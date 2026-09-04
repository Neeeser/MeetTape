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

        test("a missing grant becomes a notice with a button into the right Setup step") { expect in
            let refused = PermissionNotice(warning: .microphonePermissionMissing)
            expect.equal(refused?.kind, .microphone)
            expect.equal(refused?.recordingContinues, false)
            expect.equal(refused?.title, "Pipit can't record this meeting")
            expect.equal(refused?.menuTitle, "Microphone permission missing…")

            let farEnd = PermissionNotice(warning: .systemAudioPermissionMissing)
            expect.equal(farEnd?.kind, .screenRecording)
            expect.equal(farEnd?.recordingContinues, true)
            expect.equal(farEnd?.title, "Pipit can't record the other people in this meeting")

            // A microphone that went away mid-call is a capture fault, not a
            // grant to go and give.
            expect.isNil(PermissionNotice(warning: .permissionRevoked(track: .mic)))
        },

        test("the notice clears when its own grant is seen, not another") { expect in
            let notice = PermissionNotice(warning: .systemAudioPermissionMissing)!
            expect.isFalse(notice.isResolved(by: [PermissionStatus(kind: .microphone, state: .granted)]))
            expect.isFalse(
                notice.isResolved(by: [PermissionStatus(kind: .screenRecording, state: .grantedButNotEffective)]),
                "System Settings showing it on is not the tap being able to use it"
            )
            expect.isTrue(notice.isResolved(by: [PermissionStatus(kind: .screenRecording, state: .granted)]))
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
