import Foundation
import MeetTapeCore
import TestKit

/// Regressions for the failure modes the capture stress test found. Every one of
/// these was a real defect before the mitigation existed.
enum CaptureRecoveryTests {
    static var micPolicySuite: Suite {
        Suite("MicRecoveryPolicy", [
            test("a burst of configuration changes rebuilds exactly once") { expect in
                var policy = MicRecoveryPolicy()
                var now = 100.0
                policy.noteRebuildStarted(at: now, isInitial: true)
                policy.noteBufferArrived(at: now)

                // Six topology events in 550 ms, the shape macOS emits while a
                // Bluetooth headset negotiates its profile.
                for _ in 0..<6 {
                    now += 0.09
                    policy.noteConfigurationChange(at: now)
                    policy.noteBufferArrived(at: now)
                    expect.equal(policy.evaluate(at: now), .none, "must not rebuild mid-burst")
                }

                // Still inside the debounce window.
                now += 0.3
                expect.equal(policy.evaluate(at: now), .none)

                now += 0.15
                guard case .rebuild(let reason) = policy.evaluate(at: now) else {
                    expect.fail("expected exactly one rebuild once the burst settled")
                    return
                }
                expect.equal(reason, .configurationChange(coalesced: 5))

                // And no second rebuild from the same burst.
                policy.noteRebuildStarted(at: now, isInitial: false)
                policy.noteBufferArrived(at: now)
                now += 0.5
                expect.equal(policy.evaluate(at: now), .none)
                expect.equal(policy.restartCount, 1)
            },

            test("the watchdog stays quiet for the grace window after a rebuild") { expect in
                var policy = MicRecoveryPolicy()
                policy.noteRebuildStarted(at: 100.0, isInitial: true)
                policy.noteBufferArrived(at: 100.0)

                // Frames stop, so the watchdog fires and a rebuild begins. The gap is
                // already over threshold at that instant and keeps growing while the
                // engine is rebuilt: this is the state that produced eight rebuilds
                // in 5.8 s before the grace window existed.
                guard case .rebuild(.watchdog) = policy.evaluate(at: 102.1) else {
                    expect.fail("watchdog should fire at a 2.1 s gap")
                    return
                }
                policy.noteRebuildStarted(at: 102.1, isInitial: false)

                for instant in [102.6, 103.1, 103.5] {
                    expect.equal(
                        policy.evaluate(at: instant), .none,
                        "watchdog tripped \(instant - 102.1)s into a rebuild"
                    )
                }
                expect.equal(policy.restartCount, 1, "the grace window must hold the count at one")
                expect.isTrue(policy.suppressedWatchdogTrips >= 3, "suppression should be counted")

                // Once the grace expires and frames are still absent, it must fire.
                guard case .rebuild(.watchdog) = policy.evaluate(at: 103.7) else {
                    expect.fail("watchdog should fire again after the grace window")
                    return
                }
            },

            test("silent engine death is caught by frame arrival, not by isRunning") { expect in
                var policy = MicRecoveryPolicy()
                var now = 100.0
                policy.noteRebuildStarted(at: now, isInitial: true)
                for _ in 0..<10 {
                    now += 0.1
                    policy.noteBufferArrived(at: now)
                }
                expect.equal(policy.health(at: now), .healthy)

                // Callbacks stop. The engine still reports running; nothing else
                // notifies us. Grace has long expired because buffers arrived.
                now += 1.9
                expect.equal(policy.evaluate(at: now), .none, "1.9 s is inside the threshold")
                now += 0.2
                guard case .rebuild(.watchdog(let gap)) = policy.evaluate(at: now) else {
                    expect.fail("watchdog must catch a dead callback stream")
                    return
                }
                expect.close(gap, 2.1, tolerance: 0.001)
            },

            test("a source that never delivers a first buffer is recovered too") { expect in
                var policy = MicRecoveryPolicy()
                let start = 100.0
                policy.noteRebuildStarted(at: start, isInitial: true)
                expect.equal(policy.evaluate(at: start + 1.0), .none, "still inside the grace window")
                expect.equal(policy.evaluate(at: start + 3.0), .none, "grace plus threshold not yet reached")
                guard case .rebuild(.noFirstBuffer) = policy.evaluate(at: start + 3.6) else {
                    expect.fail("a build that never produced audio must be retried")
                    return
                }
            },

            test("silence does not trip the watchdog") { expect in
                var policy = MicRecoveryPolicy()
                var now = 100.0
                policy.noteRebuildStarted(at: now, isInitial: true)
                // 41 seconds of a silent room: buffers keep arriving, all zeroes.
                for _ in 0..<410 {
                    now += 0.1
                    policy.noteBufferArrived(at: now)
                    expect.equal(policy.evaluate(at: now), .none)
                }
                expect.equal(policy.restartCount, 0)
                expect.equal(policy.health(at: now), .healthy)
            },
        ])
    }

    static var micCoordinatorSuite: Suite {
        Suite("MicrophoneRecoveryCoordinator", [
            test("a transient zero-channel device is never adopted") { expect in
                let engine = FakeMicrophoneEngine()
                let clock = ManualClock()
                let delegate = RecordingCaptureDelegate()
                let coordinator = MicrophoneRecoveryCoordinator(
                    controller: engine, clock: clock, delegate: delegate
                )
                engine.setSteadyFormat(AudioFormatDescriptor(sampleRate: 48_000, channelCount: 3))
                coordinator.start()
                coordinator.noteBufferArrived(hostTime: clock.monotonicSeconds)
                expect.equal(coordinator.activeFormat, AudioFormatDescriptor(sampleRate: 48_000, channelCount: 3))

                // Headphones disconnecting emitted seven topology events in 0.55 s,
                // one of which described the device mid-teardown.
                engine.queueFormatReadings([AudioFormatDescriptor(sampleRate: 0, channelCount: 0)])
                engine.setSteadyFormat(AudioFormatDescriptor(sampleRate: 48_000, channelCount: 3))
                for _ in 0..<7 {
                    coordinator.noteConfigurationChange()
                    clock.advance(0.08)
                    coordinator.tick()
                    coordinator.noteBufferArrived(hostTime: clock.monotonicSeconds)
                }
                clock.advance(0.5)
                coordinator.tick()

                expect.equal(coordinator.restartCount, 1, "seven events must coalesce into one rebuild")
                // The queued 0ch/0Hz reading is consumed by the rebuild, and the
                // previous good format is kept rather than adopted.
                expect.equal(coordinator.activeFormat, AudioFormatDescriptor(sampleRate: 48_000, channelCount: 3))
                for build in engine.builds {
                    expect.isTrue(build.format.isUsable, "built against an unusable format \(build.format)")
                }
            },

            test("a Bluetooth burst produces one rebuild, not a storm") { expect in
                let engine = FakeMicrophoneEngine()
                let clock = ManualClock()
                let delegate = RecordingCaptureDelegate()
                let coordinator = MicrophoneRecoveryCoordinator(
                    controller: engine, clock: clock, delegate: delegate
                )
                engine.setSteadyFormat(AudioFormatDescriptor(sampleRate: 48_000, channelCount: 3))
                coordinator.start()
                coordinator.noteBufferArrived(hostTime: clock.monotonicSeconds)

                // The measured sequence: six configuration events across 5.5 s while
                // the device moves 48000 -> 44100 -> 16000 Hz, and no frames arrive
                // at all during the hardware transition.
                let readings = [
                    AudioFormatDescriptor(sampleRate: 44_100, channelCount: 1),
                    AudioFormatDescriptor(sampleRate: 16_000, channelCount: 1),
                ]
                engine.queueFormatReadings(readings)
                engine.setSteadyFormat(AudioFormatDescriptor(sampleRate: 16_000, channelCount: 1))

                for _ in 0..<6 {
                    coordinator.noteConfigurationChange()
                    clock.advance(0.2)
                    coordinator.tick()
                }
                // Burst settles; one rebuild happens against the settled device.
                clock.advance(0.5)
                coordinator.tick()
                expect.equal(coordinator.restartCount, 1)

                // The profile switch takes 2.44 s of real hardware silence. The
                // grace window covers the first 1.5 s of it; after that the
                // watchdog fires once, which is a recovery attempt, not a storm.
                clock.advance(2.44)
                coordinator.tick()
                coordinator.noteBufferArrived(hostTime: clock.monotonicSeconds)
                expect.isTrue(coordinator.restartCount <= 2, "got \(coordinator.restartCount) rebuilds")
                expect.equal(coordinator.health, .healthy)
                expect.equal(coordinator.activeFormat, AudioFormatDescriptor(sampleRate: 16_000, channelCount: 1))
                expect.isTrue(
                    delegate.formatChanges.contains { $0.to.sampleRate == 16_000 },
                    "the 16 kHz switch must reach the manifest"
                )
            },

            test("wake rebuilds proactively after the settle delay") { expect in
                let engine = FakeMicrophoneEngine()
                let clock = ManualClock()
                let coordinator = MicrophoneRecoveryCoordinator(
                    controller: engine, clock: clock, delegate: RecordingCaptureDelegate()
                )
                coordinator.start()
                coordinator.noteBufferArrived(hostTime: clock.monotonicSeconds)
                coordinator.noteWake()

                clock.advance(1.0)
                coordinator.tick()
                expect.equal(coordinator.restartCount, 0, "must wait for the audio stack to settle")

                clock.advance(0.6)
                coordinator.tick()
                expect.equal(coordinator.restartCount, 1)
            },

            test("a looping rebuild is warned about, a single one is not") { expect in
                let engine = FakeMicrophoneEngine()
                let clock = ManualClock()
                let coordinator = MicrophoneRecoveryCoordinator(
                    controller: engine, clock: clock, delegate: RecordingCaptureDelegate()
                )
                coordinator.start()
                coordinator.noteBufferArrived(hostTime: clock.monotonicSeconds)

                // One device switch that recovers is normal and silent.
                coordinator.noteConfigurationChange()
                clock.advance(0.5)
                coordinator.tick()
                coordinator.noteBufferArrived(hostTime: clock.monotonicSeconds)
                expect.equal(coordinator.warnings(), [])

                // Four rebuilds inside a minute is a loop.
                for _ in 0..<4 {
                    coordinator.noteConfigurationChange()
                    clock.advance(0.5)
                    coordinator.tick()
                    coordinator.noteBufferArrived(hostTime: clock.monotonicSeconds)
                }
                let warnings = coordinator.warnings()
                expect.isTrue(
                    warnings.contains { if case .rebuildLoop = $0 { true } else { false } },
                    "expected a rebuild-loop warning, got \(warnings)"
                )
            },

            test("an unrecovered microphone warns after five seconds") { expect in
                let engine = FakeMicrophoneEngine()
                let clock = ManualClock()
                let coordinator = MicrophoneRecoveryCoordinator(
                    controller: engine, clock: clock, delegate: RecordingCaptureDelegate()
                )
                engine.setSteadyFormat(nil)
                coordinator.start()
                expect.equal(coordinator.health, .degraded)

                clock.advance(3.0)
                expect.equal(coordinator.warnings(), [])
                clock.advance(3.0)
                let warnings = coordinator.warnings()
                expect.isTrue(
                    warnings.contains { if case .microphoneUnrecovered = $0 { true } else { false } },
                    "expected an unrecovered warning, got \(warnings)"
                )
            },

            test("a failed build is retried on the next poll") { expect in
                let engine = FakeMicrophoneEngine()
                let clock = ManualClock()
                let delegate = RecordingCaptureDelegate()
                let coordinator = MicrophoneRecoveryCoordinator(
                    controller: engine, clock: clock, delegate: delegate
                )
                engine.failNextBuild(with: .microphoneEngineStartFailed(status: -10_875))
                coordinator.start()
                expect.equal(coordinator.health, .failed)
                expect.equal(delegate.failures.count, 1)

                clock.advance(0.5)
                coordinator.tick()
                coordinator.noteBufferArrived(hostTime: clock.monotonicSeconds)
                expect.equal(coordinator.health, .healthy)
                expect.equal(engine.buildCount, 1, "the failed attempt built nothing")
            },

            test("a device that stays away is retried a few times a minute") { expect in
                // Every attempt writes health transitions to the manifest, and each
                // of those is an fsync. Retrying twice a second against a device
                // that is simply gone wrote tens of thousands of lines an hour.
                let engine = FakeMicrophoneEngine()
                let clock = ManualClock()
                let coordinator = MicrophoneRecoveryCoordinator(
                    controller: engine, clock: clock, delegate: RecordingCaptureDelegate()
                )
                engine.failEveryBuild(with: .microphoneEngineStartFailed(status: -10_875))
                coordinator.start()
                expect.equal(engine.buildCount, 1)

                // Five minutes of polling twice a second.
                for _ in 0..<600 {
                    clock.advance(0.5)
                    coordinator.tick()
                }
                expect.isTrue(
                    engine.buildCount < 30,
                    "\(engine.buildCount) attempts in five minutes is a retry storm"
                )
                expect.isTrue(engine.buildCount > 5, "it must keep trying: \(engine.buildCount)")

                // The device comes back and the next attempt succeeds.
                engine.stopFailing()
                clock.advance(30)
                coordinator.tick()
                coordinator.noteBufferArrived(hostTime: clock.monotonicSeconds)
                expect.equal(coordinator.health, .healthy)
            },
        ])
    }

    static var remoteSuite: Suite {
        Suite("RemoteRecoveryPolicy", [
            test("a bound but silent application stays healthy-idle") { expect in
                var policy = RemoteRecoveryPolicy()
                var now = 100.0
                let targets = [makeTarget(pid: 900, producing: false)]
                policy.start()
                policy.noteBound(to: targets, at: now)

                // Sixty seconds with no callbacks at all, which is exactly what a
                // tap on an idle application delivers.
                for _ in 0..<120 {
                    now += 0.5
                    expect.equal(policy.evaluate(targets: targets, at: now), .none)
                }
                expect.equal(policy.health, .idleButBound)
                expect.equal(policy.bindCount, 1)
            },

            test("a producing application with no callbacks is rebound") { expect in
                var policy = RemoteRecoveryPolicy()
                var now = 100.0
                let idle = [makeTarget(pid: 900, producing: false)]
                let producing = [makeTarget(pid: 900, producing: true)]
                policy.start()
                policy.noteBound(to: idle, at: now)
                now += 1.0
                _ = policy.evaluate(targets: idle, at: now)
                policy.noteBufferArrived(at: now)

                // The application starts playing meeting audio and our callbacks die.
                var decision = RemoteRecoveryPolicy.Decision.none
                for _ in 0..<12 {
                    now += 0.5
                    decision = policy.evaluate(targets: producing, at: now)
                    if case .bind = decision { break }
                }
                guard case .bind(.producingWithoutCallbacks) = decision else {
                    expect.fail("expected a rebind once output ran without callbacks, got \(decision)")
                    return
                }
                expect.isTrue(now - 100.0 > 5.0, "must not fire before the 5 s threshold")
            },

            test("a replaced target process rebinds without ending the meeting") { expect in
                var policy = RemoteRecoveryPolicy()
                var now = 100.0
                policy.start()
                policy.noteBound(to: [makeTarget(pid: 63_100, producing: true)], at: now)
                policy.noteBufferArrived(at: now)

                // Firefox quits. Source absence, reported as degraded, polling continues.
                now += 0.5
                expect.equal(policy.evaluate(targets: [], at: now), .none)
                expect.equal(policy.health, .degraded)

                // Firefox comes back under a new PID.
                now += 6.0
                let replacement = [makeTarget(pid: 63_373, producing: true)]
                guard case .bind(.targetChanged) = policy.evaluate(targets: replacement, at: now) else {
                    expect.fail("a new matching process must rebind")
                    return
                }
                policy.noteBound(to: replacement, at: now)
                policy.noteBufferArrived(at: now)
                expect.equal(policy.health, .healthy)
                expect.equal(policy.boundProcessIDs, [63_373])
            },

            test("a target appearing after none existed binds immediately") { expect in
                var policy = RemoteRecoveryPolicy()
                var now = 100.0
                policy.start()
                policy.noteBound(to: [], at: now)
                expect.equal(policy.health, .degraded)

                now += 0.5
                expect.equal(policy.evaluate(targets: [], at: now), .none)

                now += 0.5
                let appeared = [makeTarget(pid: 4_242, bundle: "com.tinyspeck.slackmacgap.helper")]
                guard case .bind(.targetAppeared) = policy.evaluate(targets: appeared, at: now) else {
                    expect.fail("expected a bind when a matching process appeared")
                    return
                }
            },
        ])
    }

    static var remoteCoordinatorSuite: Suite {
        Suite("RemoteTapCoordinator", [
            test("Slack audio binds to the helper process, not the main bundle") { expect in
                let tap = FakeProcessTap()
                let clock = ManualClock()
                let coordinator = RemoteTapCoordinator(
                    controller: tap, clock: clock, delegate: RecordingCaptureDelegate()
                )
                tap.setTargets([
                    makeTarget(pid: 500, bundle: "com.tinyspeck.slackmacgap", producing: false),
                    makeTarget(pid: 501, bundle: "com.tinyspeck.slackmacgap.helper", producing: true),
                ])
                coordinator.start(bundlePrefixes: ["com.tinyspeck.slackmacgap"])

                // Prefix matching binds both, which is what makes the helper's audio
                // reachable without hardcoding which process holds it.
                expect.equal(coordinator.boundProcessIDs, [500, 501])
                expect.equal(tap.bindCount, 1)
            },

            test("Firefox restart rebinds to the new process") { expect in
                let tap = FakeProcessTap()
                let clock = ManualClock()
                let delegate = RecordingCaptureDelegate()
                let coordinator = RemoteTapCoordinator(controller: tap, clock: clock, delegate: delegate)
                tap.setTargets([makeTarget(pid: 63_100, producing: true)])
                coordinator.start(bundlePrefixes: ["org.mozilla.firefox"])
                coordinator.noteBufferArrived(hostTime: clock.monotonicSeconds)
                expect.equal(coordinator.health, .healthy)

                tap.setTargets([])
                clock.advance(0.5)
                coordinator.tick()
                expect.equal(coordinator.health, .degraded, "target gone must not read as healthy")

                tap.setTargets([makeTarget(pid: 63_373, producing: true)])
                clock.advance(0.5)
                coordinator.tick()
                expect.equal(coordinator.boundProcessIDs, [63_373])
                coordinator.noteBufferArrived(hostTime: clock.monotonicSeconds)
                expect.equal(coordinator.health, .healthy)
                expect.equal(tap.bindCount, 2)
            },

            test("a silent remote source never emits a warning") { expect in
                let tap = FakeProcessTap()
                let clock = ManualClock()
                let coordinator = RemoteTapCoordinator(
                    controller: tap, clock: clock, delegate: RecordingCaptureDelegate()
                )
                tap.setTargets([makeTarget(pid: 900, producing: false)])
                coordinator.start(bundlePrefixes: ["org.mozilla.firefox"])
                for _ in 0..<200 {
                    clock.advance(0.5)
                    coordinator.tick()
                }
                expect.equal(coordinator.health, .idleButBound)
                expect.equal(coordinator.warnings(), [])
                expect.equal(tap.bindCount, 1, "a silent app must not be rebound")
            },
        ])
    }

    static var all: [Suite] {
        [micPolicySuite, micCoordinatorSuite, remoteSuite, remoteCoordinatorSuite]
    }
}
