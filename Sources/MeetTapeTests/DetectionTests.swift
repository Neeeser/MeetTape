import Foundation
import MeetTapeCore
import TestKit

enum DetectionTests {
    static func joined(mute: Bool? = nil, title: String? = nil) -> SlackAccessibilityObservation {
        SlackAccessibilityObservation(
            hasLeaveHuddleControl: true, subtreeWasEmpty: false, isMuted: mute, windowTitle: title
        )
    }

    static func previewing() -> SlackAccessibilityObservation {
        SlackAccessibilityObservation(hasLeaveHuddleControl: false, subtreeWasEmpty: false)
    }

    static var slackSuite: Suite {
        Suite("SlackHuddleDetector", [
            test("holding the microphone is a candidate, not a meeting") { expect in
                var detector = SlackHuddleDetector()
                var now = 100.0

                // Slack opened the microphone 12.2 s before the user joined.
                let event = detector.update(
                    observation: previewing(), helperHoldsMicrophone: true,
                    helperProducingOutput: false, at: now
                )
                expect.equal(event, .candidateAppeared)
                expect.equal(detector.state, .candidate)

                for _ in 0..<30 {
                    now += 0.4
                    let tick = detector.update(
                        observation: previewing(), helperHoldsMicrophone: true,
                        helperProducingOutput: false, at: now
                    )
                    expect.equal(tick, .none, "a preview must not become a meeting")
                }

                now += 0.4
                let joinedEvent = detector.update(
                    observation: joined(), helperHoldsMicrophone: true,
                    helperProducingOutput: true, at: now
                )
                expect.equal(joinedEvent, .joined)
            },

            test("a flapping accessibility subtree never ends a live huddle") { expect in
                var detector = SlackHuddleDetector()
                var now = 100.0
                _ = detector.update(
                    observation: joined(), helperHoldsMicrophone: true,
                    helperProducingOutput: true, at: now
                )
                expect.equal(detector.state, .joined)

                // The subtree read empty repeatedly during a confirmed active huddle.
                for cycle in 0..<20 {
                    now += 0.4
                    let empty = detector.update(
                        observation: .empty, helperHoldsMicrophone: true,
                        helperProducingOutput: true, at: now
                    )
                    expect.notEqual(empty, .left(reason: "control_gone"), "ended on empty read \(cycle)")
                    expect.notEqual(empty, .left(reason: "audio_stopped"))
                    now += 0.4
                    _ = detector.update(
                        observation: joined(), helperHoldsMicrophone: true,
                        helperProducingOutput: true, at: now
                    )
                    expect.equal(detector.state, .joined)
                }
            },

            test("a real leave ends the huddle once the audio agrees") { expect in
                var detector = SlackHuddleDetector()
                var now = 100.0
                _ = detector.update(
                    observation: joined(), helperHoldsMicrophone: true,
                    helperProducingOutput: true, at: now
                )

                var ended: SlackHuddleDetector.Event = .none
                for _ in 0..<12 {
                    now += 0.4
                    ended = detector.update(
                        observation: previewing(), helperHoldsMicrophone: false,
                        helperProducingOutput: false, at: now
                    )
                    if case .left = ended { break }
                }
                guard case .left = ended else {
                    expect.fail("a genuine leave must end the huddle, got \(ended)")
                    return
                }
                expect.equal(detector.state, .idle)
                expect.isTrue(now - 100.0 >= 1.2, "must not end on the first miss")
            },

            test("mute toggles are reported without touching the lifecycle") { expect in
                var detector = SlackHuddleDetector()
                var now = 100.0
                _ = detector.update(
                    observation: joined(mute: false), helperHoldsMicrophone: true,
                    helperProducingOutput: true, at: now
                )
                now += 0.4
                let muted = detector.update(
                    observation: joined(mute: true), helperHoldsMicrophone: true,
                    helperProducingOutput: true, at: now
                )
                expect.equal(muted, .muteChanged(true))
                expect.equal(detector.state, .joined)
            },

            test("window titles yield conversation, kind and workspace") { expect in
                let dm = try expect.unwrap(SlackWindowTitle.parse("Brian McNamara (DM) - Vectorize - Slack"))
                expect.equal(dm.conversation, "Brian McNamara")
                expect.equal(dm.kind, .directMessage)
                expect.equal(dm.workspace, "Vectorize")

                let channel = try expect.unwrap(
                    SlackWindowTitle.parse("vectorize-booking (Channel) - Hindsight - Slack")
                )
                expect.equal(channel.conversation, "vectorize-booking")
                expect.equal(channel.kind, .channel)

                let decorated = try expect.unwrap(
                    SlackWindowTitle.parse("andrew.neeser595 (DM) - Hindsight - Slack [Main] 🏠🔊")
                )
                expect.equal(decorated.conversation, "andrew.neeser595")
                expect.equal(decorated.workspace, "Hindsight")

                let preview = try expect.unwrap(SlackWindowTitle.parse("Slack - Huddle Preview"))
                expect.isTrue(preview.isHuddlePreview)
            },

            test("a title with no conversation in it names nothing") { expect in
                // Slack publishes "- Hindsight - Slack" while a conversation is
                // loading. Read as a name it became the meeting's title, and a
                // huddle was filed and announced as "- Hindsight".
                expect.isTrue(
                    SlackWindowTitle.parse("- Hindsight - Slack") == nil,
                    "a leading separator is not a conversation name"
                )
                expect.isTrue(SlackWindowTitle.parse(" (DM) - Hindsight - Slack") == nil)
                expect.isTrue(SlackWindowTitle.parse("Hindsight - Slack")?.conversation == "Hindsight")

                // And the last real name survives the moment the title is empty.
                var detector = SlackHuddleDetector()
                _ = detector.update(
                    observation: SlackAccessibilityObservation(
                        hasLeaveHuddleControl: true, subtreeWasEmpty: false, isMuted: false,
                        windowTitle: "andrew.neeser595 (DM) - Hindsight - Slack"
                    ),
                    helperHoldsMicrophone: true, helperProducingOutput: false, at: 100
                )
                _ = detector.update(
                    observation: SlackAccessibilityObservation(
                        hasLeaveHuddleControl: true, subtreeWasEmpty: false, isMuted: false,
                        windowTitle: "- Hindsight - Slack"
                    ),
                    helperHoldsMicrophone: true, helperProducingOutput: false, at: 101
                )
                expect.equal(detector.conversationTitle, "andrew.neeser595")
            },
        ])
    }

    static var browserSuite: Suite {
        Suite("BrowserMeetingDetector", [
            test("Meet prejoin and joined are only distinguishable with the sensor") { expect in
                var detector = BrowserMeetingDetector()
                var now = 100.0
                // Native view of the whole controlled test: the title carries the
                // meeting code and the microphone is held, through prejoin, join
                // and leave, with no transition at the moment of joining.
                let native = BrowserMeetingDetector.NativeSignals(
                    browserHoldsMicrophone: true, browserProducesOutput: false,
                    windowTitles: ["Meet - jfp-btbt-owm"]
                )
                let early = detector.update(native: native, at: now)
                expect.equal(early.provider, .googleMeet)
                expect.equal(early.confidence, .candidate)
                expect.equal(early.meetingID, "jfp-btbt-owm")

                // Native alone eventually records anyway: recall beats precision.
                now += 25
                expect.equal(detector.update(native: native, at: now).confidence, .confirmed)

                // With the sensor connected, prejoin is explicit.
                var sensored = BrowserMeetingDetector()
                sensored.sensorConnected(at: now)
                sensored.receive(
                    BrowserMeetingEvent(
                        browser: .firefox, provider: .googleMeet, state: .prejoin,
                        timestamp: now, url: "https://meet.google.com/jfp-btbt-owm",
                        meetingID: "jfp-btbt-owm"
                    ),
                    at: now
                )
                expect.equal(sensored.update(native: native, at: now).confidence, .candidate)

                now += 1.6
                sensored.receive(
                    BrowserMeetingEvent(
                        browser: .firefox, provider: .googleMeet, state: .inCall,
                        timestamp: now, url: "https://meet.google.com/jfp-btbt-owm",
                        meetingID: "jfp-btbt-owm", muted: false
                    ),
                    at: now
                )
                let joined = sensored.update(native: native, at: now)
                expect.equal(joined.confidence, .confirmed)
                expect.equal(joined.source, .browserSensor)
                expect.equal(joined.muted, false)
            },

            test("a prejoin screen is not recorded while the extension is reporting") { expect in
                // Meet holds the microphone on its prejoin screen, so the native
                // dwell confirms a meeting that has not been joined. The sensor
                // knows better, and an abandoned prejoin must leave no directory.
                var detector = BrowserMeetingDetector()
                var now = 100.0
                let native = BrowserMeetingDetector.NativeSignals(
                    browserHoldsMicrophone: true, browserProducesOutput: false,
                    windowTitles: ["Meet - jfp-btbt-owm"]
                )
                detector.sensorConnected(at: now)
                _ = detector.update(native: native, at: now)
                now += 30
                detector.receive(
                    BrowserMeetingEvent(
                        browser: .firefox, provider: .googleMeet, state: .prejoin,
                        timestamp: now, url: "https://meet.google.com/jfp-btbt-owm",
                        meetingID: "jfp-btbt-owm"
                    ),
                    at: now
                )
                let waiting = detector.update(native: native, at: now)
                expect.equal(
                    waiting.confidence, .candidate,
                    "the native dwell must not commit a prejoin the sensor can see"
                )

                // When the sensor goes quiet the native path takes over again.
                now += 30
                let silent = detector.update(native: native, at: now)
                expect.equal(
                    silent.confidence, .confirmed,
                    "losing the extension costs precision, and the meeting is still recorded"
                )
            },

            test("Zoom's title arrives before the microphone, and that is fine") { expect in
                var detector = BrowserMeetingDetector()
                var now = 100.0
                // Measured ordering: title at 16:41:26, microphone at 16:41:31.
                let titleOnly = BrowserMeetingDetector.NativeSignals(
                    browserHoldsMicrophone: false, browserProducesOutput: false,
                    windowTitles: ["Andrew Neeser's Zoom Meeting"]
                )
                let first = detector.update(native: titleOnly, at: now)
                expect.equal(first.provider, .zoom)
                expect.equal(first.confidence, .none, "a title alone is not a meeting")

                now += 5.3
                let withMic = BrowserMeetingDetector.NativeSignals(
                    browserHoldsMicrophone: true, browserProducesOutput: true,
                    windowTitles: ["Andrew Neeser's Zoom Meeting"]
                )
                expect.equal(detector.update(native: withMic, at: now).confidence, .candidate)
                now += 21
                let confirmed = detector.update(native: withMic, at: now)
                expect.equal(confirmed.confidence, .confirmed)
                expect.equal(confirmed.title, "Andrew Neeser's Zoom Meeting")
            },

            test("a stale sensor falls back to native without losing the meeting") { expect in
                var detector = BrowserMeetingDetector(freshnessWindow: 5)
                var now = 100.0
                detector.sensorConnected(at: now)
                detector.receive(
                    BrowserMeetingEvent(
                        browser: .firefox, provider: .googleMeet, state: .inCall,
                        timestamp: now, meetingID: "abc-defg-hij"
                    ),
                    at: now
                )
                let native = BrowserMeetingDetector.NativeSignals(
                    browserHoldsMicrophone: true, browserProducesOutput: true,
                    windowTitles: ["Meet - abc-defg-hij"]
                )
                expect.equal(detector.update(native: native, at: now).source, .browserSensor)

                // The extension stops reporting. Native evidence carries the meeting.
                now += 30
                let fallback = detector.update(native: native, at: now)
                expect.equal(fallback.source, .native)
                expect.equal(fallback.confidence, .confirmed, "the meeting must not vanish")
                expect.equal(fallback.meetingID, "abc-defg-hij")
                expect.equal(detector.sensor.connection, .stale)
            },

            test("a refresh does not look like a leave") { expect in
                var detector = BrowserMeetingDetector()
                var now = 100.0
                let live = BrowserMeetingDetector.NativeSignals(
                    browserHoldsMicrophone: true, browserProducesOutput: true,
                    windowTitles: ["Meet - hzc-josd-epv"]
                )
                _ = detector.update(native: live, at: now)
                now += 25
                expect.equal(detector.update(native: live, at: now).confidence, .confirmed)

                // Measured refresh: microphone drops for 1.486 s and comes back with
                // the same meeting ID.
                now += 0.5
                let dropped = BrowserMeetingDetector.NativeSignals(
                    browserHoldsMicrophone: false, browserProducesOutput: false,
                    windowTitles: ["Meet"]
                )
                expect.equal(detector.update(native: dropped, at: now).confidence, .candidate)
                now += 1.5
                let back = detector.update(native: live, at: now)
                expect.equal(back.meetingID, "hzc-josd-epv")
            },

            test("meeting identifiers come out of provider URLs") { expect in
                expect.equal(
                    MeetingURLParser.meetingID(forURL: "https://meet.google.com/jfp-btbt-owm"),
                    "jfp-btbt-owm"
                )
                expect.equal(
                    MeetingURLParser.meetingID(forURL: "https://app.zoom.us/wc/81771591841/join"),
                    "81771591841"
                )
                expect.equal(MeetingURLParser.provider(forURL: "https://app.zoom.us/wc/1/join"), .zoom)
                expect.isNil(MeetingURLParser.provider(forURL: "https://example.com"))
            },
        ])
    }

    static var genericSuite: Suite {
        Suite("GenericCallDetector", [
            test("system speech services never become a meeting") { expect in
                var detector = GenericCallDetector()
                var now = 100.0
                // corespeechd held the microphone for the whole observed session.
                let states = [
                    ApplicationAudioState(
                        bundleIdentifier: "com.apple.CoreSpeech", processID: 808,
                        holdsMicrophone: true, producesOutput: false,
                        isFrontmost: false, windowTitle: nil
                    ),
                ]
                for _ in 0..<400 {
                    now += 0.5
                    expect.equal(detector.update(states: states, at: now), [])
                }
            },

            test("a remote desktop session is never a meeting") { expect in
                // Jump Desktop Connect holds the microphone and plays audio for as
                // long as the session lasts, which is every signal the detector
                // has. It recorded a remote-desktop session as a call.
                var detector = GenericCallDetector()
                let states = [
                    ApplicationAudioState(
                        bundleIdentifier: "com.p5sys.jump.connect", processID: 500,
                        holdsMicrophone: true, producesOutput: true,
                        isFrontmost: false, windowTitle: nil
                    ),
                    ApplicationAudioState(
                        bundleIdentifier: "com.apple.ScreenSharing", processID: 501,
                        holdsMicrophone: true, producesOutput: true,
                        isFrontmost: false, windowTitle: nil
                    ),
                ]
                var now = 100.0
                for _ in 0..<200 {
                    now += 0.5
                    expect.equal(detector.update(states: states, at: now), [])
                }
                expect.equal(detector.currentEvidence().count, 0, "nothing to record here")
            },

            test("an unknown call is a candidate before it is confirmed") { expect in
                // The ring has to be armed while the dwell is still running,
                // otherwise the first eight to twenty-five seconds of the call
                // exist nowhere by the time it is promoted.
                var detector = GenericCallDetector()
                let states = [
                    ApplicationAudioState(
                        bundleIdentifier: "com.example.videochat", processID: 4242,
                        holdsMicrophone: true, producesOutput: true,
                        isFrontmost: true, windowTitle: "Team call"
                    ),
                ]
                _ = detector.update(states: states, at: 100)
                let early = detector.currentEvidence()
                expect.equal(early.count, 1)
                expect.equal(early.first?.confidence, .candidate, "armed but not committed")
                expect.equal(early.first?.audioBundlePrefixes, ["com.example.videochat"])

                _ = detector.update(states: states, at: 100 + 9)
                let promoted = detector.currentEvidence()
                expect.equal(promoted.first?.confidence, .confirmed, "the dwell has passed")

                // An ignored process never reaches the evidence at all.
                _ = detector.update(states: [
                    ApplicationAudioState(
                        bundleIdentifier: "com.apple.CoreSpeech", processID: 808,
                        holdsMicrophone: true, producesOutput: false,
                        isFrontmost: false, windowTitle: nil
                    ),
                ], at: 110)
                expect.isFalse(
                    detector.currentEvidence().contains { $0.applicationBundleID == "com.apple.CoreSpeech" },
                    "the ignore list keeps system services out entirely"
                )
            },

            test("a sustained two-way call in an unknown app is promoted") { expect in
                var detector = GenericCallDetector()
                var now = 100.0
                let states = [
                    ApplicationAudioState(
                        bundleIdentifier: "com.example.videochat", processID: 4_242,
                        holdsMicrophone: true, producesOutput: true,
                        isFrontmost: true, windowTitle: "Team call"
                    ),
                ]
                var promoted: GenericCallDetector.Candidate?
                for _ in 0..<40 {
                    now += 0.5
                    for event in detector.update(states: states, at: now) {
                        if case .callLikely(let candidate) = event { promoted = candidate }
                    }
                    if promoted != nil { break }
                }
                let candidate = try expect.unwrap(promoted)
                expect.equal(candidate.bundleIdentifier, "com.example.videochat")
                expect.isTrue(candidate.hasTwoWayAudio)
                expect.isTrue(candidate.heldForSeconds >= 8)
            },

            test("an application the user always records starts immediately") { expect in
                var detector = GenericCallDetector(
                    configuration: .init(alwaysRecord: ["com.example.videochat"])
                )
                let events = detector.update(
                    states: [
                        ApplicationAudioState(
                            bundleIdentifier: "com.example.videochat", processID: 1,
                            holdsMicrophone: true, producesOutput: false,
                            isFrontmost: true, windowTitle: nil
                        ),
                    ],
                    at: 100
                )
                guard case .callLikely(let candidate) = events.first else {
                    expect.fail("expected an immediate candidate, got \(events)")
                    return
                }
                expect.isTrue(candidate.isPreapproved)
            },

            test("an application the user never records is ignored") { expect in
                var detector = GenericCallDetector(
                    configuration: .init(neverRecord: ["com.example.videochat"])
                )
                var now = 100.0
                for _ in 0..<200 {
                    now += 0.5
                    expect.equal(
                        detector.update(
                            states: [
                                ApplicationAudioState(
                                    bundleIdentifier: "com.example.videochat", processID: 1,
                                    holdsMicrophone: true, producesOutput: true,
                                    isFrontmost: true, windowTitle: nil
                                ),
                            ],
                            at: now
                        ),
                        []
                    )
                }
            },

            test("never record takes effect while the app still holds the microphone") { expect in
                // The user answers the provisional prompt with "never record this
                // app" while the call is still live. The tracked entry kept
                // publishing confirmed evidence for the six-second end grace,
                // which restarted the provisional recording and asked again.
                var detector = GenericCallDetector()
                let states = [
                    ApplicationAudioState(
                        bundleIdentifier: "com.example.videochat", processID: 4_242,
                        holdsMicrophone: true, producesOutput: true,
                        isFrontmost: true, windowTitle: "Team call"
                    ),
                ]
                _ = detector.update(states: states, at: 100)
                _ = detector.update(states: states, at: 109)
                expect.equal(detector.currentEvidence().first?.confidence, .confirmed)

                detector.configuration.neverRecord = ["com.example.videochat"]
                let events = detector.update(states: states, at: 109.5)
                expect.equal(events, [.callEnded(bundleIdentifier: "com.example.videochat")])
                expect.equal(
                    detector.currentEvidence().count, 0,
                    "the ban is immediate, not after the end grace"
                )
            },

            test("a ban recorded against a helper covers the whole application") { expect in
                // CoreAudio names whichever helper opened the microphone, and an
                // Electron application rotates through .helper, .helper.Renderer
                // and .helper.GPU. Stored as reported, the ban missed both the
                // siblings and the application itself, so the next poll that
                // found a different helper asked again.
                expect.equal(
                    MicrophoneIgnoreList.applicationIdentifier(for: "com.openai.chat.helper.Renderer"),
                    "com.openai.chat"
                )
                expect.equal(
                    MicrophoneIgnoreList.applicationIdentifier(for: "com.tinyspeck.slackmacgap.helper"),
                    "com.tinyspeck.slackmacgap"
                )
                // An application that is not a helper is stored exactly as it is.
                expect.equal(
                    MicrophoneIgnoreList.applicationIdentifier(for: "com.example.videochat"),
                    "com.example.videochat"
                )
                // Nothing is ever collapsed to fewer than three components: a ban
                // on "com" would prefix-match most of the machine.
                expect.equal(
                    MicrophoneIgnoreList.applicationIdentifier(for: "com.helper.app"),
                    "com.helper.app"
                )
                expect.equal(
                    MicrophoneIgnoreList.applicationIdentifier(for: "com.acme.helperapp"),
                    "com.acme.helperapp"
                )

                let banned = MicrophoneIgnoreList.applicationIdentifier(
                    for: "com.openai.chat.helper.Renderer"
                )
                var detector = GenericCallDetector(configuration: .init(neverRecord: [banned]))
                var when = 100.0
                for sibling in [
                    "com.openai.chat", "com.openai.chat.helper", "com.openai.chat.helper.GPU",
                ] {
                    when += 30
                    expect.equal(
                        detector.update(
                            states: [
                                ApplicationAudioState(
                                    bundleIdentifier: sibling, processID: 1,
                                    holdsMicrophone: true, producesOutput: true,
                                    isFrontmost: true, windowTitle: nil
                                ),
                            ],
                            at: when
                        ),
                        [], "\(sibling) belongs to an application the user banned"
                    )
                }
                expect.equal(detector.currentEvidence().count, 0)
            },

            test("never record covers a descendant of a banned identifier") { expect in
                var detector = GenericCallDetector(
                    configuration: .init(neverRecord: ["com.example.videochat"])
                )
                var now = 100.0
                for _ in 0..<200 {
                    now += 0.5
                    expect.equal(
                        detector.update(
                            states: [
                                ApplicationAudioState(
                                    bundleIdentifier: "com.example.videochat.helper.Renderer",
                                    processID: 1,
                                    holdsMicrophone: true, producesOutput: true,
                                    isFrontmost: true, windowTitle: nil
                                ),
                            ],
                            at: now
                        ),
                        []
                    )
                }
                expect.equal(detector.currentEvidence().count, 0)
            },
        ])
    }

    static var all: [Suite] { [slackSuite, browserSuite, genericSuite] }
}
