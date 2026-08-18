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
    public func events(around date: Date, window: TimeInterval = 45 * 60) -> [EKEvent] {
        guard Self.isAuthorized else { return [] }
        return queue.sync {
            let predicate = store.predicateForEvents(
                withStart: date.addingTimeInterval(-window),
                end: date.addingTimeInterval(window),
                calendars: nil
            )
            return store.events(matching: predicate)
        }
    }

    /// Picks the event most likely to be this meeting.
    ///
    /// A matching meeting URL or ID is decisive. Otherwise the closest event that
    /// actually overlaps the recording wins, and a weak match is still returned
    /// with a low confidence so the UI can present it as a suggestion.
    public func bestMatch(
        startedAt: Date, endedAt: Date?, meetingURL: String?, providerMeetingID: String?
    ) -> Match? {
        let candidates = events(around: startedAt)
        guard !candidates.isEmpty else { return nil }
        let end = endedAt ?? startedAt.addingTimeInterval(30 * 60)

        var best: (event: EKEvent, score: Double, reason: String)?
        for event in candidates {
            var score = 0.0
            var reasons: [String] = []
            let haystack = [event.notes, event.location, event.url?.absoluteString]
                .compactMap { $0 }
                .joined(separator: " ")

            if let providerMeetingID, !providerMeetingID.isEmpty,
               haystack.localizedCaseInsensitiveContains(providerMeetingID) {
                score += 0.7
                reasons.append("meeting ID in the invitation")
            }
            if let meetingURL, let host = URLComponents(string: meetingURL)?.host,
               haystack.localizedCaseInsensitiveContains(host) {
                score += 0.15
                reasons.append("provider link in the invitation")
            }

            let overlap = min(event.endDate, end).timeIntervalSince(max(event.startDate, startedAt))
            if overlap > 0 {
                let recordingLength = max(end.timeIntervalSince(startedAt), 60)
                score += 0.5 * min(1, overlap / recordingLength)
                reasons.append("overlaps the recording")
            } else {
                let distance = abs(event.startDate.timeIntervalSince(startedAt))
                if distance <= 15 * 60 {
                    score += 0.25 * (1 - distance / (15 * 60))
                    reasons.append("starts near the recording")
                }
            }

            if score > (best?.score ?? 0) {
                best = (event, score, reasons.joined(separator: ", "))
            }
        }

        guard let best, best.score >= 0.25 else { return nil }
        let attendees = (best.event.attendees ?? []).compactMap { attendee -> String? in
            attendee.name ?? attendee.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
        }
        return Match(
            link: CalendarLink(
                eventIdentifier: best.event.eventIdentifier ?? UUID().uuidString,
                title: best.event.title ?? "Untitled event",
                startDate: best.event.startDate,
                endDate: best.event.endDate,
                organizer: best.event.organizer?.name,
                attendees: attendees,
                confidence: min(best.score, 1)
            ),
            reason: best.reason
        )
    }
}
