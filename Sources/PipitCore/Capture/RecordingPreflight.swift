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
