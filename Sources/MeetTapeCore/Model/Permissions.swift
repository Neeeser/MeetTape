import Foundation

/// A macOS permission MeetTape asks for.
///
/// The kind, what it is for, whether MeetTape works without it and which System
/// Settings pane grants it are all decisions with no I/O, so they live here.
/// Probing and requesting live with `PermissionsService`.
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
        case .screenRecording: "Screen and system audio"
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
            "Reads window titles to tell which meeting is on screen. Without it, a "
                + "browser call is detected from audio state alone, so recording starts "
                + "late and a prejoin screen looks the same as a joined call."
        case .accessibility:
            "Reads Slack's window contents to see when a huddle starts and ends. It "
                + "reads nothing else, and it never sends what it reads anywhere."
        case .calendar:
            "Matches a recording to the event on your calendar, which gives the meeting "
                + "its real title and its attendee list. Recording works without it."
        case .notifications:
            "Reports when recording starts, when a meeting is saved, and when a stage "
                + "needs attention."
        }
    }

    /// Whether setup blocks on it.
    ///
    /// All three detection permissions block. Microphone is what records at all;
    /// without the other two MeetTape misses the start of browser calls and every
    /// Slack huddle, which is a recorder that silently does not record.
    public var isRequired: Bool {
        switch self {
        case .microphone, .screenRecording, .accessibility: true
        case .calendar, .notifications: false
        }
    }

    /// Whether the pane accepts an application dropped into its list.
    ///
    /// The panes that hold a list of applications do; the ones granted through a
    /// system prompt have no list to drop onto.
    public var acceptsDroppedApplication: Bool {
        switch self {
        case .accessibility, .screenRecording: true
        case .microphone, .calendar, .notifications: false
        }
    }

    /// Whether macOS will ever show a prompt for it, or whether the only route is
    /// System Settings.
    public var isGrantedByPrompt: Bool {
        switch self {
        case .microphone, .calendar, .notifications: true
        case .accessibility, .screenRecording: false
        }
    }

    /// The System Settings pane that grants it.
    ///
    /// These are the Ventura-and-later identifiers. The `com.apple.preference.security`
    /// pane an earlier build used has not existed since System Settings replaced
    /// System Preferences, and opening it lands on the Settings root.
    public var settingsURL: URL? {
        let privacy = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
        switch self {
        case .microphone: return URL(string: "\(privacy)?Privacy_Microphone")
        case .screenRecording: return URL(string: "\(privacy)?Privacy_ScreenCapture")
        case .accessibility: return URL(string: "\(privacy)?Privacy_Accessibility")
        case .calendar: return URL(string: "\(privacy)?Privacy_Calendars")
        case .notifications:
            return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        }
    }

    /// The pane's own heading, reproduced in the illustration so the picture and
    /// the pane the user lands on read the same.
    ///
    /// These are what System Settings shows on macOS 27, checked against the
    /// panes themselves rather than from memory. Accessibility is the one that
    /// moved: the privacy pane the `Privacy_Accessibility` anchor opens is called
    /// Device Control and Data Access now, and it covers keyboard monitoring,
    /// mail, contacts and screen recording alongside application control. The
    /// Accessibility item still in the System Settings sidebar is the unrelated
    /// one holding VoiceOver and Zoom, so naming the picture after it would send
    /// people to the wrong place.
    public var paneTitle: String {
        switch self {
        case .microphone: "Microphone"
        case .screenRecording: "Screen & System Audio Recording"
        case .accessibility: "Device Control and Data Access"
        case .calendar: "Calendars"
        case .notifications: "Notifications"
        }
    }

    /// The line macOS prints above the list in that pane.
    public var paneCaption: String {
        switch self {
        case .microphone: "Allow the applications below to access your microphone."
        case .screenRecording:
            "Allow the applications below to record the content of your screen and audio, "
                + "even while using other applications."
        case .accessibility:
            "Apps with this access can view and send email, edit contacts and photos, "
                + "monitor your keyboard, track websites, record your screen, control any "
                + "app on your Mac, and more."
        case .calendar: "Allow the applications below to access your calendar."
        case .notifications: "Allow notifications from the applications below."
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
        case .denied where kind == .accessibility || kind == .screenRecording:
            "Switch MeetTape on in System Settings. If it is already switched on "
                + "there, remove it with the minus button and add it again: an "
                + "unsigned build gets a new identity every time it is rebuilt, and "
                + "the old entry keeps the permission."
        case .denied: "Enable it in System Settings, then return here."
        case .grantedButNotEffective:
            "\(kind.title) appears enabled but is not active for this MeetTape build. "
                + "Remove MeetTape from the list in System Settings and add it again."
        }
    }
}
