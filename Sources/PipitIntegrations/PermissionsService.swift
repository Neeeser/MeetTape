import AVFoundation
import AppKit
import ApplicationServices
import CoreGraphics
import EventKit
import Foundation
import PipitCore
import UserNotifications

/// Reports the effective state of each permission by probing it, since a System
/// Settings toggle can be enabled while the running build has no access.
public struct PermissionsService: Sendable {
    /// One store for the calendar probe. A fresh `EKEventStore` per poll would
    /// reconnect to the calendar daemon every 1.5 seconds.
    private static let calendarProbe = CalendarService()

    public init() {}

    public func status(for kind: PermissionKind) async -> PermissionStatus {
        switch kind {
        case .microphone:
            return PermissionStatus(kind: kind, state: microphoneState())
        case .screenRecording:
            return PermissionStatus(kind: kind, state: ScreenRecordingProbe.state())
        case .accessibility:
            return PermissionStatus(kind: kind, state: accessibilityState())
        case .calendar:
            return PermissionStatus(kind: kind, state: await calendarState())
        case .notifications:
            return PermissionStatus(kind: kind, state: await notificationState())
        }
    }

    /// One line describing every permission, for the log.
    public static func summary(of statuses: [PermissionStatus]) -> String {
        statuses.map { "\($0.kind.rawValue)=\($0.state.rawValue)" }.joined(separator: " ")
    }

    public func allStatuses() async -> [PermissionStatus] {
        var statuses: [PermissionStatus] = []
        for kind in PermissionKind.allCases {
            statuses.append(await status(for: kind))
        }
        return statuses
    }

    private func microphoneState() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }

    /// Distinguishes "never granted" from "granted but not binding to this build".
    private func accessibilityState() -> PermissionState {
        if AXIsProcessTrusted() { return .granted }
        return TCCRecordProbe.hasStaleAccessibilityRecord() ? .grantedButNotEffective : .denied
    }

    private func calendarState() async -> PermissionState {
        let reported = EKEventStore.authorizationStatus(for: .event)
        guard reported == .notDetermined else {
            return Self.calendarState(reported: reported, canReadCalendars: false)
        }
        // The only case the probe can change, and the only one worth the cost of
        // asking the calendar daemon on every poll.
        return Self.calendarState(
            reported: reported, canReadCalendars: await Self.calendarProbe.hasUsableAccess()
        )
    }

    /// The reported status and a functional probe, resolved to one state.
    ///
    /// Separated from the probe so the rule is testable: the whole point is that
    /// `notDetermined` is not trustworthy in the process that asked for access,
    /// and a store that can read calendars overrides it.
    public static func calendarState(
        reported: EKAuthorizationStatus, canReadCalendars: Bool
    ) -> PermissionState {
        switch reported {
        case .fullAccess: return .granted
        case .denied, .restricted, .writeOnly: return .denied
        case .notDetermined:
            // EventKit reports notDetermined for the life of the process that was
            // granted access. The probe is what catches it.
            return canReadCalendars ? .granted : .notDetermined
        @unknown default: return canReadCalendars ? .granted : .notDetermined
        }
    }

    private func notificationState() async -> PermissionState {
        guard NotificationSupport.isAvailable else { return .notDetermined }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .granted
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    // MARK: - requests

    /// Microphone and Calendar present a dialog. Accessibility and Screen
    /// Recording do not, and can only be granted in System Settings.
    @discardableResult
    public func request(_ kind: PermissionKind) async -> PermissionStatus {
        switch kind {
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .calendar:
            // The same store the probe reads from, so the grant and the check
            // are not on two different connections to the calendar daemon.
            let granted = await Self.calendarProbe.requestAccess()
            Log.app.info(
                "calendar request returned \(granted, privacy: .public), status now \(EKEventStore.authorizationStatus(for: .event).rawValue, privacy: .public)"
            )
        case .notifications:
            guard NotificationSupport.isAvailable else { break }
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        case .accessibility:
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        }
        return await status(for: kind)
    }

    @MainActor
    public func openSettings(for kind: PermissionKind) {
        guard let url = kind.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Reads screen recording access, preferring the system's own answer and falling
/// back to the window list when it says no.
///
/// `CGPreflightScreenCaptureAccess` is the supported check and is what this asks
/// first. It has a long history of answering from a cache filled once per
/// process, which is why so many applications tell people to quit and reopen
/// after granting; the fallback exists to spare Pipit's users that, and does
/// nothing at all when the supported call is already right.
///
/// The fallback reads `kCGWindowName`, which the window server populates only for
/// a process holding the grant. It has to be conservative, because a false
/// positive here lets setup finish on a machine that cannot see a window title,
/// which is the exact failure the gating exists to prevent. So it counts only
/// ordinary application windows: another process, and window layer 0. The window
/// server's own `Menubar` window sits at layer 24 and reports its name to
/// everybody, so counting any named window at all reported the grant on every
/// machine in the world.
///
/// Chromium and mac-screen-capture-permissions are often cited for this trick.
/// Both did use it once and both now call `CGPreflightScreenCaptureAccess` and
/// nothing else, so it is kept here as a fallback rather than as the answer.
public enum ScreenRecordingProbe {
    public static func state() -> PermissionState {
        if CGPreflightScreenCaptureAccess() { return .granted }
        return canReadApplicationWindowNames() ? .granted : .denied
    }

    /// Whether any ordinary window belonging to another application reports a
    /// name.
    static func canReadApplicationWindowNames() -> Bool {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return windows.contains { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                // Layer 0 is an ordinary application window. Everything above it
                // is system furniture that names itself regardless of the grant.
                let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                let name = window[kCGWindowName as String] as? String, !name.isEmpty
            else { return false }
            return true
        }
    }
}

/// Detects the granted-but-not-effective state without reading TCC's database,
/// which is not accessible and does not live at a stable path.
enum TCCRecordProbe {
    /// The unified log records TCC's decisions. A recent grant for this bundle
    /// while the effective check fails means the record is stale.
    static func hasStaleAccessibilityRecord() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "show", "--last", "10m", "--style", "compact",
            "--predicate", #"process == "tccd""#,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains(bundleID)
            && text.contains("kTCCServiceAccessibility")
            && text.contains("AUTHREQ_CTX")
    }
}
