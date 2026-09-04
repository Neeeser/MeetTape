import Foundation
import PipitCore
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
                // previous good format is kept rather than adopted. Asserting
                // the format alone was not enough: it is equally unchanged when
                // the rebuild finds no usable device and builds nothing at all,
                // which is what deleting the fallback does.
                expect.equal(engine.buildCount, 2, "the rebuild built, rather than giving up on the device")
                expect.equal(
                    engine.builds.last?.format,
                    AudioFormatDescriptor(sampleRate: 48_000, channelCount: 3),
                    "against the last good format"
                )
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

            test("an engine that builds and delivers nothing is not rebuilt forever") { expect in
                // Measured on a Mac whose default output was an 8-channel virtual
                // device: the engine built without error, reported a format,
                // delivered 0.09 s of audio and then nothing, and each rebuild
                // produced another configuration change. 119 rebuilds in four
                // minutes. The cause that time was the voice-processing unit,
                // since removed; a driver that opens muted or a virtual input
                // produces the same shape, and the bound has to hold whatever
                // is behind it.
                //
                // A build that throws already backs off. One that succeeds and
                // then never delivers did not, because success cleared the
                // backoff on every attempt.
                let engine = FakeMicrophoneEngine()
                let clock = ManualClock()
                let coordinator = MicrophoneRecoveryCoordinator(
                    controller: engine, clock: clock, delegate: RecordingCaptureDelegate()
                )
                coordinator.start()

                // Sixty seconds of polling with not one buffer.
                for _ in 0..<120 {
                    clock.advance(0.5)
                    coordinator.tick()
                }

                // Unbounded, this is a rebuild every 1.5 s, each one restarting
                // the grace window: 38 in a minute, measured. Three immediate
                // attempts and then a doubling wait capped at the ceiling is
                // under a dozen.
                expect.isTrue(
                    coordinator.restartCount <= 12,
                    "rebuilding into the same silent engine is the storm: got \(coordinator.restartCount)"
                )
                expect.isTrue(
                    coordinator.restartCount >= 3,
                    "it still tries before it waits: got \(coordinator.restartCount)"
                )
                expect.notEqual(coordinator.health, .healthy, "nothing arrived, so nothing is healthy")
                expect.isTrue(
                    coordinator.health.isLosingAudio,
                    "and it says so: recovering is the grace window, not the whole silence, got \(coordinator.health)"
                )
                expect.isTrue(
                    coordinator.warnings().contains {
                        if case .microphoneUnrecovered = $0 { return true }
                        return false
                    },
                    "and the user is told, rather than the loop running quietly"
                )

                // The first buffer ends it. Health alone would not show that,
                // because a buffer marks the engine healthy whether or not the
                // wait was released, so the pin is a rebuild that the wait would
                // otherwise refuse: audio arrives, stops again, and the watchdog
                // must be allowed to act rather than sit behind a 16 s wait.
                coordinator.noteBufferArrived(hostTime: clock.monotonicSeconds)
                clock.advance(0.5)
                coordinator.tick()
                expect.equal(coordinator.health, .healthy)
                let released = coordinator.restartCount
                clock.advance(2.5)
                coordinator.tick()
                expect.equal(
                    coordinator.restartCount, released + 1,
                    "the buffer released the wait, so the watchdog rebuilds"
                )
            },

            test("a rebuild's own configuration change does not reopen the loop") { expect in
                // On the device the bound was measured against, each rebuild
                // was followed by a configuration change, so each rebuild
                // produced the notification that justified the next one. That
                // was seen with the voice-processing unit installed and may not
                // survive its removal, so this pins the shape rather than the
                // device. A configuration change ordinarily clears every wait,
                // because hardware that changed may be hardware that came back,
                // so the loop's own footprint cleared the bound at the debounce
                // cadence, faster than the watchdog storm it was meant to stop.
                let engine = FakeMicrophoneEngine()
                let clock = ManualClock()
                let coordinator = MicrophoneRecoveryCoordinator(
                    controller: engine, clock: clock, delegate: RecordingCaptureDelegate()
                )
                coordinator.start()

                for _ in 0..<120 {
                    clock.advance(0.5)
                    coordinator.tick()
                    // What the engine's own rebuild sends back.
                    coordinator.noteConfigurationChange()
                }

                expect.isTrue(
                    coordinator.restartCount <= 12,
                    "the loop's own footprint must not clear its bound: got \(coordinator.restartCount)"
                )
                expect.isTrue(
                    coordinator.restartCount >= 3,
                    "it still tries before it waits: got \(coordinator.restartCount)"
                )
            },

            test("a device that returns while builds are failing is rebuilt on the next poll") { expect in
                // The wait a silent engine earns is released by its first buffer.
                // A failed build earns a wait too, and no buffer can ever release
                // that one, because no engine exists. Counting failed builds as
                // silent rebuilds made the configuration-change guard hold the
                // failure wait as well: a USB microphone unplugged mid-meeting
                // climbed the backoff to its 30 s ceiling, and when it was
                // plugged back in the notification was refused and capture
                // resumed up to half a minute later. Before this branch it was
                // one poll.
                let engine = FakeMicrophoneEngine()
                let clock = ManualClock()
                let delegate = RecordingCaptureDelegate()
                let coordinator = MicrophoneRecoveryCoordinator(
                    controller: engine, clock: clock, delegate: delegate
                )
                engine.failEveryBuild(with: .microphoneEngineStartFailed(status: -1))
                coordinator.start()
                for _ in 0..<60 {
                    clock.advance(0.5)
                    coordinator.tick()
                }
                expect.isTrue(coordinator.restartCount >= 3, "several failures have climbed the backoff")
                expect.isFalse(engine.isRunning)

                // Plugged back in: the hardware says so, once.
                engine.stopFailing()
                coordinator.noteConfigurationChange()
                let before = coordinator.restartCount
                clock.advance(0.5)
                coordinator.tick()
                expect.equal(
                    coordinator.restartCount, before + 1,
                    "a device that came back is not held behind a wait no buffer can release"
                )
                expect.isTrue(engine.isRunning)
                expect.isTrue(
                    delegate.restarts.last?.reason.hasPrefix("config_change") == true,
                    "recorded as the device change it was, got \(delegate.restarts.last?.reason ?? "none")"
                )
                // And once. A retry left standing from the failure would tear
                // this working engine down again on the very next poll.
                clock.advance(0.5)
                coordinator.tick()
                expect.equal(
                    coordinator.restartCount, before + 1,
                    "the new engine is not torn down again by a stale retry"
                )
            },

            test("a silent engine that is then unplugged is rebuilt the poll the device returns") { expect in
                // The silent engine's wait holds through configuration changes,
                // because on the motivating device the rebuild emitted them.
                // That hold must belong to the silent engine and end with it. A
                // virtual input that built cleanly and delivered nothing for
                // long enough to latch the hold, then unplugged, left the hold
                // asserting a silent engine through a run of failed builds, and
                // the microphone plugged in to replace it was refused for up to
                // thirty seconds. The build that threw is what ends the claim:
                // whatever was silent is gone.
                let engine = FakeMicrophoneEngine()
                let clock = ManualClock()
                let coordinator = MicrophoneRecoveryCoordinator(
                    controller: engine, clock: clock, delegate: RecordingCaptureDelegate()
                )
                coordinator.start()
                for _ in 0..<60 {
                    clock.advance(0.5)
                    coordinator.tick()
                }
                expect.isTrue(coordinator.restartCount >= 3, "the silent hold is latched")

                engine.failEveryBuild(with: .microphoneEngineStartFailed(status: -1))
                for _ in 0..<80 {
                    clock.advance(0.5)
                    coordinator.tick()
                }
                expect.isFalse(engine.isRunning)

                engine.stopFailing()
                coordinator.noteConfigurationChange()
                let before = coordinator.restartCount
                clock.advance(0.5)
                coordinator.tick()
                expect.equal(
                    coordinator.restartCount, before + 1,
                    "the device that returned is rebuilt now, not after the silent engine's wait"
                )
                expect.isTrue(engine.isRunning)
            },

            test("a wake that follows a failed build does not tear the new engine down again") { expect in
                // Waking rebuilds once the audio stack settles. When the build
                // before the wake had failed, the retry that failure scheduled
                // was still on the books after the wake's build succeeded, and
                // it fired on the next poll against a half-second-old working
                // engine. A build that succeeded has nothing to retry.
                let engine = FakeMicrophoneEngine()
                let clock = ManualClock()
                let delegate = RecordingCaptureDelegate()
                let coordinator = MicrophoneRecoveryCoordinator(
                    controller: engine, clock: clock, delegate: delegate
                )
                engine.failEveryBuild(with: .microphoneEngineStartFailed(status: -1))
                coordinator.start()
                for _ in 0..<10 {
                    clock.advance(0.5)
                    coordinator.tick()
                }
                expect.isFalse(engine.isRunning)

                engine.stopFailing()
                coordinator.noteWake()
                clock.advance(1.6)
                coordinator.tick()
                expect.isTrue(engine.isRunning, "the wake rebuilt, and the device is back")
                expect.equal(delegate.restarts.last?.reason, "wake")

                let after = coordinator.restartCount
                clock.advance(0.5)
                coordinator.tick()
                expect.equal(
                    coordinator.restartCount, after,
                    "no retry is owed for a build that succeeded"
                )
                expect.isTrue(engine.isRunning)
            },

            test("a configuration change refused during the wait is taken when it expires") { expect in
                // `evaluate` consumes the pending flag to return the decision. If
                // the wait refuses it, nothing re-derives it: the watchdog and
                // first-buffer decisions rebuild themselves from the gap on the
                // next poll, a configuration change does not. Re-arming it is
                // what keeps the rebuild at expiry recorded for what it was, so
                // the manifest says a device changed rather than that a buffer
                // never came.
                let engine = FakeMicrophoneEngine()
                let clock = ManualClock()
                let delegate = RecordingCaptureDelegate()
                let coordinator = MicrophoneRecoveryCoordinator(
                    controller: engine, clock: clock, delegate: delegate
                )
                coordinator.start()
                // Twenty silent seconds: the wait is several seconds long by now.
                for _ in 0..<40 {
                    clock.advance(0.5)
                    coordinator.tick()
                }
                let restartsBefore = delegate.restarts.count
                coordinator.noteConfigurationChange()
                // Through the rest of the wait and one poll past its expiry.
                for _ in 0..<12 {
                    clock.advance(0.5)
                    coordinator.tick()
                }
                expect.equal(
                    delegate.restarts.count, restartsBefore + 1,
                    "exactly one rebuild inside the window: at expiry, not before"
                )
                expect.isTrue(
                    delegate.restarts.last?.reason.hasPrefix("config_change") == true,
                    "and it is recorded as the device change it was, got \(delegate.restarts.last?.reason ?? "none")"
                )
            },

            test("a wake with a latched silent count does not hold the new engine") { expect in
                // The wake clears the wait, because the audio stack
                // re-enumerated and whatever was waiting was waiting on an
                // engine that is gone. It did not clear the count the wait is
                // derived from, so the wake's own rebuild found the count at
                // the ceiling and installed the thirty-second wait the wake had
                // just removed, against an engine half a second old.
                let engine = FakeMicrophoneEngine()
                let clock = ManualClock()
                let coordinator = MicrophoneRecoveryCoordinator(
                    controller: engine, clock: clock, delegate: RecordingCaptureDelegate()
                )
                coordinator.start()
                for _ in 0..<120 {
                    clock.advance(0.5)
                    coordinator.tick()
                }
                expect.isTrue(coordinator.restartCount >= 3, "the silent count is latched")

                coordinator.noteWake()
                clock.advance(1.6)
                coordinator.tick()
                let afterWake = coordinator.restartCount

                // Still silent, so it is rebuilt again, and soon: the count
                // starts over at the wake rather than resuming at the ceiling.
                for _ in 0..<12 {
                    clock.advance(0.5)
                    coordinator.tick()
                }
                expect.isTrue(
                    coordinator.restartCount > afterWake,
                    "a fresh engine is not held for the ceiling on the poll after a wake"
                )
            },

            test("a different device plugged in during a silent wait is taken at once") { expect in
                // The silent engine's wait refuses configuration changes because
                // the rebuild's own footprint arrives as one. The footprint is
                // the same device. A change from a different device is the user
                // plugging one in, and refusing it held a working microphone for
                // up to thirty seconds behind a wait that belonged to the device
                // it replaced.
                //
                // Same format on both sides, on purpose. Most microphones on
                // most Macs read 48 kHz at one channel, so a swap that had to
                // change the format to be noticed was noticed on none of them.
                let engine = FakeMicrophoneEngine()
                let clock = ManualClock()
                let coordinator = MicrophoneRecoveryCoordinator(
                    controller: engine, clock: clock, delegate: RecordingCaptureDelegate()
                )
                engine.setDeviceUID("builtin-mic")
                coordinator.start()
                for _ in 0..<120 {
                    clock.advance(0.5)
                    coordinator.tick()
                }
                expect.isTrue(coordinator.restartCount >= 3, "the silent wait is latched")

                engine.setDeviceUID("usb-mic")
                coordinator.noteConfigurationChange()
                let before = coordinator.restartCount
                clock.advance(0.5)
                coordinator.tick()
                expect.equal(coordinator.restartCount, before + 1, "the new device is built now")

                // And it starts from nothing. Whatever was silent was the other
                // device; carried across, this one's first build re-latched the
                // wait at the ceiling before it had been silent for a single
                // grace window.
                for _ in 0..<16 {
                    clock.advance(0.5)
                    coordinator.tick()
                }
                expect.isTrue(
                    coordinator.restartCount >= before + 3,
                    "the new device's silence is counted from zero: got \(coordinator.restartCount - before) rebuilds in 8 s"
                )
            },

            test("a device renegotiating its format during a silent wait is still the footprint") { expect in
                // The other direction of the same discriminator. A device that
                // reads a different rate on every rebuild is one device, not a
                // new one each time; told apart by format it cleared the silent
                // wait on every footprint change and the loop ran at the
                // debounce cadence again, which is the storm the wait exists to
                // stop. Told apart by identity it is refused like any footprint.
                let engine = FakeMicrophoneEngine()
                let clock = ManualClock()
                let coordinator = MicrophoneRecoveryCoordinator(
                    controller: engine, clock: clock, delegate: RecordingCaptureDelegate()
                )
                engine.setDeviceUID("bluetooth-headset")
                coordinator.start()
                let rates: [Double] = [48_000, 44_100, 16_000]
                for i in 0..<120 {
                    clock.advance(0.5)
                    coordinator.tick()
                    engine.setSteadyFormat(AudioFormatDescriptor(sampleRate: rates[i % 3], channelCount: 1))
                    coordinator.noteConfigurationChange()
                }
                expect.isTrue(
                    coordinator.restartCount <= 12,
                    "a format that moves is not a new device: got \(coordinator.restartCount)"
                )
            },

            test("a buffer flushed by a failing open does not reset the failure backoff") { expect in
                // A driver that flushes one buffer while the device is being
                // opened delivers it inside the build, after the retry has
                // cleared the previous wait and before the throw installs the
                // next. Guarding the buffer on the wait's cause missed that
                // window entirely: the count was zeroed on every attempt, the
                // next failure started again at a half-second step, and 600
                // attempts landed in five minutes with the microphone reported
                // healthy throughout. No engine exists during a build. A buffer
                // with no engine installed is evidence of nothing.
                let engine = FakeMicrophoneEngine()
                let clock = ManualClock()
                let coordinator = MicrophoneRecoveryCoordinator(
                    controller: engine, clock: clock, delegate: RecordingCaptureDelegate()
                )
                engine.failEveryBuild(with: .microphoneEngineStartFailed(status: -10_875))
                engine.setDuringBuild { coordinator.noteBufferArrived(hostTime: clock.monotonicSeconds) }
                coordinator.start()
                for _ in 0..<600 {
                    clock.advance(0.5)
                    coordinator.tick()
                }
                expect.isTrue(
                    engine.buildCount < 30,
                    "\(engine.buildCount) attempts in five minutes is the storm the backoff exists to stop"
                )
                expect.notEqual(coordinator.health, .healthy, "a microphone that never built is not healthy")
                expect.isTrue(
                    coordinator.warnings().contains {
                        if case .microphoneUnrecovered = $0 { return true }
                        return false
                    },
                    "and the user is told"
                )
            },

            test("a microphone that is gone reports failed, not recovering") { expect in
                // The policy's health said a rebuild was in flight because the
                // timestamp that says so was cleared only by a buffer, and a
                // build that threw never delivers one. Every poll overwrote the
                // failure the coordinator had just recorded with `.recovering`,
                // which does not count as losing audio, so the menu bar showed
                // the ordinary recording icon for a microphone that was simply
                // gone. With no engine installed the coordinator's verdict
                // stands.
                let engine = FakeMicrophoneEngine()
                let clock = ManualClock()
                let coordinator = MicrophoneRecoveryCoordinator(
                    controller: engine, clock: clock, delegate: RecordingCaptureDelegate()
                )
                engine.failEveryBuild(with: .microphoneEngineStartFailed(status: -10_875))
                coordinator.start()
                expect.equal(coordinator.health, .failed)
                for _ in 0..<20 {
                    clock.advance(0.5)
                    coordinator.tick()
                    expect.equal(coordinator.health, .failed, "not overwritten by a poll")
                }
                expect.isTrue(coordinator.health.isLosingAudio, "the icon that says audio is being lost lights")
            },

            test("after a device returns, silence is counted from zero") { expect in
                // A build that throws ends whatever the silent count said: the
                // engine it described is gone. Without that, the device that
                // returned inherited the count, its first successful build read
                // as the fourth silent one, and it was held for the ceiling
                // before it had been silent for a single grace window.
                let engine = FakeMicrophoneEngine()
                let clock = ManualClock()
                let coordinator = MicrophoneRecoveryCoordinator(
                    controller: engine, clock: clock, delegate: RecordingCaptureDelegate()
                )
                coordinator.start()
                for _ in 0..<60 {
                    clock.advance(0.5)
                    coordinator.tick()
                }
                engine.failEveryBuild(with: .microphoneEngineStartFailed(status: -1))
                for _ in 0..<20 {
                    clock.advance(0.5)
                    coordinator.tick()
                }
                engine.stopFailing()
                coordinator.noteConfigurationChange()
                clock.advance(0.5)
                coordinator.tick()
                expect.isTrue(engine.isRunning, "the returned device built")
                let returned = coordinator.restartCount

                // Silent again, so it is rebuilt again, at the grace cadence: the
                // count starts over rather than resuming where the old engine's
                // left off.
                for _ in 0..<12 {
                    clock.advance(0.5)
                    coordinator.tick()
                }
                expect.isTrue(
                    coordinator.restartCount > returned,
                    "the new engine is not held for the ceiling on its first silence"
                )
            },

            test("a buffer flushed during teardown is not evidence for the new build") { expect in
                // A rebuild decided is an engine being replaced. A driver that
                // flushes one buffer as the tap is removed delivers it after the
                // rebuild has begun and before the new build exists. Recorded,
                // it cleared the grace window the new build had just been given,
                // zeroed the silent count and the failure count, and released
                // the silent engine's wait: 23 rebuilds in a minute against a
                // bound of twelve, through a door the in-build hook does not
                // reach. The fact that an engine exists is false from the
                // moment the rebuild is committed to, not from the moment the
                // teardown returns.
                let engine = FakeMicrophoneEngine()
                let clock = ManualClock()
                let coordinator = MicrophoneRecoveryCoordinator(
                    controller: engine, clock: clock, delegate: RecordingCaptureDelegate()
                )
                engine.setDuringTeardown { coordinator.noteBufferArrived(hostTime: clock.monotonicSeconds) }
                coordinator.start()
                for _ in 0..<120 {
                    clock.advance(0.5)
                    coordinator.tick()
                }
                expect.isTrue(
                    coordinator.restartCount <= 12,
                    "a teardown's flushed buffer must not reopen the loop: got \(coordinator.restartCount)"
                )
            },

            test("a device the system cannot name is refused, not admitted") { expect in
                // The admission compares identities. Where the system cannot
                // name the current device, there is nothing to compare, and the
                // safe reading is that nothing changed: the wait holds and the
                // change is re-armed, which costs one debounce per poll rather
                // than the ceiling. Read as "different from the recorded name",
                // a missing name admitted every refused change.
                let engine = FakeMicrophoneEngine()
                let clock = ManualClock()
                let coordinator = MicrophoneRecoveryCoordinator(
                    controller: engine, clock: clock, delegate: RecordingCaptureDelegate()
                )
                engine.setDeviceUID("builtin-mic")
                coordinator.start()
                for _ in 0..<120 {
                    clock.advance(0.5)
                    coordinator.tick()
                }
                expect.isTrue(coordinator.restartCount >= 3, "the silent wait is latched")

                engine.setDeviceUID(nil)
                coordinator.noteConfigurationChange()
                let before = coordinator.restartCount
                clock.advance(0.5)
                coordinator.tick()
                expect.equal(coordinator.restartCount, before, "nothing to compare, so the wait holds")

                // And a device it can name, and which differs, is admitted.
                engine.setDeviceUID("usb-mic")
                coordinator.noteConfigurationChange()
                clock.advance(0.5)
                coordinator.tick()
                expect.equal(coordinator.restartCount, before + 1, "a named, different device is built now")
            },

            test("a build that throws under a pending change is retried by the change, once") { expect in
                // A configuration change clears a failed build's wait when it
                // arrives. One that arrived first had nothing to clear, and the
                // wait installed after it was one no change would end: the retry
                // consumed it as `manual`, and the change, still pending, tore
                // the new engine down on the following poll. The ordering is a
                // wake whose rebuild throws while a change from the settle
                // window is still in its debounce.
                let engine = FakeMicrophoneEngine()
                let clock = ManualClock()
                let delegate = RecordingCaptureDelegate()
                let coordinator = MicrophoneRecoveryCoordinator(
                    controller: engine, clock: clock, delegate: delegate
                )
                coordinator.start()
                coordinator.noteBufferArrived(hostTime: clock.monotonicSeconds)

                coordinator.noteWake()
                clock.advance(1.4)
                // The change lands inside the settle window, so it is pending
                // and in its debounce when the wake rebuild runs and throws.
                coordinator.noteConfigurationChange()
                engine.failNextBuild(with: .microphoneEngineStartFailed(status: -1))
                clock.advance(0.2)
                coordinator.tick()
                expect.equal(delegate.restarts.last?.reason, "wake")
                expect.isFalse(engine.isRunning, "the wake rebuild threw")
                let afterThrow = delegate.restarts.count

                // The change's own rebuild, and then nothing: no manual retry
                // ahead of it, no second teardown behind it. The device is back,
                // so the engine it builds delivers.
                for _ in 0..<4 {
                    clock.advance(0.5)
                    coordinator.tick()
                    if engine.isRunning { coordinator.noteBufferArrived(hostTime: clock.monotonicSeconds) }
                }
                expect.equal(
                    delegate.restarts.count, afterThrow + 1,
                    "one rebuild after the throw: got \(delegate.restarts.dropFirst(afterThrow).map(\.reason))"
                )
                expect.isTrue(
                    delegate.restarts.last?.reason.hasPrefix("config_change") == true,
                    "and it is the change's, got \(delegate.restarts.last?.reason ?? "none")"
                )
                expect.isTrue(engine.isRunning)
                expect.equal(coordinator.health, .healthy)
            },

            test("a buffer stamped before the rebuild is not the new engine's") { expect in
                // A buffer already in flight on the render thread while the old
                // tap is removed can reach the lock after the new build has been
                // recorded. It carries the old engine's timestamp. Counted as
                // the new engine's, it zeroed the silent count, released the
                // silent engine's wait and marked the microphone healthy, once
                // per rebuild: 119 rebuilds in a minute, the figure the bound
                // exists to prevent, through the one door that does not close
                // synchronously.
                let engine = FakeMicrophoneEngine()
                let clock = ManualClock()
                let coordinator = MicrophoneRecoveryCoordinator(
                    controller: engine, clock: clock, delegate: RecordingCaptureDelegate()
                )
                coordinator.start()
                var rebuilds = coordinator.restartCount
                for _ in 0..<120 {
                    clock.advance(0.5)
                    coordinator.tick()
                    // After each rebuild, one buffer the old tap had in flight:
                    // it reaches the lock now, stamped from before the rebuild
                    // was committed to.
                    if coordinator.restartCount != rebuilds {
                        rebuilds = coordinator.restartCount
                        coordinator.noteBufferArrived(hostTime: clock.monotonicSeconds - 0.6)
                    }
                }
                expect.isTrue(
                    coordinator.restartCount <= 12,
                    "a stale buffer must not read as the new engine delivering: got \(coordinator.restartCount)"
                )
                expect.notEqual(coordinator.health, .healthy, "nothing this engine produced has arrived")
            },

            test("a change emitted by a failing open does not forgive the failure") { expect in
                // A change that arrived before a build failed may mean the
                // device is back, and it clears the failure's wait. One that
                // arrives during the failing build was emitted by the open
                // itself, on the device that motivated this, and honouring it
                // let every failure forgive itself: 601 builds in five minutes.
                // It stays pending, is refused by the wait, and is taken when
                // the wait expires.
                let engine = FakeMicrophoneEngine()
                let clock = ManualClock()
                let delegate = RecordingCaptureDelegate()
                let coordinator = MicrophoneRecoveryCoordinator(
                    controller: engine, clock: clock, delegate: delegate
                )
                engine.failEveryBuild(with: .microphoneEngineStartFailed(status: -10_875))
                engine.setDuringBuild { coordinator.noteConfigurationChange() }
                coordinator.start()
                for _ in 0..<600 {
                    clock.advance(0.5)
                    coordinator.tick()
                }
                expect.isTrue(
                    engine.buildCount < 30,
                    "\(engine.buildCount) attempts in five minutes is the storm the backoff exists to stop"
                )
                // Each retry is the pending change's, and the manifest says so.
                // Taken by the failed-build retry first it was filed as manual.
                let reasons = delegate.restarts.map(\.reason)
                expect.isTrue(
                    !reasons.contains("manual"),
                    "a rebuild a change is waiting on is recorded as the change's: got \(reasons)"
                )
            },

            test("a wake answers the change that arrived while it settled") { expect in
                // The wake rebuild reads the device fresh, which is all a
                // configuration change asks for. Left pending, the change
                // rebuilt the engine the wake had just built, half a second
                // old, for nothing.
                let engine = FakeMicrophoneEngine()
                let clock = ManualClock()
                let delegate = RecordingCaptureDelegate()
                let coordinator = MicrophoneRecoveryCoordinator(
                    controller: engine, clock: clock, delegate: delegate
                )
                coordinator.start()
                coordinator.noteBufferArrived(hostTime: clock.monotonicSeconds)
                coordinator.noteWake()
                clock.advance(1.0)
                coordinator.noteConfigurationChange()
                clock.advance(0.6)
                coordinator.tick()
                expect.equal(delegate.restarts.map(\.reason), ["wake"])
                for _ in 0..<4 {
                    clock.advance(0.5)
                    coordinator.tick()
                    coordinator.noteBufferArrived(hostTime: clock.monotonicSeconds)
                }
                expect.equal(delegate.restarts.map(\.reason), ["wake"], "one rebuild, the wake's")
                expect.equal(coordinator.health, .healthy)
            },

            test("the silent wait doubles from the threshold and stops at the ceiling") { expect in
                // The bounds elsewhere pass for any wait between a few seconds
                // and the ceiling. This is the schedule itself: three rebuilds
                // at the grace cadence, then one poll interval past the
                // threshold, doubling, capped. A changed constant fails here
                // and nowhere else, which is the point.
                let engine = FakeMicrophoneEngine()
                let clock = ManualClock()
                let delegate = RecordingCaptureDelegate()
                let coordinator = MicrophoneRecoveryCoordinator(
                    controller: engine, clock: clock, delegate: delegate
                )
                coordinator.start()
                var seen: [Int: Int] = [:]
                for i in 1...120 {
                    clock.advance(0.5)
                    coordinator.tick()
                    if [20, 40, 80, 120].contains(i) { seen[i] = coordinator.restartCount }
                }
                // The first buffer is owed at 3.5 s (timeout plus grace), so the
                // first rebuild is at 4.0, and each one restarts the 1.5 s grace:
                // 4.0, 5.5, 7.0 are the three free. The count is then 3 and the
                // wait is one interval past the threshold, 1 s, which expires at
                // 8.0 inside the grace window, so the rebuild is at 8.5. Then
                // 2 s → 10.5, 4 s → 14.5, 8 s → 22.5, 16 s → 38.5, and the step
                // caps at 32 s → the 30 s ceiling → 68.5.
                expect.equal(seen[20], 4, "by 10 s: three free rebuilds and the first waited one")
                expect.equal(seen[40], 6, "by 20 s: the 2 s and 4 s waits")
                expect.equal(seen[80], 8, "by 40 s: the 8 s and 16 s waits")
                expect.equal(seen[120], 8, "by 60 s: the ceiling holds until 68.5")
            },

            test("a change delivered after the throw does not forgive the failure either") { expect in
                // The sibling test emits the change from inside `buildAndStart`,
                // where the failure's own wait does not exist yet and the
                // arrival-time discriminator settles it. CoreAudio posts the
                // notification on its own thread, so the same driver's change
                // lands just as often after the throw, with the wait already
                // standing, and it is the forgiveness clause that answers.
                // Unbounded, that forgave every failure: 601 builds in five
                // minutes, teardown and probe and manifest fsync twice a second
                // for as long as the device flapped.
                let engine = FakeMicrophoneEngine()
                let clock = ManualClock()
                let coordinator = MicrophoneRecoveryCoordinator(
                    controller: engine, clock: clock, delegate: RecordingCaptureDelegate()
                )
                engine.failEveryBuild(with: .microphoneEngineStartFailed(status: -10_875))
                coordinator.start()
                for _ in 0..<600 {
                    clock.advance(0.5)
                    coordinator.tick()
                    // After the poll, not inside the build.
                    coordinator.noteConfigurationChange()
                }
                expect.isTrue(
                    engine.buildCount < 30,
                    "\(engine.buildCount) attempts in five minutes is the storm the backoff exists to stop"
                )
            },

            test("a default input flapping between two devices is bounded") { expect in
                // A differing device identity admits a change through a silent
                // engine's wait, because the loop's own footprint reports the
                // same device. A dock, or a headset whose profiles present
                // distinct identities, alternates on every poll and reads as a
                // fresh swap each time: the wait was cleared every poll and the
                // silent count restarted with it, so the bound was absent for
                // exactly the shape it exists to bound.
                let engine = FakeMicrophoneEngine()
                let clock = ManualClock()
                let coordinator = MicrophoneRecoveryCoordinator(
                    controller: engine, clock: clock, delegate: RecordingCaptureDelegate()
                )
                engine.setDeviceUID("dock-a")
                coordinator.start()
                for i in 0..<240 {
                    clock.advance(0.5)
                    coordinator.tick()
                    engine.setDeviceUID(i.isMultiple(of: 2) ? "dock-b" : "dock-a")
                    coordinator.noteConfigurationChange()
                }
                // Three admissions are allowed, and each one is a device the
                // coordinator has been told is new, so each earns a fresh silent
                // count and three more rebuilds at the grace cadence before its
                // own wait is installed. Twelve, then the ceiling: nineteen
                // across two minutes, against 240 unbounded, and a lower rate
                // than the bound the silent tests hold at.
                expect.isTrue(
                    coordinator.restartCount <= 24,
                    "a flapping default input must not clear the bound forever: got \(coordinator.restartCount)"
                )
            },

            test("every microphone build records the device it opened") { expect in
                // The engine's input node runs on a per-process aggregate
                // rather than on a microphone, so which device a track came
                // from was never written down. A track that reads 30 dB below
                // the rest of the meeting is answerable only against the device
                // it was captured on.
                let engine = FakeMicrophoneEngine()
                let clock = ManualClock()
                let delegate = RecordingCaptureDelegate()
                let coordinator = MicrophoneRecoveryCoordinator(
                    controller: engine, clock: clock, delegate: delegate
                )
                engine.setSteadyFormat(AudioFormatDescriptor(sampleRate: 48_000, channelCount: 3))
                engine.setDeviceUID("BuiltInMicrophoneDevice")
                // The device and the tap are two readings and they can disagree:
                // setting the input unit's device leaves the node's client-side
                // format on whatever it was instantiated with. The build takes
                // this queued reading, so the two differ here by construction.
                engine.queueFormatReadings([
                    AudioFormatDescriptor(sampleRate: 16_000, channelCount: 1),
                ])
                coordinator.start()

                expect.equal(delegate.micBinds.count, 1)
                expect.equal(delegate.micBinds.first?.reason, "session_start")
                expect.equal(
                    delegate.micBinds.first?.device,
                    MicrophoneDeviceDescription(
                        uid: "BuiltInMicrophoneDevice", name: "Fake input",
                        sampleRate: 48_000, channelCount: 3
                    )
                )
                expect.equal(
                    delegate.micBinds.first?.build.format,
                    AudioFormatDescriptor(sampleRate: 16_000, channelCount: 1),
                    "the format the segments are written at, not the device's"
                )

                // And again on the rebuild that follows a device swap, so the
                // manifest carries the whole history rather than the first
                // device of the meeting.
                engine.setDeviceUID("BluetoothHeadsetDevice")
                engine.setSteadyFormat(AudioFormatDescriptor(sampleRate: 16_000, channelCount: 1))
                coordinator.noteConfigurationChange()
                clock.advance(0.5)
                coordinator.tick()

                expect.equal(delegate.micBinds.count, 2)
                expect.equal(delegate.micBinds.last?.device.uid, "BluetoothHeadsetDevice")
                expect.equal(delegate.micBinds.last?.device.channelCount, 1)

                // A build that throws installed no engine, so it names no device.
                engine.failNextBuild(with: .microphoneEngineStartFailed(status: -1))
                coordinator.noteConfigurationChange()
                clock.advance(0.5)
                coordinator.tick()
                expect.equal(delegate.micBinds.count, 2, "a failed build binds no device")
            },

            test("audio restores trust in what the hardware says") { expect in
                // The budget for clearing a backoff on a hardware signal is
                // spent by signals that led nowhere. A working engine is what
                // earns it back: without that, a machine that flapped early in
                // a meeting would refuse every later reconnect for the rest of
                // the session, long after the microphone was fine.
                let engine = FakeMicrophoneEngine()
                let clock = ManualClock()
                let coordinator = MicrophoneRecoveryCoordinator(
                    controller: engine, clock: clock, delegate: RecordingCaptureDelegate()
                )
                engine.failEveryBuild(with: .microphoneEngineStartFailed(status: -1))
                coordinator.start()
                // Spend the budget: three changes, three forgiven failures.
                for _ in 0..<20 {
                    clock.advance(0.5)
                    coordinator.tick()
                    coordinator.noteConfigurationChange()
                }
                // The device comes back and delivers.
                engine.stopFailing()
                for _ in 0..<70 {
                    clock.advance(0.5)
                    coordinator.tick()
                    if engine.isRunning { coordinator.noteBufferArrived(hostTime: clock.monotonicSeconds) }
                }
                expect.equal(coordinator.health, .healthy, "the microphone recovered")

                // It goes away again, and fails long enough for the backoff to
                // climb well past a poll. Only a trusted change can produce a
                // rebuild on the next poll now; the retry alone would wait
                // seconds, which is what makes this assertion about the budget
                // rather than about the backoff expiring on its own.
                engine.failEveryBuild(with: .microphoneEngineStartFailed(status: -1))
                for _ in 0..<24 {
                    clock.advance(0.5)
                    coordinator.tick()
                }
                let afterLoss = coordinator.restartCount
                clock.advance(0.5)
                coordinator.tick()
                expect.equal(
                    coordinator.restartCount, afterLoss,
                    "the backoff is holding, so the next rebuild is the change's or nothing"
                )
                coordinator.noteConfigurationChange()
                clock.advance(0.5)
                coordinator.tick()
                expect.isTrue(
                    coordinator.restartCount > afterLoss,
                    "a change after audio is trusted again, got \(coordinator.restartCount) from \(afterLoss)"
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
                policy.noteBufferArrived(at: now, peak: 0.5)

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
                policy.noteBufferArrived(at: now, peak: 0.5)

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
                policy.noteBufferArrived(at: now, peak: 0.5)
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

            test("what the tap's first callback read is written down once per bind") { expect in
                // `remote_bind` says which buffer of the aggregate the bind
                // chose. Whether that choice held was logged and nothing else,
                // so a meeting whose far side is silent could not be diagnosed
                // from its own folder.
                let tap = FakeProcessTap()
                let clock = ManualClock()
                let delegate = RecordingCaptureDelegate()
                let coordinator = RemoteTapCoordinator(controller: tap, clock: clock, delegate: delegate)
                tap.setTargets([makeTarget(pid: 500, producing: true)])
                coordinator.start(bundlePrefixes: ["org.mozilla.firefox"])

                // The bind returns before any callback runs, so nothing is
                // known yet.
                clock.advance(0.5)
                coordinator.tick()
                expect.isTrue(delegate.remoteStreams.isEmpty, "a bind with no callback reports nothing")

                // The MacBook Pro shape, with the index unusable so the
                // channel-count match read the buffer instead.
                let reading = TapCallbackReading(
                    streams: [
                        .init(channelCount: 8, byteCount: 16_384),
                        .init(channelCount: 2, byteCount: 4_096),
                    ],
                    usedFallback: true
                )
                tap.deliverFirstCallback(reading)
                coordinator.noteBufferArrived(hostTime: clock.monotonicSeconds, peak: 0.5)
                clock.advance(0.5)
                coordinator.tick()

                expect.equal(delegate.remoteStreams.count, 1)
                expect.equal(delegate.remoteStreams.first?.reading, reading)
                expect.equal(delegate.remoteStreams.first?.bindCount, 1)

                // A poll every second all meeting must not write the same line
                // every second.
                for _ in 0..<5 {
                    coordinator.noteBufferArrived(hostTime: clock.monotonicSeconds, peak: 0.5)
                    clock.advance(0.5)
                    coordinator.tick()
                }
                expect.equal(delegate.remoteStreams.count, 1, "one line per bind, not one per poll")

                // A rebind is a new reading. The source clears its own on
                // teardown, so nothing is reported until a callback arrives on
                // the new bind.
                tap.setTargets([makeTarget(pid: 900, producing: true)])
                clock.advance(0.5)
                coordinator.tick()
                expect.equal(tap.bindCount, 2)
                expect.equal(delegate.remoteStreams.count, 1, "a rebind with no callback reports nothing")

                let second = TapCallbackReading(
                    streams: [.init(channelCount: 2, byteCount: 4_096)], usedFallback: false
                )
                tap.deliverFirstCallback(second)
                coordinator.noteBufferArrived(hostTime: clock.monotonicSeconds, peak: 0.5)
                clock.advance(0.5)
                coordinator.tick()
                expect.equal(delegate.remoteStreams.count, 2)
                expect.equal(delegate.remoteStreams.last?.reading, second)
                expect.equal(delegate.remoteStreams.last?.bindCount, 2)
            },

            test("Firefox restart rebinds to the new process") { expect in
                let tap = FakeProcessTap()
                let clock = ManualClock()
                let delegate = RecordingCaptureDelegate()
                let coordinator = RemoteTapCoordinator(controller: tap, clock: clock, delegate: delegate)
                tap.setTargets([makeTarget(pid: 63_100, producing: true)])
                coordinator.start(bundlePrefixes: ["org.mozilla.firefox"])
                coordinator.noteBufferArrived(hostTime: clock.monotonicSeconds, peak: 0.5)
                // On the poll rather than on the buffer. A buffer arriving says
                // the aggregate device is running, which it does whether or not
                // the tap has anything, so health is settled where the target's
                // own output flag can be read alongside it.
                clock.advance(0.5)
                coordinator.tick()
                expect.equal(coordinator.health, .healthy)

                tap.setTargets([])
                clock.advance(0.5)
                coordinator.tick()
                expect.equal(coordinator.health, .degraded, "target gone must not read as healthy")

                tap.setTargets([makeTarget(pid: 63_373, producing: true)])
                clock.advance(0.5)
                coordinator.tick()
                expect.equal(coordinator.boundProcessIDs, [63_373])
                coordinator.noteBufferArrived(hostTime: clock.monotonicSeconds, peak: 0.5)
                clock.advance(0.5)
                coordinator.tick()
                expect.equal(coordinator.health, .healthy)
                expect.equal(tap.bindCount, 2)
            },

            test("every bind records what it was pointed at") { expect in
                // A tap that produced nothing and a tap on an application that
                // was playing nothing write the same track. The manifest
                // carried health transitions and never which processes were
                // bound or whether CoreAudio believed any of them was
                // producing output, so on the one recording that needed the
                // answer it is not recoverable.
                let tap = FakeProcessTap()
                let clock = ManualClock()
                let delegate = RecordingCaptureDelegate()
                let coordinator = RemoteTapCoordinator(controller: tap, clock: clock, delegate: delegate)
                tap.setTargets([makeTarget(pid: 79_590, producing: true)])
                coordinator.start(bundlePrefixes: ["org.mozilla.firefox"])

                expect.equal(delegate.remoteBinds.count, 1)
                expect.equal(delegate.remoteBinds.first?.reason, "session_start")
                expect.equal(delegate.remoteBinds.first?.processIDs, [79_590])
                expect.equal(delegate.remoteBinds.first?.producing, [true])
                expect.equal(
                    delegate.remoteBinds.first?.binding,
                    RemoteTapBinding(
                        format: AudioFormatDescriptor(sampleRate: 48_000, channelCount: 2),
                        streamCount: 2, tapStreamIndex: 1
                    ),
                    "the binding the tap reported reaches the manifest, not a rebuilt one"
                )

                // And again when the process moves, so a recording carries the
                // whole history rather than the first answer.
                tap.setTargets([makeTarget(pid: 81_002, producing: false)])
                clock.advance(0.5)
                coordinator.tick()
                expect.equal(delegate.remoteBinds.count, 2)
                expect.equal(delegate.remoteBinds.last?.processIDs, [81_002])
                expect.equal(delegate.remoteBinds.last?.producing, [false])
            },

            test("a quiet stretch settles on one state instead of flapping") { expect in
                // Buffers arrive whether or not the tap has anything, because
                // the aggregate device is clocked by its output sub-device.
                // Declaring healthy from the buffer fought the poll's
                // idleButBound and logged pairs of transitions milliseconds
                // apart: one recording on disk carries dozens of them, and the
                // noise is what hid that its far end was digital zero.
                let tap = FakeProcessTap()
                let clock = ManualClock()
                let delegate = RecordingCaptureDelegate()
                let coordinator = RemoteTapCoordinator(controller: tap, clock: clock, delegate: delegate)
                tap.setTargets([makeTarget(pid: 79_590, producing: false)])
                coordinator.start(bundlePrefixes: ["org.mozilla.firefox"])

                for _ in 0..<20 {
                    coordinator.noteBufferArrived(hostTime: clock.monotonicSeconds, peak: 0)
                    clock.advance(0.5)
                    coordinator.tick()
                }
                expect.equal(coordinator.health, .idleButBound)
                expect.equal(
                    delegate.healthChanges.filter { $0.state == .healthy }.count, 0,
                    "a buffer from a target producing nothing never reads as healthy"
                )
                expect.isTrue(
                    delegate.healthChanges.count <= 2,
                    "one settled state, not a transition per buffer"
                )
            },

            test("a tap delivering silence under a producing target is rebound once") { expect in
                // Three recordings on this machine hold 2 to 41 minutes of
                // exactly-zero far-end audio while the manifest shows the bound
                // Slack helper reporting output the whole time and health
                // healthy. Arrival was the only thing anything read.
                let tap = FakeProcessTap()
                let clock = ManualClock()
                let delegate = RecordingCaptureDelegate()
                let coordinator = RemoteTapCoordinator(controller: tap, clock: clock, delegate: delegate)
                tap.setTargets([makeTarget(pid: 79_590, producing: true)])
                coordinator.start(bundlePrefixes: ["org.mozilla.firefox"])

                deliverSilence(to: coordinator, clock: clock, seconds: 25)

                expect.equal(tap.bindCount, 2, "one rebind, not one per poll")
                expect.equal(
                    delegate.restarts.map(\.reason), ["silent_while_producing"],
                    "the rebind is recorded as what caused it"
                )
                expect.isFalse(
                    coordinator.health.isLosingAudio,
                    "a rebind is the first answer, not a verdict on the recording"
                )
                expect.equal(coordinator.warnings(), [], "nothing to tell the user about yet")
            },

            test("silence that survives the rebind is degraded and warned about") { expect in
                let tap = FakeProcessTap()
                let clock = ManualClock()
                let delegate = RecordingCaptureDelegate()
                let coordinator = RemoteTapCoordinator(controller: tap, clock: clock, delegate: delegate)
                tap.setTargets([makeTarget(pid: 79_590, producing: true)])
                coordinator.start(bundlePrefixes: ["org.mozilla.firefox"])

                deliverSilence(to: coordinator, clock: clock, seconds: 45)

                expect.equal(coordinator.health, .degraded)
                expect.equal(tap.bindCount, 2, "a rebind that changed nothing is not repeated")
                expect.equal(coordinator.warnings().count, 1, "one condition, one warning")
                guard case .remoteSilentWhileProducing(let seconds)? = coordinator.warnings().first else {
                    expect.fail("expected a silence warning, got \(coordinator.warnings())")
                    return
                }
                expect.isTrue(seconds >= 40, "the warning reports the whole run, got \(seconds)")
                expect.equal(
                    delegate.healthChanges.last?.state, .degraded,
                    "the manifest carries the transition, not just the menu bar"
                )
            },

            test("one non-zero buffer ends the silence and the warning with it") { expect in
                let tap = FakeProcessTap()
                let clock = ManualClock()
                let delegate = RecordingCaptureDelegate()
                let coordinator = RemoteTapCoordinator(controller: tap, clock: clock, delegate: delegate)
                tap.setTargets([makeTarget(pid: 79_590, producing: true)])
                coordinator.start(bundlePrefixes: ["org.mozilla.firefox"])
                deliverSilence(to: coordinator, clock: clock, seconds: 45)
                expect.equal(coordinator.health, .degraded)

                coordinator.noteBufferArrived(hostTime: clock.monotonicSeconds, peak: 0.02)
                clock.advance(0.5)
                coordinator.tick()

                expect.equal(coordinator.warnings(), [])
                expect.equal(coordinator.health, .healthy)
                expect.equal(tap.bindCount, 2, "audio arriving is not a reason to rebind")
            },

            test("the silence warning waits for the poll that declares it") { expect in
                // The degraded state and the warning are one decision. Deriving
                // the warning from elapsed time instead let it appear on a poll
                // that returned early, which is every poll between a rebind and
                // the next buffer, and the user was told about a state nothing
                // had entered.
                let tap = FakeProcessTap()
                let clock = ManualClock()
                let coordinator = RemoteTapCoordinator(
                    controller: tap, clock: clock, delegate: RecordingCaptureDelegate()
                )
                tap.setTargets([makeTarget(pid: 79_590, producing: true)])
                coordinator.start(bundlePrefixes: ["org.mozilla.firefox"])
                deliverSilence(to: coordinator, clock: clock, seconds: 25)

                // The tap stops calling back at all, so every poll from here
                // leaves through the callback checks.
                for _ in 0..<60 {
                    clock.advance(0.5)
                    coordinator.tick()
                    expect.isFalse(
                        coordinator.warnings().contains {
                            $0.dedupKey == "remote_silent_while_producing"
                        },
                        "warned without ever calling the tap degraded"
                    )
                }
                expect.notEqual(coordinator.health, .degraded)
            },

            test("a silence run belongs to the process that was producing during it") { expect in
                // The aggregate is clocked by its output sub-device, so it hands
                // over digital zero at full rate through every quiet stretch. A
                // run that keeps counting across the moment output starts tore
                // the tap down on the first poll of the call, and a rebuild
                // costs 200 to 900 ms of exactly the audio it was saving.
                let tap = FakeProcessTap()
                let clock = ManualClock()
                let delegate = RecordingCaptureDelegate()
                let coordinator = RemoteTapCoordinator(controller: tap, clock: clock, delegate: delegate)
                tap.setTargets([makeTarget(pid: 79_590, producing: false)])
                coordinator.start(bundlePrefixes: ["org.mozilla.firefox"])
                deliverSilence(to: coordinator, clock: clock, seconds: 25)

                // The call's audio starts.
                tap.setTargets([makeTarget(pid: 79_590, producing: true)])
                deliverSilence(to: coordinator, clock: clock, seconds: 15)
                expect.equal(delegate.restarts, [], "the quiet stretch is not charged against the call")
                expect.equal(tap.bindCount, 1)

                // The window still runs, measured from when output started.
                deliverSilence(to: coordinator, clock: clock, seconds: 10)
                expect.equal(delegate.restarts.map(\.reason), ["silent_while_producing"])

                // The application relaunches under a new PID. Its silence is
                // judged from its own bind, not from the process it replaced.
                tap.setTargets([makeTarget(pid: 81_002, producing: true)])
                clock.advance(0.5)
                coordinator.tick()
                expect.equal(delegate.restarts.map(\.reason), ["silent_while_producing", "target_changed"])

                deliverSilence(to: coordinator, clock: clock, seconds: 15)
                expect.equal(
                    delegate.restarts.map(\.reason), ["silent_while_producing", "target_changed"],
                    "the replacement inherited the process it replaced's silence clock"
                )
            },

            test("a degraded state from another cause is not blamed on silence") { expect in
                // The detail goes into the manifest beside the state. A run that
                // outlives the output it was measured against labels the next
                // degraded transition, whatever actually caused it.
                let tap = FakeProcessTap()
                let clock = ManualClock()
                let delegate = RecordingCaptureDelegate()
                let coordinator = RemoteTapCoordinator(controller: tap, clock: clock, delegate: delegate)
                tap.setTargets([makeTarget(pid: 79_590, producing: true)])
                coordinator.start(bundlePrefixes: ["org.mozilla.firefox"])
                deliverSilence(to: coordinator, clock: clock, seconds: 45)
                expect.equal(coordinator.health, .degraded)
                expect.equal(
                    delegate.healthChanges.last?.detail, "tap delivers silence while target reports output",
                    "the transition the silence did cause carries its reason"
                )

                // The application stops playing, so nothing is claiming output
                // that the tap is failing to carry.
                tap.setTargets([makeTarget(pid: 79_590, producing: false)])
                clock.advance(0.5)
                coordinator.tick()
                expect.equal(coordinator.health, .idleButBound)
                expect.equal(coordinator.warnings(), [])

                // Then it quits, which is source absence.
                tap.setTargets([])
                clock.advance(0.5)
                coordinator.tick()
                expect.equal(coordinator.health, .degraded)
                expect.isNil(
                    delegate.healthChanges.last?.detail,
                    "an application quitting is not the tap delivering silence"
                )
            },

            test("a target playing nothing is allowed to deliver silence forever") { expect in
                // The aggregate device is clocked by its output sub-device, so
                // it hands over digital zero at full rate whenever the tapped
                // application is quiet. That is the normal state and it must
                // never rebind or warn.
                let tap = FakeProcessTap()
                let clock = ManualClock()
                let delegate = RecordingCaptureDelegate()
                let coordinator = RemoteTapCoordinator(controller: tap, clock: clock, delegate: delegate)
                tap.setTargets([makeTarget(pid: 79_590, producing: false)])
                coordinator.start(bundlePrefixes: ["org.mozilla.firefox"])

                deliverSilence(to: coordinator, clock: clock, seconds: 60)

                expect.equal(coordinator.health, .idleButBound)
                expect.equal(tap.bindCount, 1)
                expect.equal(coordinator.warnings(), [])
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

    /// Runs the tap at 10 buffers a second and the poll at its own 0.5 s, with
    /// every buffer exactly zero. The recordings that lost their far side had
    /// this shape. Buffers arrived on time and carried nothing.
    private static func deliverSilence(
        to coordinator: RemoteTapCoordinator, clock: ManualClock, seconds: Double
    ) {
        for step in 1...Int(seconds * 10) {
            coordinator.noteBufferArrived(hostTime: clock.monotonicSeconds, peak: 0)
            clock.advance(0.1)
            if step % 5 == 0 { coordinator.tick() }
        }
    }

    static var all: [Suite] {
        [micPolicySuite, micCoordinatorSuite, remoteSuite, remoteCoordinatorSuite]
    }
}
