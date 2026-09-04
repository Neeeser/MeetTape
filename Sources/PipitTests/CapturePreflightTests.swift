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

        test("no microphone grant refuses the recording, no system audio grant lets it run with a warning") { expect in
            expect.equal(
                RecordingPreflight.decide(capturesRemote: true, microphone: .denied, systemAudio: .granted),
                RecordingPreflight.Decision.refuse(.microphonePermissionMissing)
            )
            expect.equal(
                RecordingPreflight.decide(capturesRemote: false, microphone: .notDetermined, systemAudio: .denied),
                RecordingPreflight.Decision.refuse(.microphonePermissionMissing)
            )
            expect.equal(
                RecordingPreflight.decide(capturesRemote: true, microphone: .granted, systemAudio: .denied),
                RecordingPreflight.Decision.proceed([.systemAudioPermissionMissing])
            )
            expect.equal(
                RecordingPreflight.decide(capturesRemote: true, microphone: .granted, systemAudio: .granted),
                RecordingPreflight.Decision.proceed([])
            )
            expect.equal(
                RecordingPreflight.decide(capturesRemote: false, microphone: .granted, systemAudio: .denied),
                RecordingPreflight.Decision.proceed([])
            )
            expect.equal(
                CaptureWarning.message(forKey: "microphone_permission_missing"),
                CaptureWarning.microphonePermissionMissing.message
            )
        },

        test("one missing grant is offered from the panel, two send the person into Setup") { expect in
            let refused = PermissionNotice(missing: [.microphone])
            expect.equal(refused?.single, .microphone)
            expect.equal(refused?.recordingContinues, false)
            expect.equal(refused?.title, "Pipit can't record this meeting")
            expect.equal(refused?.menuTitle, "Microphone permission missing…")
            expect.equal(refused?.warnings, [.microphonePermissionMissing])

            let farEnd = PermissionNotice(missing: [.screenRecording])
            expect.equal(farEnd?.single, .screenRecording)
            expect.equal(farEnd?.recordingContinues, true)
            expect.equal(farEnd?.title, "Pipit can't record the other people in this meeting")

            // Given out of order, kept in Setup order, and too many for one
            // panel to grant.
            let both = PermissionNotice(missing: [.screenRecording, .microphone])
            expect.equal(both?.missing, [.microphone, .screenRecording])
            expect.isNil(both?.single)
            expect.equal(both?.menuTitle, "Permissions missing…")
            expect.equal(both?.recordingContinues, false)
            expect.isTrue(both?.body.contains("Setup") == true)

            expect.isNil(PermissionNotice(missing: []))
        },

        test("the notice clears when every grant it names is seen, not one of them") { expect in
            let notice = PermissionNotice(missing: [.microphone, .screenRecording])!
            let mic = PermissionStatus(kind: PermissionKind.microphone, state: .granted)
            expect.isFalse(notice.isResolved(by: [mic]))
            expect.isFalse(
                notice.isResolved(by: [mic, PermissionStatus(kind: .screenRecording, state: .grantedButNotEffective)]),
                "System Settings showing it on is not the tap being able to use it"
            )
            expect.isTrue(
                notice.isResolved(by: [mic, PermissionStatus(kind: .screenRecording, state: .granted)])
            )
        },

        test("a manual start always gets the notice, a detected call once a minute") { expect in
            let now = Date(timeIntervalSince1970: 1_000)
            let justNow = now.addingTimeInterval(-1)
            // The person pressed the button one second after the last notice
            // and is waiting for a reaction. This was the second press that
            // saw nothing.
            expect.isTrue(PermissionPromptPolicy.shouldPrompt(isManual: true, lastPromptedAt: justNow, now: now))
            expect.isTrue(PermissionPromptPolicy.shouldPrompt(isManual: false, lastPromptedAt: nil, now: now))
            expect.isFalse(PermissionPromptPolicy.shouldPrompt(isManual: false, lastPromptedAt: justNow, now: now))
            expect.isTrue(
                PermissionPromptPolicy.shouldPrompt(
                    isManual: false, lastPromptedAt: now.addingTimeInterval(-60), now: now
                )
            )
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
