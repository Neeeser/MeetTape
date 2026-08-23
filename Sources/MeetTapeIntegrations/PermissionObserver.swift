import AppKit
import Foundation
import MeetTapeCore

/// Reports permission changes as they happen, so a grant made in System Settings
/// shows up in MeetTape without a relaunch.
///
/// macOS publishes nothing that covers all five permissions, so this combines the
/// signals that exist:
///
/// - `com.apple.accessibility.api`, a distributed notification the system posts
///   when the Accessibility list changes. It arrives on the switch itself.
/// - `NSWorkspace.didActivateApplicationNotification`, which fires the moment the
///   user comes back from System Settings and covers every pane at once.
/// - A slow poll, for the case where the user never leaves MeetTape's window,
///   which happens when the drag chip is used and System Settings never takes
///   focus.
///
/// The poll runs only while someone is looking at a permission, since its whole
/// purpose is to redraw a screen.
@MainActor
public final class PermissionObserver: NSObject {
    /// How often the fallback poll runs. Fast enough that switching a toggle and
    /// looking back at MeetTape reads as instant, slow enough to be free.
    public static let pollInterval: TimeInterval = 1.5

    private let service: PermissionsService
    private let distributed: DistributedNotificationCenter
    private let workspace: NotificationCenter
    private var workspaceToken: NSObjectProtocol?
    private var timer: DispatchSourceTimer?
    private var onChange: (([PermissionStatus]) -> Void)?
    private var isRefreshing = false

    /// The name the system posts when the Accessibility list changes.
    static let accessibilityChanged = Notification.Name("com.apple.accessibility.api")

    public init(
        service: PermissionsService = PermissionsService(),
        distributed: DistributedNotificationCenter = .default(),
        workspace: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.service = service
        self.distributed = distributed
        self.workspace = workspace
        super.init()
    }

    /// Begins reporting. The handler is called once immediately, so a caller has
    /// a state to draw before any signal arrives.
    public func start(onChange: @escaping ([PermissionStatus]) -> Void) {
        stop()
        self.onChange = onChange

        // The selector form is what takes a suspension behaviour. MeetTape is an
        // accessory application and spends setup in the background while System
        // Settings is in front, which is exactly when a coalesced notification
        // would be held back until it no longer matters.
        distributed.addObserver(
            self, selector: #selector(signalled), name: Self.accessibilityChanged,
            object: nil, suspensionBehavior: .deliverImmediately
        )
        workspaceToken = workspace.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.pollInterval, repeating: Self.pollInterval)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.resume()
        self.timer = timer

        refresh()
    }

    public func stop() {
        guard onChange != nil || timer != nil else { return }
        distributed.removeObserver(self, name: Self.accessibilityChanged, object: nil)
        if let workspaceToken { workspace.removeObserver(workspaceToken) }
        workspaceToken = nil
        timer?.cancel()
        timer = nil
        onChange = nil
    }

    @objc private func signalled() {
        MainActor.assumeIsolated { refresh() }
    }

    /// Reads every permission and reports the result.
    ///
    /// Reads overlap: the notification and the poll routinely land together, and
    /// the notification permission read is an `await` into another process. A
    /// second pass while one is in flight is dropped rather than queued, since it
    /// would report the same answer.
    public func refresh() {
        guard let onChange, !isRefreshing else { return }
        isRefreshing = true
        Task { @MainActor in
            defer { isRefreshing = false }
            onChange(await service.allStatuses())
        }
    }
}
