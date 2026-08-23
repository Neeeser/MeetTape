import EventKit
import Foundation
import MeetTapeCore

/// Calendar enrichment.
///
/// Enrichment only: nothing here decides whether a meeting is recorded, and a
/// spontaneous call with no calendar entry is captured exactly the same way.
public final class CalendarService: @unchecked Sendable {
    public struct Match: Sendable, Equatable {
        public let link: CalendarLink
        public let reason: String
    }

    /// `EKEventStore` is not documented as thread safe, so every use of it goes
    /// through this queue and no reference to it escapes.
    private let queue = DispatchQueue(label: "com.meettape.calendar")
    private let store: EKEventStore

    public init(store: EKEventStore = EKEventStore()) {
        self.store = store
    }

    public static var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    public static var isAuthorized: Bool {
        authorizationStatus == .fullAccess
    }

    /// Whether the store can actually read calendars.
    ///
    /// `EKEventStore.authorizationStatus` is not reliable in the process that
    /// asked for access. Observed on macOS 27: `requestFullAccessToEvents`
    /// called back with `granted = true`, System Settings listed MeetTape under
    /// Calendars with Full Access, and the class method went on reporting
    /// `notDetermined` for the rest of the process's life. Everything gated on
    /// it therefore did nothing until the next launch, which for `events(around:)`
    /// means a meeting recorded in that session never got its calendar title or
    /// its attendees.
    ///
    /// Asking the store for calendars is not cached and answers what the next
    /// fetch will actually do. A user with access and no event calendars at all
    /// reads as no access, which is the same answer the status already gives, so
    /// nothing is made worse by the ambiguity.
    public func hasUsableAccess() async -> Bool {
        if Self.isAuthorized { return true }
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: !self.store.calendars(for: .event).isEmpty)
            }
        }
    }

    public func requestAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                self.store.requestFullAccessToEvents { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    /// Events overlapping a window around the meeting.
    ///
    /// Asynchronous because the store can take seconds when cold, and blocking a
    /// cooperative-pool thread on it stalls unrelated work.
    public func events(around date: Date, window: TimeInterval = 45 * 60) async -> [EKEvent] {
        guard await hasUsableAccess() else { return [] }
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.fetchEvents(around: date, window: window))
            }
        }
    }

    private func fetchEvents(around date: Date, window: TimeInterval) -> [EKEvent] {
        {
            let predicate = store.predicateForEvents(
                withStart: date.addingTimeInterval(-window),
                end: date.addingTimeInterval(window),
                calendars: nil
            )
            return store.events(matching: predicate)
        }()
    }

    /// Picks the event most likely to be this meeting.
    ///
    /// The choice itself is `CalendarMatchPolicy`, which holds no EventKit and
    /// is therefore testable; this reads the store and maps what it finds.
    public func bestMatch(
        startedAt: Date, endedAt: Date?, meetingURL: String?, providerMeetingID: String?
    ) async -> Match? {
        let events = await events(around: startedAt)
        guard !events.isEmpty else { return nil }
        let end = endedAt ?? startedAt.addingTimeInterval(30 * 60)

        var byIdentifier: [String: EKEvent] = [:]
        var candidates: [CalendarCandidate] = []
        for event in events {
            let identifier = event.eventIdentifier ?? UUID().uuidString
            byIdentifier[identifier] = event
            candidates.append(CalendarCandidate(
                identifier: identifier,
                title: event.title ?? "Untitled event",
                startDate: event.startDate,
                endDate: event.endDate,
                isAllDay: event.isAllDay,
                haystack: [event.notes, event.location, event.url?.absoluteString]
                    .compactMap { $0 }
                    .joined(separator: " ")
            ))
        }

        guard let best = CalendarMatchPolicy.best(
            among: candidates, startedAt: startedAt, endedAt: end,
            meetingURL: meetingURL, providerMeetingID: providerMeetingID
        ) else { return nil }
        let event = byIdentifier[best.candidate.identifier]
        let attendees = (event?.attendees ?? []).compactMap { attendee -> String? in
            attendee.name ?? attendee.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
        }
        return Match(
            link: CalendarLink(
                eventIdentifier: best.candidate.identifier,
                title: best.candidate.title,
                startDate: best.candidate.startDate,
                endDate: best.candidate.endDate,
                organizer: event?.organizer?.name,
                attendees: attendees,
                confidence: min(best.score, 1)
            ),
            reason: best.reason
        )
    }
}
