import Foundation
import MeetTapeCore
import UserNotifications

/// Whether the User Notifications framework can be used at all.
///
/// `UNUserNotificationCenter.current()` raises an Objective-C exception, which
/// Swift cannot catch, when the running process has no bundle identifier. That
/// is every command-line invocation of this code, including the test runner.
/// The shipping app always runs from a bundle, so this is false only outside it.
public enum NotificationSupport {
    public static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }
}

/// User-facing notifications.
///
/// Nothing here carries meeting content beyond the title the user will see
/// anyway, and nothing is logged. Under an ad-hoc signature macOS refuses to
/// deliver notifications at all, so every call tolerates failure quietly.
public struct NotificationService: Sendable {
    public enum Category: String, Sendable {
        case recordingStarted = "recording_started"
        case meetingSaved = "meeting_saved"
        case keepRecording = "keep_recording"
        case captureProblem = "capture_problem"
        case processingProblem = "processing_problem"
        case readyToReview = "ready_to_review"
    }

    public enum Action: String, Sendable {
        case keep
        case discard
        case reveal
        case retry
    }

    /// `UNUserNotificationCenter.current()` is a thread-safe singleton, so it is
    /// resolved per call rather than stored. Nil outside an app bundle.
    private var center: UNUserNotificationCenter? {
        NotificationSupport.isAvailable ? .current() : nil
    }

    public init() {}

    /// Registers the actionable categories. Actionable notifications need a
    /// Developer ID signature; under ad-hoc signing this is accepted and then
    /// never delivered.
    public func registerCategories() {
        let keep = UNNotificationCategory(
            identifier: Category.keepRecording.rawValue,
            actions: [
                UNNotificationAction(
                    identifier: Action.keep.rawValue, title: "Keep Recording", options: []
                ),
                UNNotificationAction(
                    identifier: Action.discard.rawValue, title: "Discard",
                    options: [.destructive]
                ),
            ],
            intentIdentifiers: []
        )
        let saved = UNNotificationCategory(
            identifier: Category.meetingSaved.rawValue,
            actions: [
                UNNotificationAction(
                    identifier: Action.reveal.rawValue, title: "Reveal in Finder", options: [.foreground]
                ),
            ],
            intentIdentifiers: []
        )
        let failed = UNNotificationCategory(
            identifier: Category.processingProblem.rawValue,
            actions: [
                UNNotificationAction(
                    identifier: Action.retry.rawValue, title: "Retry", options: []
                ),
            ],
            intentIdentifiers: []
        )
        center?.setNotificationCategories([keep, saved, failed])
    }

    public func post(
        title: String, body: String, category: Category, userInfo: [String: String] = [:]
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = category.rawValue
        content.userInfo = userInfo
        content.sound = nil
        let request = UNNotificationRequest(
            identifier: "\(category.rawValue)-\(UUID().uuidString)", content: content, trigger: nil
        )
        center?.add(request) { error in
            if let error {
                Log.ui.notice("notification not delivered: \(logSafeDescription(error), privacy: .public)")
            }
        }
    }

    public func recordingStarted(provider: MeetingProvider, title: String?) {
        post(
            title: "Recording \(provider.displayName)",
            body: title ?? "MeetTape is capturing this meeting.",
            category: .recordingStarted
        )
    }

    public func meetingSaved(title: String, path: String, meetingID: String) {
        post(
            title: "Meeting saved",
            body: title,
            category: .meetingSaved,
            userInfo: ["meetingID": meetingID, "path": path]
        )
    }

    public func askToKeep(applicationName: String, meetingID: String) {
        post(
            title: "This looks like a meeting",
            body: "MeetTape started recording \(applicationName). Keep it?",
            category: .keepRecording,
            userInfo: ["meetingID": meetingID]
        )
    }

    /// Posted when the transcript is complete. Tapping it opens the review
    /// window, where the user fills in speaker names and the title.
    public func readyToReview(title: String, meetingID: String) {
        post(
            title: "Transcript ready",
            body: "\(title) is transcribed. Open it to name the speakers and check the title.",
            category: .readyToReview,
            userInfo: ["meetingID": meetingID]
        )
    }

    public func captureProblem(_ warning: CaptureWarning) {
        post(title: "Recording problem", body: warning.message, category: .captureProblem)
    }

    public func processingProblem(_ error: ProcessingError, meetingID: String) {
        post(
            title: "Processing needs attention",
            body: error.userMessage,
            category: .processingProblem,
            userInfo: ["meetingID": meetingID]
        )
    }
}
