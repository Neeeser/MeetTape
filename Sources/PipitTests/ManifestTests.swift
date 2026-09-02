import Foundation
import PipitCore
import TestKit

enum ManifestTests {
    static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pipit-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var suite: Suite {
        Suite("Manifest", [
            test("every event round-trips through JSONL") { expect in
                let directory = try makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: directory) }
                let url = directory.appendingPathComponent("manifest.jsonl")
                let writer = try ManifestWriter(url: url)

                let events: [ManifestEvent] = [
                    .sessionStart(.init(
                        meetingID: "2026-08-18-1418-slack-huddle", source: .slackHuddle,
                        segmentSeconds: 30, appVersion: "1.0.0", processID: 1234
                    )),
                    .segmentOpen(.init(
                        track: .mic, index: 1, file: "mic.0001.caf", firstFrameHostTime: 12.5,
                        startFrame: 0, sampleRate: 48_000, channelCount: 1, reason: "start"
                    )),
                    .segmentClose(.init(
                        track: .mic, index: 1, frameCount: 1_440_000, byteCount: 5_760_000,
                        seconds: 30, firstFrameHostTime: 12.5, reason: "rotate"
                    )),
                    .formatChange(.init(
                        track: .mic,
                        from: AudioFormatDescriptor(sampleRate: 48_000, channelCount: 1),
                        to: AudioFormatDescriptor(sampleRate: 16_000, channelCount: 1),
                        reason: "config_change"
                    )),
                    .captureRestart(.init(track: .mic, reason: "watchdog", restartCount: 1)),
                    .remoteBind(.init(
                        reason: "session_start",
                        targets: [
                            .init(
                                processID: 79_590, bundleIdentifier: "org.mozilla.firefox",
                                isRunningOutput: true
                            ),
                            .init(
                                processID: 45_082,
                                bundleIdentifier: "com.tinyspeck.slackmacgap.helper",
                                isRunningOutput: false
                            ),
                        ],
                        bindCount: 1
                    )),
                    .sourceHealth(.init(track: .remote, state: .idleButBound, detail: nil)),
                    .preRollFlushed(.init(track: .mic, frameCount: 720_000, seconds: 15, earliestHostTime: 1.0)),
                    .marker(.init(label: "user note")),
                    .crashTailAdopted(.init(
                        track: .mic, index: 2, frameCount: 4_320, byteCount: 17_280, seconds: 0.09
                    )),
                    .sessionEnd(.init(reason: "provider_ended", micSeconds: 30.09, remoteSeconds: 29.5)),
                ]
                for event in events {
                    expect.isTrue(writer.append(event, hostTime: 100, wallClock: Date(timeIntervalSince1970: 1)))
                }
                writer.close()

                let result = try ManifestReader.read(contentsOf: url)
                expect.equal(result.lines.count, events.count)
                expect.equal(result.unrecognisedLines, 0)
                expect.isFalse(result.hasTruncatedTail)
                for (line, event) in zip(result.lines, events) {
                    expect.equal(line.event, event)
                    expect.equal(line.hostTime, 100)
                }
            },

            test("total duration sums per-segment rates, never a global divide") { expect in
                // The exact shape the stress test hit: 48 kHz, then Bluetooth HFP at
                // 16 kHz, then back. Dividing accumulated frames by the current rate
                // under-reported a real session by two thirds.
                let lines = timelineLines(segments: [
                    (track: .mic, index: 1, rate: 48_000.0, frames: Int64(48_000 * 30)),
                    (track: .mic, index: 2, rate: 16_000.0, frames: Int64(16_000 * 180)),
                    (track: .mic, index: 3, rate: 48_000.0, frames: Int64(48_000 * 30)),
                ])
                let timeline = ManifestReader.timeline(from: lines)

                expect.close(timeline.duration(track: .mic), 240.0, tolerance: 0.001)

                let totalFrames = timeline.segments(track: .mic).reduce(Int64(0)) { $0 + ($1.frameCount ?? 0) }
                let naive = Double(totalFrames) / 48_000.0
                expect.close(naive, 120.0, tolerance: 0.001, "the naive formula should be visibly wrong")
                expect.isTrue(
                    abs(timeline.duration(track: .mic) - naive) > 100,
                    "per-segment accounting must not agree with the naive formula here"
                )
            },

            test("rotation is not a gap, and a real gap is") { expect in
                // The writer rotates every thirty seconds, so a long call is
                // many segments recorded back to back. Counting segments would
                // call every real meeting discontiguous and silently turn off
                // everything that places itself by a single host-time shift.
                let rotating = ManifestReader.timeline(from: timelineLines(segments: [
                    (track: .remote, index: 1, rate: 48_000.0, frames: Int64(48_000 * 30),
                     host: 1_000.0),
                    (track: .remote, index: 2, rate: 48_000.0, frames: Int64(48_000 * 30),
                     host: 1_030.0),
                    (track: .remote, index: 3, rate: 48_000.0, frames: Int64(48_000 * 30),
                     host: 1_060.0),
                ]))
                expect.isTrue(
                    rotating.isContiguous(track: .remote),
                    "thirty-second rotation is how every meeting is recorded"
                )

                // A sleep/wake or a tap rebind leaves audio missing, and
                // everything after it sits early on the concatenated timeline.
                let gapped = ManifestReader.timeline(from: timelineLines(segments: [
                    (track: .remote, index: 1, rate: 48_000.0, frames: Int64(48_000 * 30),
                     host: 1_000.0),
                    (track: .remote, index: 2, rate: 48_000.0, frames: Int64(48_000 * 30),
                     host: 1_050.0),
                ]))
                expect.isFalse(gapped.isContiguous(track: .remote))
            },

            test("a restart inside the last segment is a gap, an earlier one is not") { expect in
                // A restart does not force a rotation, so a sleep and wake in
                // the last thirty seconds leaves the missing audio inside the
                // final segment, with nothing after it to measure against. The
                // restart record is the only evidence there is.
                func withRestart(at hostTime: Double) -> RecordingTimeline {
                    let result = timelineLines(segments: [
                        (track: .remote, index: 1, rate: 48_000.0, frames: Int64(48_000 * 30),
                         host: 1_000.0),
                        (track: .remote, index: 2, rate: 48_000.0, frames: Int64(48_000 * 30),
                         host: 1_030.0),
                    ])
                    return ManifestReader.timeline(from: ManifestReadResult(
                        lines: result.lines + [ManifestLine(
                            hostTime: hostTime, wallClock: Date(timeIntervalSince1970: hostTime),
                            event: .captureRestart(.init(
                                track: .remote, reason: "wake", restartCount: 1
                            ))
                        )],
                        hasTruncatedTail: false, unrecognisedLines: 0
                    ))
                }

                expect.isFalse(withRestart(at: 1_045).isContiguous(track: .remote))
                // Rebinding the tap is ordinary and usually costs no audio: it
                // happens before a track's first frame when a generic call
                // becomes a recognised one, and whenever a browser's helper
                // processes come and go. Where it does cost audio, the segment
                // boundary shows it; treating every restart as a gap threw the
                // record away for most real meetings.
                expect.isTrue(
                    withRestart(at: 1_010).isContiguous(track: .remote),
                    "an earlier restart the boundaries already cover"
                )
                expect.isTrue(
                    withRestart(at: 1_045).isContiguous(track: .mic),
                    "the other track is unaffected"
                )
            },

            test("meeting duration is the longer of the two tracks") { expect in
                let lines = timelineLines(segments: [
                    (track: .mic, index: 1, rate: 48_000.0, frames: Int64(48_000 * 30)),
                    (track: .remote, index: 1, rate: 44_100.0, frames: Int64(44_100 * 25)),
                ])
                let timeline = ManifestReader.timeline(from: lines)
                expect.close(timeline.duration, 30.0, tolerance: 0.001)
                expect.close(timeline.duration(track: .remote), 25.0, tolerance: 0.001)
            },

            test("a truncated last line is a crash tail, not a corrupt manifest") { expect in
                let directory = try makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: directory) }
                let url = directory.appendingPathComponent("manifest.jsonl")
                let writer = try ManifestWriter(url: url)
                writer.append(.sessionStart(.init(
                    meetingID: "m", source: .googleMeet, segmentSeconds: 30,
                    appVersion: "1.0.0", processID: 1
                )))
                writer.append(.segmentOpen(.init(
                    track: .mic, index: 1, file: "mic.0001.caf", firstFrameHostTime: nil,
                    startFrame: 0, sampleRate: 48_000, channelCount: 1, reason: "start"
                )))
                writer.close()

                // Simulate SIGKILL partway through the next fsync'd line.
                var data = try Data(contentsOf: url)
                data.append(contentsOf: Array(#"{"ev":"segment_close","host":1"#.utf8))
                try data.write(to: url)

                let result = try ManifestReader.read(contentsOf: url)
                expect.isTrue(result.hasTruncatedTail)
                expect.equal(result.unrecognisedLines, 0)
                let timeline = ManifestReader.timeline(from: result)
                expect.equal(timeline.openSegments.count, 1)
                expect.isTrue(timeline.wasInterrupted)
                expect.isFalse(timeline.isComplete)
            },

            test("recovery can append to a manifest that was cut off mid-line") { expect in
                // Startup recovery reopens the manifest of a killed recording and
                // appends what it adopted. Writing straight onto the partial line
                // glues the two together, and both records are then unreadable.
                let directory = try makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: directory) }
                let url = directory.appendingPathComponent("manifest.jsonl")
                let writer = try ManifestWriter(url: url)
                writer.append(.sessionStart(.init(
                    meetingID: "m", source: .googleMeet, segmentSeconds: 30,
                    appVersion: "1.0.0", processID: 1
                )))
                writer.append(.segmentOpen(.init(
                    track: .mic, index: 1, file: "mic.0001.caf", firstFrameHostTime: nil,
                    startFrame: 0, sampleRate: 48_000, channelCount: 1, reason: "start"
                )))
                writer.close()
                var data = try Data(contentsOf: url)
                data.append(contentsOf: Array(#"{"ev":"segment_close","host":1"#.utf8))
                try data.write(to: url)

                let recovery = try ManifestWriter(url: url)
                recovery.append(.crashTailAdopted(.init(
                    track: .mic, index: 1, frameCount: 480_000, byteCount: 1_920_000, seconds: 10
                )))
                recovery.append(.sessionEnd(.init(reason: "recovered", micSeconds: 10, remoteSeconds: 0)))
                recovery.close()

                let result = try ManifestReader.read(contentsOf: url)
                // The fragment stays in the file and is skipped. What matters is
                // that the records written after it are readable.
                expect.equal(result.unrecognisedLines, 1, "only the crash fragment is dropped")
                expect.equal(result.lines.count, 4, "both recovery records survived")
                let timeline = ManifestReader.timeline(from: result)
                expect.equal(timeline.openSegments.count, 0, "the tail closed the open segment")
                expect.close(timeline.duration(track: .mic), 10, tolerance: 0.01)
                expect.isTrue(timeline.isComplete)
            },

            test("an unknown future event does not discard the recording") { expect in
                var data = Data()
                let writerLines = [
                    #"{"ev":"session_start","host":1,"t":"2026-08-18T18:00:00.000Z","meetingID":"m","source":"manual","segmentSeconds":30,"appVersion":"1.0.0","processID":1}"#,
                    #"{"ev":"something_new","host":2,"t":"2026-08-18T18:00:01.000Z"}"#,
                    #"{"ev":"segment_open","host":3,"t":"2026-08-18T18:00:02.000Z","track":"mic","index":1,"file":"mic.0001.caf","startFrame":0,"sampleRate":48000,"channelCount":1,"reason":"start"}"#,
                ]
                for line in writerLines {
                    data.append(contentsOf: Array(line.utf8))
                    data.append(0x0A)
                }
                let result = ManifestReader.parse(data)
                expect.equal(result.unrecognisedLines, 1)
                expect.equal(result.lines.count, 2)
                let timeline = ManifestReader.timeline(from: result)
                expect.equal(timeline.segments.count, 1)
                expect.equal(timeline.meetingID, "m")
            },

            test("an adopted crash tail contributes its real duration") { expect in
                var lines = timelineLines(segments: [
                    (track: .mic, index: 1, rate: 48_000.0, frames: Int64(48_000 * 30)),
                ]).lines
                lines.append(ManifestLine(
                    hostTime: 40, wallClock: Date(timeIntervalSince1970: 40),
                    event: .segmentOpen(.init(
                        track: .mic, index: 2, file: "mic.0002.caf", firstFrameHostTime: nil,
                        startFrame: 1_440_000, sampleRate: 48_000, channelCount: 1, reason: "rotate"
                    ))
                ))
                var timeline = ManifestReader.timeline(
                    from: ManifestReadResult(lines: lines, hasTruncatedTail: true, unrecognisedLines: 0)
                )
                expect.equal(timeline.openSegments.count, 1)
                expect.close(timeline.duration(track: .mic), 30.0, tolerance: 0.001)

                lines.append(ManifestLine(
                    hostTime: 41, wallClock: Date(timeIntervalSince1970: 41),
                    event: .crashTailAdopted(.init(
                        track: .mic, index: 2, frameCount: 4_320, byteCount: 17_280, seconds: 0.09
                    ))
                ))
                timeline = ManifestReader.timeline(
                    from: ManifestReadResult(lines: lines, hasTruncatedTail: true, unrecognisedLines: 0)
                )
                expect.equal(timeline.openSegments.count, 0)
                expect.close(timeline.duration(track: .mic), 30.09, tolerance: 0.001)
                expect.isTrue(timeline.segments.last?.wasAdoptedFromCrashTail == true)
            },
        ])
    }

    static func timelineLines(
        segments: [(track: CaptureTrack, index: Int, rate: Double, frames: Int64)]
    ) -> ManifestReadResult {
        var lines: [ManifestLine] = [
            ManifestLine(
                hostTime: 0, wallClock: Date(timeIntervalSince1970: 0),
                event: .sessionStart(.init(
                    meetingID: "meeting", source: .googleMeet, segmentSeconds: 30,
                    appVersion: "1.0.0", processID: 1
                ))
            ),
        ]
        var host = 1.0
        for segment in segments {
            lines.append(ManifestLine(
                hostTime: host, wallClock: Date(timeIntervalSince1970: host),
                event: .segmentOpen(.init(
                    track: segment.track, index: segment.index,
                    file: String(format: "%@.%04d.caf", segment.track.segmentPrefix, segment.index),
                    firstFrameHostTime: host, startFrame: 0,
                    sampleRate: segment.rate, channelCount: 1, reason: "rotate"
                ))
            ))
            host += 1
            lines.append(ManifestLine(
                hostTime: host, wallClock: Date(timeIntervalSince1970: host),
                event: .segmentClose(.init(
                    track: segment.track, index: segment.index, frameCount: segment.frames,
                    byteCount: segment.frames * 4, seconds: Double(segment.frames) / segment.rate,
                    firstFrameHostTime: host, reason: "rotate"
                ))
            ))
            host += 1
        }
        return ManifestReadResult(lines: lines, hasTruncatedTail: false, unrecognisedLines: 0)
    }

    /// Segments placed at chosen host times, for anything that reads where one
    /// segment ends and the next begins.
    static func timelineLines(
        segments: [(track: CaptureTrack, index: Int, rate: Double, frames: Int64, host: Double)]
    ) -> ManifestReadResult {
        var lines: [ManifestLine] = [
            ManifestLine(
                hostTime: 0, wallClock: Date(timeIntervalSince1970: 0),
                event: .sessionStart(.init(
                    meetingID: "meeting", source: .googleMeet, segmentSeconds: 30,
                    appVersion: "1.0.0", processID: 1
                ))
            ),
        ]
        for segment in segments {
            lines.append(ManifestLine(
                hostTime: segment.host, wallClock: Date(timeIntervalSince1970: segment.host),
                event: .segmentOpen(.init(
                    track: segment.track, index: segment.index,
                    file: String(format: "%@.%04d.caf", segment.track.segmentPrefix, segment.index),
                    // Nil, the way the writer records it: the host time is only
                    // known once a buffer has arrived, so the close record
                    // carries it. Seeding it here would let the gap check pass
                    // on a value production never has.
                    firstFrameHostTime: nil, startFrame: 0,
                    sampleRate: segment.rate, channelCount: 1, reason: "rotate"
                ))
            ))
            let seconds = Double(segment.frames) / segment.rate
            lines.append(ManifestLine(
                hostTime: segment.host + seconds,
                wallClock: Date(timeIntervalSince1970: segment.host + seconds),
                event: .segmentClose(.init(
                    track: segment.track, index: segment.index, frameCount: segment.frames,
                    byteCount: segment.frames * 4, seconds: seconds,
                    firstFrameHostTime: segment.host, reason: "rotate"
                ))
            ))
        }
        return ManifestReadResult(lines: lines, hasTruncatedTail: false, unrecognisedLines: 0)
    }
}
