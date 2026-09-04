import AVFoundation
import Foundation
import PipitAudio
import PipitCore
import PipitServices
import TestKit

/// The cleaned microphone track: what comes out of it, what it is called, and
/// the meetings it must refuse to touch.
///
/// The problem it solves, measured on a Slack huddle of 3 September 2026: 81%
/// of the words on the microphone were the far end's, arriving through the air
/// from the speakers. Every earlier attempt worked on the transcript, guessing
/// which words to delete, and deleted the local user's 3957 words instead.
enum MicrophoneCleanerTests {
    static let rate = 16_000.0
    /// The far end's own voice, playing for the whole call.
    ///
    /// None of these divide 16 kHz into a whole number of samples. A tone that
    /// does, 400 Hz at 40 samples, repeats exactly on the block grid, which
    /// leaves the delay between the reference and its copy in the microphone
    /// ambiguous at every multiple of the period. The canceller's filter never
    /// converges on it and it reports the 0.18 dB floor of its own estimator.
    static let farToneA = 440.0
    /// A second far-end tone that starts halfway through, so the canceller has
    /// to keep tracking rather than settling on one frequency.
    static let farToneB = 950.0
    /// The local user, talking over the far end for the middle third.
    static let nearTone = 1_300.0
    /// What the room does to the far end on its way back to the capsule: a
    /// third of the level, 3 ms across the desk.
    static let echoGain: Float = 0.35
    static let echoDelaySamples = 48

    // MARK: - building a meeting

    /// A recorded two-track meeting whose audio is exactly the samples given.
    ///
    /// `remoteStartOffset` puts the far end's first frame that many seconds
    /// after the microphone's, which is what a real recording looks like: the
    /// remote writer opens on the first packet from the meeting application,
    /// and that is always after the microphone begins.
    static func makeMeeting(
        root: URL, source: MeetingSource = .slackHuddle,
        mic: [Float], remote: [Float]?, remoteStartOffset: Double = 0
    ) throws -> (metadata: MeetingMetadata, store: MeetingStore, repository: MeetingRepository) {
        let repository = MeetingRepository(root: root)
        let started = Date(timeIntervalSince1970: 1_787_070_000)
        let created = try repository.createMeeting(
            source: source, provider: source.provider, startedAt: started,
            titles: TitleCandidates(provider: "Huddle", timestampFallback: "fallback"),
            now: started
        )
        let manifest = try ManifestWriter(url: created.store.layout.manifest)
        manifest.append(.sessionStart(.init(
            meetingID: created.metadata.id, source: source, segmentSeconds: 600,
            appVersion: "test", processID: 1
        )))
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!

        let micWriter = SegmentWriter(
            track: .mic, layout: created.store.layout, manifest: manifest,
            format: format, segmentSeconds: 600
        )
        micWriter.enqueueSynchronously(AudioBufferPacket(buffer: buffer(mic, format: format), hostTime: 100))
        micWriter.finish(reason: "test")

        if let remote {
            let remoteWriter = SegmentWriter(
                track: .remote, layout: created.store.layout, manifest: manifest,
                format: format, segmentSeconds: 600
            )
            remoteWriter.enqueueSynchronously(AudioBufferPacket(
                buffer: buffer(remote, format: format), hostTime: 100 + remoteStartOffset
            ))
            remoteWriter.finish(reason: "test")
        }
        let seconds = Double(mic.count) / rate
        manifest.append(.sessionEnd(.init(
            reason: "test", micSeconds: seconds,
            remoteSeconds: remote.map { Double($0.count) / rate } ?? 0
        )))
        manifest.close()

        var metadata = created.metadata
        metadata.endedAt = started.addingTimeInterval(seconds)
        metadata.durationSeconds = seconds
        metadata.processing = ProcessingStatus(state: .audioSafe, updatedAt: started)
        try created.store.writeMetadata(metadata)
        return (metadata, created.store, repository)
    }

    static func buffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer {
        let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        out.frameLength = AVAudioFrameCount(samples.count)
        let data = out.floatChannelData!
        for index in samples.indices { data[0][index] = samples[index] }
        return out
    }

    static func tone(
        count: Int, frequency: Double, amplitude: Float, from: Int = 0, upTo: Int? = nil
    ) -> [Float] {
        var samples = [Float](repeating: 0, count: count)
        for index in from..<min(upTo ?? count, count) {
            samples[index] = amplitude * Float(sin(2 * Double.pi * frequency * Double(index) / rate))
        }
        return samples
    }

    /// Every sample of a track, read the way the pipeline reads it.
    static func samples(_ location: TrackAudioLocation) throws -> [Float] {
        let stream = TrackAudioStream(
            segments: location.segments, segmentsDirectory: location.directory,
            format: AudioFormatDescriptor(sampleRate: rate, channelCount: 1)
        )
        var out: [Float] = []
        try stream.forEachBuffer(from: 0, to: location.seconds) { buffer, _ in
            if let data = buffer.floatChannelData {
                out.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
            }
            return true
        }
        return out
    }

    static func seconds(_ from: Double, _ to: Double, of samples: [Float]) -> [Float] {
        let start = min(samples.count, Int(from * rate))
        let end = min(samples.count, Int(to * rate))
        guard end > start else { return [] }
        return Array(samples[start..<end])
    }

    /// Energy at one frequency, by the Goertzel recurrence. Broadband energy
    /// after cancellation is mostly residue from subtracting the far end, so it
    /// says nothing about the tone actually asked about.
    static func toneEnergy(_ samples: [Float], frequency: Double) -> Double {
        AudioTests.toneEnergy(samples, frequency: frequency, sampleRate: rate)
    }

    static func dropDB(from before: Double, to after: Double) -> Double {
        10 * log10((before + 1e-12) / (after + 1e-12))
    }

    /// The second, to a fiftieth of one, at which a tone starts.
    ///
    /// The first 20 ms window past `after` whose energy at that frequency
    /// passes half the level it holds once the tone is running.
    static func onset(of samples: [Float], frequency: Double, after: Double, steady: Double)
        -> Double
    {
        let step = Int(0.02 * rate)
        var index = Int(after * rate)
        while index + step <= samples.count {
            if toneEnergy(Array(samples[index..<(index + step)]), frequency: frequency) > steady / 2 {
                return Double(index) / rate
            }
            index += step
        }
        return .infinity
    }

    // MARK: - the two-track meeting every measurement is taken on

    /// A call on speakers. The far end plays throughout, the user talks over it
    /// for the middle third, and a third of the far end is back in the
    /// microphone 3 ms later.
    static func makeCallOnSpeakers(root: URL, seconds: Double = 30, remoteStartOffset: Double = 2)
        throws -> (metadata: MeetingMetadata, store: MeetingStore, repository: MeetingRepository)
    {
        let count = Int(seconds * rate)
        var remote = tone(count: count, frequency: farToneA, amplitude: 0.5)
        let second = tone(count: count, frequency: farToneB, amplitude: 0.4, from: count / 2)
        for index in 0..<count { remote[index] += second[index] }

        // The user, for the middle third of their own track.
        var mic = tone(
            count: count, frequency: nearTone, amplitude: 0.3,
            from: count / 3, upTo: 2 * count / 3
        )
        // The far end coming back through the air. The far end's first frame
        // landed `remoteStartOffset` seconds after the microphone's, so far-end
        // sample j was in the room at microphone sample j + offset + delay.
        let shift = Int(remoteStartOffset * rate) + echoDelaySamples
        for index in shift..<count { mic[index] += echoGain * remote[index - shift] }

        return try makeMeeting(
            root: root, mic: mic, remote: remote, remoteStartOffset: remoteStartOffset
        )
    }

    static let suite = Suite("MicrophoneCleaner", [
        test("the cleaned microphone loses the far end and keeps the user") { expect in
            let root = try ManifestTests.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let meeting = try makeCallOnSpeakers(root: root)
            let store = meeting.store
            let timeline = try store.readTimeline()

            let outcome = try MicrophoneCleaner().clean(
                store: store, metadata: meeting.metadata, timeline: timeline
            )
            expect.equal(outcome, CleaningOutcome.cleaned)
            expect.isTrue(
                FileManager.default.fileExists(atPath: store.layout.cleanedMicFile.path),
                "the cleaned track is on disk"
            )

            let metadata = try store.readMetadata()
            let cleaned = try expect.unwrap(metadata.cleanedMic)
            expect.equal(cleaned.track.file, "mic.cleaned.m4a")
            expect.equal(cleaned.track.sampleRate, rate)
            expect.equal(cleaned.track.channelCount, 1)
            expect.close(cleaned.track.seconds, 30, tolerance: 0.2)

            let raw = try samples(store.rawTrackAudioLocation(
                track: .mic, metadata: metadata, timeline: timeline
            ))
            let clean = try samples(store.trackAudioLocation(
                track: .mic, metadata: metadata, timeline: timeline
            ))
            expect.equal(clean.count, raw.count, "the cleaned track runs as long as the recording")

            // Measured over the last third, where the user is silent. The
            // first third is not comparable: the canceller reports nothing
            // until it has heard 2.5 s of far-end activity, and the far end
            // here does not start until two seconds in. Measured at 88.1 dB.
            let farBefore = toneEnergy(seconds(20, 30, of: raw), frequency: farToneA)
            let farAfter = toneEnergy(seconds(20, 30, of: clean), frequency: farToneA)
            let removed = dropDB(from: farBefore, to: farAfter)
            expect.isTrue(removed > 20, "the far end came down only \(removed) dB")

            // And the user, over the middle third, where they are talking
            // across the far end. This is the number every earlier attempt got
            // wrong. Measured at 0.33 dB.
            let userBefore = toneEnergy(seconds(10, 20, of: raw), frequency: nearTone)
            let userAfter = toneEnergy(seconds(10, 20, of: clean), frequency: nearTone)
            let lost = dropDB(from: userBefore, to: userAfter)
            expect.isTrue(lost < 3, "the user lost \(lost) dB of their own voice")

            // And it sits on the same clock the recording does. An encoder that
            // put its own priming frames at the front would move every
            // timestamp in the transcript by that much.
            let steady = toneEnergy(seconds(15, 15.02, of: raw), frequency: nearTone)
            let rawOnset = onset(of: raw, frequency: nearTone, after: 9, steady: steady)
            let cleanOnset = onset(of: clean, frequency: nearTone, after: 9, steady: steady)
            expect.close(rawOnset, 10, tolerance: 0.02)
            expect.close(cleanOnset, rawOnset, tolerance: 0.02)
        },

        test("a cleaned meeting reads the cleaned track and still reaches the raw one") { expect in
            let root = try ManifestTests.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let meeting = try makeCallOnSpeakers(root: root)
            let store = meeting.store
            let timeline = try store.readTimeline()

            // Before the cleaner runs, both resolve to the recording. This is
            // what makes the assertions below mean something.
            let before = store.trackAudioLocation(
                track: .mic, metadata: meeting.metadata, timeline: timeline
            )
            expect.equal(before.directory.lastPathComponent, "segments")

            _ = try MicrophoneCleaner().clean(
                store: store, metadata: meeting.metadata, timeline: timeline
            )
            let metadata = try store.readMetadata()
            let cleaned = store.trackAudioLocation(
                track: .mic, metadata: metadata, timeline: timeline
            )
            expect.equal(cleaned.segments.first?.file, "mic.cleaned.m4a")
            expect.equal(cleaned.directory.lastPathComponent, "audio")
            // The mixdown aligns tracks by this, and the cleaned track starts on
            // the same frame the recording did.
            expect.equal(
                cleaned.segments.first?.resolvedFirstFrameHostTime,
                timeline.firstFrameHostTime(track: .mic)
            )

            let raw = store.rawTrackAudioLocation(
                track: .mic, metadata: metadata, timeline: timeline
            )
            expect.equal(raw.directory.lastPathComponent, "segments")
            expect.isTrue(
                raw.segments.first?.file.hasSuffix(".caf") == true,
                "the recording is still where it was"
            )
            // The far end is untouched either way: only the microphone is
            // cleaned.
            let remote = store.trackAudioLocation(
                track: .remote, metadata: metadata, timeline: timeline
            )
            expect.equal(remote.directory.lastPathComponent, "segments")
        },

        test("a meeting whose far end never played is left alone") { expect in
            let root = try ManifestTests.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let count = Int(15 * rate)
            let meeting = try makeMeeting(
                root: root,
                mic: tone(count: count, frequency: nearTone, amplitude: 0.3),
                remote: [Float](repeating: 0, count: count)
            )
            let store = meeting.store
            let timeline = try store.readTimeline()
            expect.isFalse(
                store.rawTrackAudioLocation(
                    track: .remote, metadata: meeting.metadata, timeline: timeline
                ).isEmpty,
                "the far end was recorded, it just holds nothing"
            )

            let outcome = try MicrophoneCleaner().clean(
                store: store, metadata: meeting.metadata, timeline: timeline
            )
            expect.equal(outcome, CleaningOutcome.skippedNoReference)
            expect.isFalse(
                FileManager.default.fileExists(atPath: store.layout.cleanedMicFile.path),
                "no cleaned track was written"
            )
            expect.isNil(try store.readMetadata().cleanedMic)
        },

        test("a call taken on headphones keeps the microphone it recorded") { expect in
            let root = try ManifestTests.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            // The far end plays and the microphone holds only the user, which is
            // every call taken on headphones. Cancelling anyway takes tens of
            // decibels out of the user, so the only safe answer is the
            // recording.
            let count = Int(15 * rate)
            let meeting = try makeMeeting(
                root: root,
                mic: tone(count: count, frequency: 700, amplitude: 0.3),
                remote: tone(count: count, frequency: farToneA, amplitude: 0.5)
            )
            let store = meeting.store
            let timeline = try store.readTimeline()

            let outcome = try MicrophoneCleaner().clean(
                store: store, metadata: meeting.metadata, timeline: timeline
            )
            expect.equal(outcome, CleaningOutcome.bypassedNoEchoPath)
            expect.isFalse(
                FileManager.default.fileExists(atPath: store.layout.cleanedMicFile.path),
                "the cleaned track was deleted rather than kept"
            )
            let metadata = try store.readMetadata()
            expect.isNil(metadata.cleanedMic)
            expect.equal(
                store.trackAudioLocation(track: .mic, metadata: metadata, timeline: timeline)
                    .directory.lastPathComponent,
                "segments"
            )
        },

        test("a recording holding everyone on one track has no far end to subtract") { expect in
            let root = try ManifestTests.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let count = Int(2 * rate)
            let meeting = try makeMeeting(
                root: root, source: .imported,
                mic: tone(count: count, frequency: nearTone, amplitude: 0.3), remote: nil
            )
            let store = meeting.store
            let outcome = try MicrophoneCleaner().clean(
                store: store, metadata: meeting.metadata, timeline: try store.readTimeline()
            )
            expect.equal(outcome, CleaningOutcome.skippedOneTrack)
            expect.isFalse(
                FileManager.default.fileExists(atPath: store.layout.cleanedMicFile.path),
                "no cleaned track was written"
            )
        },
    ])
}
