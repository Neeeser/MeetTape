import AVFoundation
import AppKit
import ApplicationServices
import CoreGraphics
import EventKit
import Foundation
import MeetTapeCore
import UserNotifications

public enum PermissionKind: String, Sendable, CaseIterable, Identifiable {
    case microphone
    case screenRecording
    case accessibility
    case calendar
    case notifications

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .microphone: "Microphone"
        case .screenRecording: "System Audio & Screen Recording"
        case .accessibility: "Accessibility"
        case .calendar: "Calendar"
        case .notifications: "Notifications"
        }
    }

    /// Why MeetTape asks, and what happens without it.
    public var rationale: String {
        switch self {
        case .microphone:
            "Records your side of every meeting. MeetTape cannot record without it."
        case .screenRecording:
            "Reads window titles to identify which meeting is on screen. Without it, browser detection relies on audio state alone."
        case .accessibility:
            "Detects when you join and leave a Slack Huddle. Without it, Slack detection relies on microphone activity."
        case .calendar:
            "Matches recordings to calendar events for titles and attendees. Recording works without it."
        case .notifications:
            "Reports when recording starts, when a meeting is saved, and when a stage needs attention."
        }
    }

    public var isRequired: Bool {
        switch self {
        case .microphone: true
        case .screenRecording, .accessibility, .calendar, .notifications: false
        }
    }

    /// The System Settings pane, for the permissions macOS will not grant in-app.
    public var settingsURL: URL? {
        switch self {
        case .microphone:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .screenRecording:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        case .accessibility:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .calendar:
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
        case .notifications:
            URL(string: "x-apple.systempreferences:com.apple.preference.notifications")
        }
    }
}

public enum PermissionState: String, Sendable, Equatable {
    case granted
    case denied
    case notDetermined
    /// System Settings shows this as enabled but the running build cannot use it.
    ///
    /// Observed after re-signing the application: the Accessibility toggle read as
    /// enabled while `AXIsProcessTrusted()` returned false. Removing MeetTape from
    /// the list in System Settings and adding it again restores access.
    case grantedButNotEffective
}

public struct PermissionStatus: Sendable, Equatable, Identifiable {
    public let kind: PermissionKind
    public let state: PermissionState
    public var id: String { kind.rawValue }

    public init(kind: PermissionKind, state: PermissionState) {
        self.kind = kind
        self.state = state
    }

    public var isUsable: Bool { state == .granted }

    public var advice: String? {
        switch state {
        case .granted: nil
        case .notDetermined: "Not requested yet."
        case .denied: "Enable it in System Settings, then return here."
        case .grantedButNotEffective:
            "\(kind.title) appears enabled but is not active for this MeetTape build. "
                + "Remove MeetTape from the list in System Settings and add it again."
        }
    }
}

/// Reports the effective state of each permission by probing it, since a System
/// Settings toggle can be enabled while the running build has no access.
public struct PermissionsService: Sendable {
    public init() {}

    public func status(for kind: PermissionKind) async -> PermissionStatus {
        switch kind {
        case .microphone:
            return PermissionStatus(kind: kind, state: microphoneState())
        case .screenRecording:
            return PermissionStatus(
                kind: kind, state: CGPreflightScreenCaptureAccess() ? .granted : .denied
            )
        case .accessibility:
            return PermissionStatus(kind: kind, state: accessibilityState())
        case .calendar:
            return PermissionStatus(kind: kind, state: calendarState())
        case .notifications:
            return PermissionStatus(kind: kind, state: await notificationState())
        }
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

    private func calendarState() -> PermissionState {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .denied, .restricted, .writeOnly: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
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
            _ = await CalendarService().requestAccess()
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
