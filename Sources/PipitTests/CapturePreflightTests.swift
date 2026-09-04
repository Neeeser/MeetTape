import Foundation
import PipitCore
import TestKit

enum CapturePreflightTests {
    static let suite = Suite("CapturePreflight", [
        test("a call recorded without the system audio grant is warned about before capture") { expect in
            // Seven recordings on this Mac lost their far end to a tap created
            // without the grant. The tap reports healthy, so the answer has to
            // come from the grant itself, before anything is armed.
            for state in [PermissionState.denied, .notDetermined, .grantedButNotEffective] {
                expect.equal(
                    RecordingPreflight.warnings(capturesRemote: true, systemAudio: state),
                    [.systemAudioPermissionMissing],
                    "\(state.rawValue) means silence from the tap"
                )
            }
        },

        test("a granted tap and a recording with no far end raise nothing") { expect in
            expect.equal(RecordingPreflight.warnings(capturesRemote: true, systemAudio: .granted), [])
            // An in-person or imported recording never opens a tap, so the
            // grant is not its business.
            expect.equal(RecordingPreflight.warnings(capturesRemote: false, systemAudio: .denied), [])
        },

        test("a warning stored by key reads back as its message") { expect in
            let key = CaptureWarning.systemAudioPermissionMissing.dedupKey
            expect.equal(
                CaptureWarning.message(forKey: key), CaptureWarning.systemAudioPermissionMissing.message
            )
            expect.equal(
                CaptureWarning.message(forKey: "remote_silent_while_producing"),
                CaptureWarning.remoteSilentWhileProducing(seconds: 0).message
            )
            expect.equal(
                CaptureWarning.message(forKey: "permission_revoked_mic"),
                CaptureWarning.permissionRevoked(track: .mic).message
            )
            // What older builds wrote is free text and is shown as it was.
            expect.equal(
                CaptureWarning.message(forKey: "capture ended in state degraded"),
                "capture ended in state degraded"
            )
        },
    ])
}
