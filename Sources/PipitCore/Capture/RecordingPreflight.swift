import Foundation

/// What a recording is missing before it starts.
///
/// A process tap created without the Screen & System Audio Recording grant
/// returns no error anywhere. The tap, the aggregate device, the IOProc and
/// the start call all succeed, and the callback then delivers digital zero at
/// full rate for the whole meeting. Seven recordings on this Mac lost their far
/// end that way, every one made by a build launched after a reinstall and
/// before the grant was given again. The tap cannot tell, so the grant is
/// checked before capture is armed and the answer is said out loud.
public enum RecordingPreflight {
    /// What to do with a recording that is about to start.
    public enum Decision: Equatable, Sendable {
        /// Do not start. Nothing useful can be recorded and the person has to
        /// act first.
        case refuse(CaptureWarning)
        /// Start, and say these things out loud as it does.
        case proceed([CaptureWarning])
    }

    /// - Parameters:
    ///   - capturesRemote: whether this source records the far end through a
    ///     process tap at all.
    ///   - microphone: the Microphone grant. Without it the input engine
    ///     throws on every build and the meeting is a folder of nothing, so
    ///     the recording is refused rather than started.
    ///   - systemAudio: the Screen & System Audio Recording grant, read only
    ///     when the far end is captured. Without it the tap delivers silence
    ///     and reports healthy; the microphone still records, so the meeting
    ///     goes ahead with the warning said at once.
    public static func decide(
        capturesRemote: Bool, microphone: PermissionState, systemAudio: PermissionState
    ) -> Decision {
        guard microphone == .granted else { return .refuse(.microphonePermissionMissing) }
        return .proceed(warnings(capturesRemote: capturesRemote, systemAudio: systemAudio))
    }

    /// - Parameters:
    ///   - capturesRemote: whether this source records the far end through a
    ///     process tap at all. An in-person or imported recording does not.
    ///   - systemAudio: the state of the Screen & System Audio Recording
    ///     grant as probed for the running build. Anything but `granted`
    ///     means the tap will deliver silence, including a grant System
    ///     Settings shows as on for a build whose code hash has since changed.
    public static func warnings(
        capturesRemote: Bool, systemAudio: PermissionState
    ) -> [CaptureWarning] {
        guard capturesRemote, systemAudio != .granted else { return [] }
        return [.systemAudioPermissionMissing]
    }
}

/// What the person is shown when a recording is asked for without a grant.
///
/// The warning is what gets stored with the meeting and shown in the menu.
/// This is what goes on screen at the moment of refusal, in front of the
/// call. One missing grant is given from the panel itself; more than one
/// sends the person into Setup, which walks through them in order.
public struct PermissionNotice: Equatable, Sendable, Identifiable {
    /// The grants that are missing, in Setup order. Never empty.
    public let missing: [PermissionKind]

    public var id: String { missing.map(\.rawValue).joined(separator: "+") }

    /// Nil when nothing is missing.
    public init?(missing: [PermissionKind]) {
        let ordered = PermissionKind.allCases.filter { missing.contains($0) }
        guard !ordered.isEmpty else { return nil }
        self.missing = ordered
    }

    /// The one grant to give from the panel, or nil when Setup takes over.
    public var single: PermissionKind? { missing.count == 1 ? missing[0] : nil }

    /// Whether the microphone is still being recorded behind the notice.
    /// Without the Microphone grant nothing is; without the system audio
    /// grant the microphone runs and the far end is lost.
    public var recordingContinues: Bool { !missing.contains(.microphone) }

    public var title: String {
        recordingContinues
            ? "Pipit can't record the other people in this meeting"
            : "Pipit can't record this meeting"
    }

    public var body: String {
        switch single {
        case .microphone:
            return "Pipit does not have the Microphone permission. Nothing was recorded. Allow it and the recording starts."
        case .screenRecording:
            return "Pipit does not have the Screen & System Audio Recording permission. Your microphone is being recorded. The other side of the call is not."
        case .accessibility:
            return "Pipit does not have the Accessibility permission, so Slack huddles are not detected. Recording still works."
        case .some(let kind):
            return "Pipit does not have the \(kind.title) permission."
        case .none:
            let names = missing.map(\.paneTitle).joined(separator: " or ")
            return recordingContinues
                ? "Pipit does not have the \(names) permission. Setup walks through each one."
                : "Pipit does not have the \(names) permission. Nothing was recorded. Setup walks through each one."
        }
    }

    /// The menu item that stays until the grants exist.
    public var menuTitle: String {
        if let single { return "\(single.title) permission missing…" }
        return "Permissions missing…"
    }

    /// The warnings recorded against the session for these grants.
    public var warnings: [CaptureWarning] {
        missing.compactMap { kind in
            switch kind {
            case .microphone: .microphonePermissionMissing
            case .screenRecording: .systemAudioPermissionMissing
            case .accessibility, .calendar, .notifications: nil
            }
        }
    }

    /// The grants Pipit cannot fully work without that are not in effect,
    /// from whatever has been probed so far. A kind never probed is not
    /// counted as missing: the icon goes red on evidence, not on silence.
    public static func missingRequired(in states: [PermissionKind: PermissionState]) -> PermissionNotice? {
        let missing = PermissionKind.allCases.filter { kind in
            guard kind.isRequired, let state = states[kind] else { return false }
            return state != .granted
        }
        return PermissionNotice(missing: missing)
    }

    /// Whether every grant this notice is about is now usable.
    public func isResolved(by statuses: [PermissionStatus]) -> Bool {
        missing.allSatisfy { kind in statuses.contains { $0.kind == kind && $0.isUsable } }
    }
}

/// When the notice goes on screen, as opposed to being recorded.
///
/// A manual start gets it every time: the person pressed the button and is
/// waiting for a reaction. A detected call re-arms on every poll while the
/// grant is missing, and gets it once a minute so the window is seen and not
/// thrown at them twice a second.
public enum PermissionPromptPolicy {
    public static let detectedRepeatInterval: TimeInterval = 60

    public static func shouldPrompt(isManual: Bool, lastPromptedAt: Date?, now: Date) -> Bool {
        if isManual { return true }
        guard let lastPromptedAt else { return true }
        return now.timeIntervalSince(lastPromptedAt) >= detectedRepeatInterval
    }
}
