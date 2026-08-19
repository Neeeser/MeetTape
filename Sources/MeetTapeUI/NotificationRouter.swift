import AppKit
import Foundation
import MeetTapeCore
import MeetTapeIntegrations
import MeetTapeServices
import UserNotifications

/// Routes notification button taps to the runtime.
///
/// Without a delegate the actions registered on each category are inert: the
/// buttons appear and do nothing. Under an ad-hoc signature macOS refuses to
/// deliver actionable notifications at all, so this only comes alive on a build
/// signed with a Developer ID.
@MainActor
public final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    private let runtime: MeetTapeRuntime
    private let windows: WindowManager

    public init(runtime: MeetTapeRuntime, windows: WindowManager) {
        self.runtime = runtime
        self.windows = windows
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        let meetingID = response.notification.request.content.userInfo["meetingID"] as? String
        await MainActor.run {
            switch NotificationService.Action(rawValue: action) {
            case .keep:
                runtime.resolveProvisional(keep: true)
            case .discard:
                runtime.resolveProvisional(keep: false)
            case .reveal:
                if let meetingID { runtime.revealInFinder(meetingID: meetingID) }
            case .retry:
                if let meetingID { runtime.retryProcessing(meetingID: meetingID) }
            case nil:
                // Tapping the body opens the meeting it refers to.
                if let meetingID { windows.showReview(meetingID: meetingID) }
            }
        }
    }

    /// Meeting notices are worth seeing even while MeetTape is frontmost.
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
