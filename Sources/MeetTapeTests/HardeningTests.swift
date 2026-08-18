import AVFoundation
import Foundation
import MeetTapeAudio
import MeetTapeCore
import TestKit

/// Regressions for defects found by adversarial review. Each one failed against
/// the code as it was.
enum HardeningTests {
    // MARK: - fakes that emit audio

    final class EmittingMicrophone: MicrophoneEngineController, @unchecked Sendable {
        private let lock = NSLock()
        private var sinkHandler: AudioBufferSink?
        var format = AudioFormatDescriptor(sampleRate: 48_000, channelCount: 1)

        init(sink: @escaping AudioBufferSink) { self.sinkHandler = sink }

        func currentInputFormat() -> AudioFormatDescriptor? { format }
        func teardown() {}
        @discardableResult
        func buildAndStart(preferred: AudioFormatDescriptor) throws -> AudioFormatDescriptor { format }
        var isRunning: Bool { true }

        func emit(seconds: Double, hostTime: Double) {
            lock.lock()
            let handler = sinkHandler
            lock.unlock()
            let buffer = AudioTests.makeTone(seconds: seconds, sampleRate: format.sampleRate)
            handler?(AudioBufferPacket(buffer: buffer, hostTime: hostTime))
        }
    }

    final class EmittingTap: ProcessTapController, @unchecked Sendable {
        private let lock = NSLock()
        private var sinkHandler: AudioBufferSink?
        private var targets: [RemoteAudioTarget] = []
        var format = AudioFormatDescriptor(sampleRate: 48_000, channelCount: 1)
        private(set) var bindCount = 0

        init(sink: @escaping AudioBufferSink) { self.sinkHandler = sink }

        func setTargets(_ targets: [RemoteAudioTarget]) {
            lock.lock()
            self.targets = targets
            lock.unlock()
        }

        func resolveTargets(bundlePrefixes: [String]) -> [RemoteAudioTarget] {
            lock.lock()
            defer { lock.unlock() }
            return targets.filter { target in
                bundlePrefixes.contains { target.bundleIdentifier.hasPrefix($0) }
            }
        }

        func teardown() {}

        func bind(to targets: [RemoteAudioTarget]) throws -> AudioFormatDescriptor {
            lock.lock()
            bindCount += 1
            lock.unlock()
            return format
        }

        func emit(seconds: Double, hostTime: Double) {
            lock.lock()
            let handler = sinkHandler
            lock.unlock()
            let buffer = AudioTests.makeTone(seconds: seconds, sampleRate: format.sampleRate)
            handler?(AudioBufferPacket(buffer: buffer, hostTime: hostTime))
        }
    }

    final class SilentDelegate: CaptureEngineDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var snapshots: [CaptureHealthSnapshot] = []
        private(set) var warnings: [CaptureWarning] = []

        func captureEngineDidUpdateHealth(_ snapshot: CaptureHealthSnapshot) {
            lock.lock()
            snapshots.append(snapshot)
            lock.unlock()
        }

        func captureEngineDidRaiseWarning(_ warning: CaptureWarning) {
            lock.lock()
            warnings.append(warning)
            lock.unlock()
        }
    }

    static var captureSuite: Suite {
        Suite("CaptureEngineHardening", [
            test("remote audio that starts after commit is still written") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let layout = MeetingLayout(root: root)
                try FileManager.default.createDirectory(at: layout.segments, withIntermediateDirectories: true)

                let microphone = LockedBox<EmittingMicrophone?>(nil)
                let tap = LockedBox<EmittingTap?>(nil)
                let engine = CaptureEngine(
                    segmentSeconds: 60,
                    makeMicrophone: { sink, _ in
                        let source = EmittingMicrophone(sink: sink)
                        microphone.withLock { $0 = source }
                        return source
                    },
                    makeTap: { sink, _ in
                        let source = EmittingTap(sink: sink)
                        tap.withLock { $0 = source }
                        return source
                    },
                    delegate: SilentDelegate()
                )

                // The provider's audio process does not exist yet, which is the
                // normal state the instant a huddle or a call is joined.
                await engine.arm(bundlePrefixes: ["com.example.app"], capturesRemote: true)
                try await engine.commit(layout: layout, meetingID: "m", source: .googleMeet)

                // It appears a moment later and starts producing audio.
                tap.withLock { $0?.setTargets([makeTarget(pid: 42, bundle: "com.example.app")]) }
                tap.withLock { $0?.emit(seconds: 1, hostTime: 100) }
                microphone.withLock { $0?.emit(seconds: 1, hostTime: 100) }
                _ = await engine.stop(reason: "test")

                let timeline = try ManifestReader.timeline(contentsOf: layout.manifest)
                expect.isTrue(
                    timeline.duration(track: .remote) > 0.5,
                    "remote audio arriving after commit was dropped"
                )
                expect.isTrue(timeline.duration(track: .mic) > 0.5)
            },

            test("the pre-roll reaches disk before the audio that follows it") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let layout = MeetingLayout(root: root)
                try FileManager.default.createDirectory(at: layout.segments, withIntermediateDirectories: true)

                let microphone = LockedBox<EmittingMicrophone?>(nil)
                let engine = CaptureEngine(
                    segmentSeconds: 60,
                    makeMicrophone: { sink, _ in
                        let source = EmittingMicrophone(sink: sink)
                        microphone.withLock { $0 = source }
                        return source
                    },
                    makeTap: { sink, _ in EmittingTap(sink: sink) },
                    delegate: SilentDelegate()
                )

                await engine.arm(bundlePrefixes: [], capturesRemote: false)
                // Three seconds of candidate audio, held only in memory.
                for index in 0..<3 {
                    microphone.withLock { $0?.emit(seconds: 1, hostTime: Double(index)) }
                }
                try await engine.commit(layout: layout, meetingID: "m", source: .googleMeet)
                microphone.withLock { $0?.emit(seconds: 1, hostTime: 3) }
                _ = await engine.stop(reason: "test")

                let timeline = try ManifestReader.timeline(contentsOf: layout.manifest)
                expect.close(
                    timeline.duration(track: .mic), 4.0, tolerance: 0.2,
                    "the ring should be written along with the live audio"
                )
                expect.equal(timeline.preRollFlushes.count, 1)
                expect.close(timeline.preRollFlushes[0].seconds, 3.0, tolerance: 0.1)
            },

            test("a mic-only recording is not judged by the remote source") { expect in
                var snapshot = CaptureHealthSnapshot(
                    mic: .healthy, remote: .failed, capturesRemote: false
                )
                expect.equal(snapshot.overall, .healthy, "in-person capture has no remote track")

                snapshot = CaptureHealthSnapshot(mic: .healthy, remote: .failed, capturesRemote: true)
                expect.equal(snapshot.overall, .failed, "a failed required source is never healthy")

                snapshot = CaptureHealthSnapshot(mic: .healthy, remote: .idleButBound)
                expect.equal(snapshot.overall, .healthy, "a quiet meeting app is normal")

                snapshot = CaptureHealthSnapshot(mic: .recovering, remote: .healthy)
                expect.equal(snapshot.overall, .recovering)

                snapshot = CaptureHealthSnapshot(mic: .degraded, remote: .healthy)
                expect.equal(snapshot.overall, .degraded)
            },

            test("a segment that cannot be opened is retried, not abandoned") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let layout = MeetingLayout(root: root)
                try FileManager.default.createDirectory(at: layout.segments, withIntermediateDirectories: true)
                let manifest = try ManifestWriter(url: layout.manifest)
                let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

                // The segments directory disappears, so the first open fails.
                try FileManager.default.removeItem(at: layout.segments)
                let clock = ManualClock()
                let writer = SegmentWriter(
                    track: .mic, layout: layout, manifest: manifest, format: format,
                    segmentSeconds: 60, clock: clock
                )
                writer.enqueueSynchronously(AudioBufferPacket(
                    buffer: AudioTests.makeTone(seconds: 1, sampleRate: 48_000), hostTime: 0
                ))
                expect.isTrue(writer.stats.writeFailures > 0, "the failure should be recorded")

                // The volume comes back; the next buffer after the retry delay must
                // land on disk.
                try FileManager.default.createDirectory(at: layout.segments, withIntermediateDirectories: true)
                clock.advance(2)
                writer.enqueueSynchronously(AudioBufferPacket(
                    buffer: AudioTests.makeTone(seconds: 1, sampleRate: 48_000), hostTime: 1
                ))
                writer.finish(reason: "test")
                manifest.close()

                expect.close(
                    writer.stats.totalSeconds, 1.0, tolerance: 0.05,
                    "recording should resume once the directory exists again"
                )
            },
        ])
    }

    static var detectionSuite: Suite {
        Suite("DetectionHardening", [
            test("consecutive uninformative reads never end a live huddle") { expect in
                var detector = SlackHuddleDetector()
                var now = 100.0
                _ = detector.update(
                    observation: DetectionTests.joined(), helperHoldsMicrophone: true,
                    helperProducingOutput: true, at: now
                )
                expect.equal(detector.state, .joined)

                // Twelve consecutive empty reads, well past both the miss count and
                // the grace period, while Slack is plainly still in the huddle.
                for index in 0..<12 {
                    now += 0.4
                    let event = detector.update(
                        observation: .empty, helperHoldsMicrophone: true,
                        helperProducingOutput: true, at: now
                    )
                    if case .left(let reason) = event {
                        expect.fail("ended on empty read \(index) with reason \(reason)")
                        return
                    }
                    expect.notEqual(detector.state, .idle)
                }

                // The control comes back and the huddle is unaffected.
                now += 0.4
                _ = detector.update(
                    observation: DetectionTests.joined(), helperHoldsMicrophone: true,
                    helperProducingOutput: true, at: now
                )
                expect.equal(detector.state, .joined)
                expect.equal(detector.consecutiveMisses, 0)
            },

            test("a huddle is still detected without accessibility") { expect in
                var detector = SlackHuddleDetector()
                var now = 100.0
                var joined = false
                for _ in 0..<120 {
                    now += 0.5
                    let event = detector.update(
                        observation: .unavailable, helperHoldsMicrophone: true,
                        helperProducingOutput: true, at: now
                    )
                    if event == .joinedWithoutAccessibility { joined = true; break }
                }
                expect.isTrue(joined, "audio evidence alone should eventually confirm a huddle")
                expect.equal(detector.state, .joined)

                // It ends when the audio does, since there is no control to watch.
                var ended = false
                for _ in 0..<20 {
                    now += 0.5
                    if case .left = detector.update(
                        observation: .unavailable, helperHoldsMicrophone: false,
                        helperProducingOutput: false, at: now
                    ) { ended = true; break }
                }
                expect.isTrue(ended)
            },

            test("a stale sensor event cannot demote a live call") { expect in
                var tracker = BrowserSensorTracker()
                tracker.noteConnected(at: 100)
                tracker.receive(
                    BrowserMeetingEvent(
                        browser: .firefox, provider: .googleMeet, state: .inCall,
                        timestamp: 1_000, tabID: 1
                    ),
                    at: 100
                )
                // An event observed earlier but delivered later.
                tracker.receive(
                    BrowserMeetingEvent(
                        browser: .firefox, provider: .googleMeet, state: .prejoin,
                        timestamp: 990, tabID: 1
                    ),
                    at: 101
                )
                expect.equal(tracker.currentEvent(at: 101)?.state, .inCall)
            },

            test("a second tab does not overwrite the tab that is in a call") { expect in
                var tracker = BrowserSensorTracker()
                tracker.noteConnected(at: 100)
                tracker.receive(
                    BrowserMeetingEvent(
                        browser: .firefox, provider: .googleMeet, state: .inCall,
                        timestamp: 1_000, tabID: 1
                    ),
                    at: 100
                )
                tracker.receive(
                    BrowserMeetingEvent(
                        browser: .firefox, provider: .zoom, state: .browsing,
                        timestamp: 1_001, tabID: 2
                    ),
                    at: 101
                )
                let current = tracker.currentEvent(at: 101)
                expect.equal(current?.state, .inCall)
                expect.equal(current?.tabID, 1)

                // Closing the browsing tab leaves the call alone.
                tracker.closeTab(2)
                expect.equal(tracker.currentEvent(at: 101)?.state, .inCall)
            },

            test("a sensor reporting browsing cannot cancel a confirmed native meeting") { expect in
                var detector = BrowserMeetingDetector()
                var now = 100.0
                let native = BrowserMeetingDetector.NativeSignals(
                    browserHoldsMicrophone: true, browserProducesOutput: true,
                    windowTitles: ["Meet - abc-defg-hij"]
                )
                _ = detector.update(native: native, at: now)
                now += 25
                expect.equal(detector.update(native: native, at: now).confidence, .confirmed)

                // The extension's selector stops matching the leave control, so it
                // reports browsing while the meeting is plainly still running.
                detector.sensorConnected(at: now)
                detector.receive(
                    BrowserMeetingEvent(
                        browser: .firefox, provider: .googleMeet, state: .browsing, timestamp: now
                    ),
                    at: now
                )
                let evidence = detector.update(native: native, at: now)
                expect.equal(
                    evidence.confidence, .confirmed,
                    "a DOM regression must cost precision, not the meeting"
                )
            },

            test("a stale window title stops producing evidence") { expect in
                var detector = BrowserMeetingDetector()
                var now = 100.0
                let withMeeting = BrowserMeetingDetector.NativeSignals(
                    browserHoldsMicrophone: true, browserProducesOutput: true,
                    windowTitles: ["Meet - abc-defg-hij"]
                )
                _ = detector.update(native: withMeeting, at: now)
                now += 25
                expect.equal(detector.update(native: withMeeting, at: now).confidence, .confirmed)

                // The meeting tab is closed but the browser keeps using the
                // microphone for something else.
                let noTitles = BrowserMeetingDetector.NativeSignals(
                    browserHoldsMicrophone: true, browserProducesOutput: true, windowTitles: []
                )
                now += 200
                expect.equal(
                    detector.update(native: noTitles, at: now).confidence, .none,
                    "a title seen minutes ago is not evidence of a meeting now"
                )
            },

            test("an unsupported call keeps producing evidence for as long as it runs") { expect in
                var detector = GenericCallDetector()
                var now = 100.0
                let states = [
                    ApplicationAudioState(
                        bundleIdentifier: "com.example.videochat", processID: 4_242,
                        holdsMicrophone: true, producesOutput: true,
                        isFrontmost: true, windowTitle: "Team call"
                    ),
                ]
                for _ in 0..<20 {
                    now += 0.5
                    _ = detector.update(states: states, at: now)
                }
                expect.equal(detector.currentEvidence().count, 1)

                // Half an hour later it is still reporting, so the session never
                // runs out of evidence and stops the recording.
                for _ in 0..<3_600 {
                    now += 0.5
                    _ = detector.update(states: states, at: now)
                }
                let evidence = try expect.unwrap(detector.currentEvidence().first)
                expect.equal(evidence.confidence, .confirmed)
                expect.equal(evidence.audioBundlePrefixes, ["com.example.videochat"])

                // A single missed poll is not the end of the call.
                now += 0.5
                expect.equal(detector.update(states: [], at: now), [])
                expect.equal(detector.currentEvidence().count, 1)

                now += 10
                let ended = detector.update(states: [], at: now)
                expect.isTrue(ended.contains(.callEnded(bundleIdentifier: "com.example.videochat")))
                expect.equal(detector.currentEvidence().count, 0)
            },
        ])
    }

    static var sessionSuite: Suite {
        Suite("SessionHardening", [
            test("a provider set to never record does not suppress another one") { expect in
                var policies = ProviderPolicies()
                policies.zoom = ProviderPolicy(autoStart: .never, autoStop: true)
                var controller = SessionController(policies: policies)
                let wall = Date(timeIntervalSince1970: 1_787_070_000)

                let zoom = ProviderEvidence(
                    provider: .zoom, confidence: .confirmed, source: .browserSensor,
                    meetingID: "81771591841", audioBundlePrefixes: ["org.mozilla.firefox"]
                )
                let meet = SessionTests.meetEvidence(confidence: .confirmed)
                let actions = controller.update(
                    evidence: [zoom, meet], now: 100, wallClock: wall
                )
                expect.equal(controller.snapshot.provider, .googleMeet)
                expect.isTrue(actions.contains { if case .commitRecording = $0 { true } else { false } })
            },

            test("a different meeting replaces the current one instead of merging") { expect in
                var controller = SessionController()
                let wall = Date(timeIntervalSince1970: 1_787_070_000)
                _ = controller.update(
                    evidence: [SessionTests.meetEvidence(confidence: .confirmed)],
                    now: 100, wallClock: wall
                )
                expect.equal(controller.snapshot.providerMeetingID, "abc-defg-hij")

                let actions = controller.update(
                    evidence: [SessionTests.meetEvidence(confidence: .confirmed, meetingID: "zzz-zzzz-zzz")],
                    now: 101, wallClock: wall
                )
                expect.isTrue(
                    actions.contains { if case .finishRecording = $0 { true } else { false } },
                    "the first meeting must be finished, not extended"
                )
                expect.isTrue(actions.contains { if case .commitRecording = $0 { true } else { false } })
                expect.equal(controller.snapshot.providerMeetingID, "zzz-zzzz-zzz")
            },

            test("weaker evidence sustains a recording rather than ending it") { expect in
                var controller = SessionController()
                let wall = Date(timeIntervalSince1970: 1_787_070_000)
                _ = controller.update(
                    evidence: [SessionTests.meetEvidence(confidence: .confirmed)],
                    now: 100, wallClock: wall
                )
                var now = 100.0
                for _ in 0..<400 {
                    now += 0.5
                    let actions = controller.update(
                        evidence: [SessionTests.meetEvidence(confidence: .candidate)],
                        now: now, wallClock: wall
                    )
                    expect.isFalse(
                        actions.contains { if case .finishRecording = $0 { true } else { false } },
                        "candidate-level evidence still means the meeting is there"
                    )
                }
                expect.equal(controller.snapshot.state, .recording)
            },

            test("a candidate survives a brief gap in evidence") { expect in
                var controller = SessionController()
                let wall = Date(timeIntervalSince1970: 1_787_070_000)
                _ = controller.update(
                    evidence: [SessionTests.meetEvidence(confidence: .candidate)],
                    now: 100, wallClock: wall
                )
                // A CoreAudio process-list flap: evidence vanishes for two polls.
                for offset in [100.5, 101.0] {
                    let actions = controller.update(evidence: [], now: offset, wallClock: wall)
                    expect.equal(actions, [], "one flap must not discard the pre-roll")
                }
                expect.equal(controller.snapshot.state, .candidate)

                let resumed = controller.update(
                    evidence: [SessionTests.meetEvidence(confidence: .confirmed)],
                    now: 101.5, wallClock: wall
                )
                expect.isTrue(resumed.contains { if case .commitRecording = $0 { true } else { false } })
            },

            test("pausing detection finishes a live recording instead of freezing it") { expect in
                var controller = SessionController()
                let wall = Date(timeIntervalSince1970: 1_787_070_000)
                _ = controller.update(
                    evidence: [SessionTests.meetEvidence(confidence: .confirmed)],
                    now: 100, wallClock: wall
                )
                expect.equal(controller.snapshot.state, .recording)

                controller.policies.detectionPaused = true
                let actions = controller.update(evidence: [], now: 101, wallClock: wall)
                expect.isTrue(
                    actions.contains { if case .finishRecording = $0 { true } else { false } },
                    "a paused session must be finalised, not left writing segments forever"
                )
                expect.equal(controller.snapshot.state, .idle)
            },
        ])
    }

    static var all: [Suite] { [captureSuite, detectionSuite, sessionSuite] }
}
