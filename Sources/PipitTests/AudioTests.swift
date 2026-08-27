import AVFoundation
import Foundation
import PipitAudio
import PipitCore
import TestKit

/// Real audio through the real writers and readers. These use AVFoundation but no
/// audio hardware, so they run anywhere.
enum AudioTests {
    static func makeTone(
        seconds: Double, sampleRate: Double, channels: AVAudioChannelCount = 1,
        frequency: Double = 440, amplitude: Float = 0.5
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData!
        for frame in 0..<Int(frames) {
            let value = amplitude * Float(sin(2 * Double.pi * frequency * Double(frame) / sampleRate))
            for channel in 0..<Int(channels) { data[channel][frame] = value }
        }
        return buffer
    }

    /// A buffer in the shape a multi-channel built-in microphone delivers: more
    /// than two channels, discrete, with no surround layout to mix down from.
    static func makeDiscreteTone(
        seconds: Double, sampleRate: Double, channels: UInt32,
        frequency: Double = 440, amplitude: Float = 0.5
    ) -> AVAudioPCMBuffer {
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0
        )
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_DiscreteInOrder | channels
        let format = AVAudioFormat(
            streamDescription: &description,
            channelLayout: AVAudioChannelLayout(layout: &layout)
        )!
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData!
        for frame in 0..<Int(frames) {
            let value = amplitude * Float(sin(2 * Double.pi * frequency * Double(frame) / sampleRate))
            for channel in 0..<Int(channels) { data[channel][frame] = value }
        }
        return buffer
    }

    static func makeSilence(seconds: Double, sampleRate: Double) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData!
        for frame in 0..<Int(frames) { data[0][frame] = 0 }
        return buffer
    }

    static var suite: Suite {
        Suite("Audio", [
            test("takes read minutes apart are judged as one reading") { expect in
                // Somebody read part of the script, was told they were short,
                // and read some more. The two files are one reading with a
                // pause in the middle, and what judges it has to see them that
                // way or the second take is measured on its own and is short
                // too.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

                func write(_ seconds: Double, to name: String) throws -> URL {
                    let url = root.appendingPathComponent(name)
                    let file = try AVAudioFile(
                        forWriting: url, settings: format.settings,
                        commonFormat: .pcmFormatFloat32, interleaved: false
                    )
                    try file.write(from: makeTone(seconds: seconds, sampleRate: 48_000))
                    return url
                }

                let first = try write(2, to: "take-1.wav")
                let second = try write(3, to: "take-2.wav")
                let joined = root.appendingPathComponent("reading.wav")
                try AudioConcatenation.join([first, second], into: joined)

                let read = try AVAudioFile(forReading: joined)
                expect.equal(read.processingFormat.sampleRate, 48_000)
                let seconds = Double(read.length) / read.processingFormat.sampleRate
                expect.isTrue(
                    abs(seconds - 5) < 0.01,
                    "five seconds of reading, got \(seconds)"
                )
            },

            test("takes recorded at different rates are refused rather than resampled") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }

                func write(_ rate: Double, to name: String) throws -> URL {
                    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
                    let url = root.appendingPathComponent(name)
                    let file = try AVAudioFile(
                        forWriting: url, settings: format.settings,
                        commonFormat: .pcmFormatFloat32, interleaved: false
                    )
                    try file.write(from: makeTone(seconds: 1, sampleRate: rate))
                    return url
                }

                // The input device changed between takes. Joining them anyway
                // would play one of them at the wrong speed, which is a voice
                // that is not this person's.
                let first = try write(48_000, to: "take-1.wav")
                let second = try write(16_000, to: "take-2.wav")
                do {
                    try AudioConcatenation.join(
                        [first, second], into: root.appendingPathComponent("reading.wav")
                    )
                    expect.fail("two rates cannot be one reading")
                } catch let error as AudioConcatenationError {
                    expect.equal(error, .formatMismatch)
                }
            },

            test("the reading meter counts speech and ignores a quiet room") { expect in
                // The bar a reader watches. Elapsed time told a quick reader
                // they had done enough when they had not, so it counts audio
                // loud enough to be somebody talking instead.
                let speech = VoiceEnrollmentRecorder.speechSeconds(
                    in: makeTone(seconds: 0.5, sampleRate: 48_000, amplitude: 0.4)
                )
                expect.isTrue(abs(speech - 0.5) < 0.001, "half a second of speech, got \(speech)")

                expect.equal(
                    VoiceEnrollmentRecorder.speechSeconds(
                        in: makeTone(seconds: 0.5, sampleRate: 48_000, amplitude: 0.001)
                    ),
                    0,
                    "a room nobody is talking in fills no bar"
                )
            },

            test("segments rotate, close cleanly and report per-segment duration") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let layout = MeetingLayout(root: root)
                try FileManager.default.createDirectory(at: layout.segments, withIntermediateDirectories: true)
                let manifest = try ManifestWriter(url: layout.manifest)
                let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
                let writer = SegmentWriter(
                    track: .mic, layout: layout, manifest: manifest, format: format, segmentSeconds: 1
                )

                for index in 0..<5 {
                    let packet = AudioBufferPacket(
                        buffer: makeTone(seconds: 0.5, sampleRate: 48_000), hostTime: Double(index) * 0.5
                    )
                    writer.enqueueSynchronously(packet)
                }
                writer.finish(reason: "test")
                manifest.close()

                let timeline = try ManifestReader.timeline(contentsOf: layout.manifest)
                expect.equal(timeline.segments(track: .mic).count, 3, "1 s segments over 2.5 s of audio")
                expect.close(timeline.duration(track: .mic), 2.5, tolerance: 0.01)
                for segment in timeline.segments(track: .mic) where segment.isClosed {
                    let url = layout.segments.appendingPathComponent(segment.file)
                    let info = try AudioFileInspector().inspect(url: url)
                    expect.equal(info.frameCount, segment.frameCount ?? -1, "manifest disagrees with \(segment.file)")
                }
            },

            test("a mid-recording format change opens a new segment and is recorded") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let layout = MeetingLayout(root: root)
                try FileManager.default.createDirectory(at: layout.segments, withIntermediateDirectories: true)
                let manifest = try ManifestWriter(url: layout.manifest)
                let wideband = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
                let narrowband = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
                let writer = SegmentWriter(
                    track: .mic, layout: layout, manifest: manifest, format: wideband, segmentSeconds: 60
                )

                writer.enqueueSynchronously(AudioBufferPacket(
                    buffer: makeTone(seconds: 2, sampleRate: 48_000), hostTime: 0
                ))
                // Bluetooth switches to the hands-free profile.
                writer.changeFormat(narrowband, reason: "config_change")
                writer.enqueueSynchronously(AudioBufferPacket(
                    buffer: makeTone(seconds: 3, sampleRate: 16_000), hostTime: 2
                ))
                writer.finish(reason: "test")
                manifest.close()

                let timeline = try ManifestReader.timeline(contentsOf: layout.manifest)
                expect.equal(timeline.segments(track: .mic).count, 2)
                expect.equal(timeline.formatChanges.count, 1)
                expect.equal(timeline.formatChanges[0].to.sampleRate, 16_000)
                expect.close(timeline.duration(track: .mic), 5.0, tolerance: 0.01)
                // The naive formula would report 2 + 3*16000/48000 = 3 s.
                let totalFrames = timeline.segments(track: .mic).reduce(Int64(0)) { $0 + ($1.frameCount ?? 0) }
                expect.close(Double(totalFrames) / 48_000, 3.0, tolerance: 0.01)
            },

            test("the pre-roll ring stays bounded and keeps the newest audio") { expect in
                let ring = PreRollBuffer(capacitySeconds: 2)
                for index in 0..<40 {
                    ring.append(AudioBufferPacket(
                        buffer: makeTone(seconds: 0.1, sampleRate: 48_000), hostTime: Double(index) * 0.1
                    ))
                }
                expect.isTrue(ring.bufferedSeconds <= 2.05, "buffered \(ring.bufferedSeconds)s")
                expect.isTrue(ring.bufferedSeconds >= 1.9)
                let drained = ring.drain()
                expect.close(drained.last?.hostTime ?? 0, 3.9, tolerance: 0.001)
                expect.equal(ring.bufferedSeconds, 0)
                expect.equal(ring.drain().count, 0)
            },

            test("a track reads back across a sample-rate change at the right length") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let layout = MeetingLayout(root: root)
                try FileManager.default.createDirectory(at: layout.segments, withIntermediateDirectories: true)
                let manifest = try ManifestWriter(url: layout.manifest)
                let writer = SegmentWriter(
                    track: .mic, layout: layout, manifest: manifest,
                    format: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!,
                    segmentSeconds: 60
                )
                writer.enqueueSynchronously(AudioBufferPacket(
                    buffer: makeTone(seconds: 2, sampleRate: 48_000), hostTime: 0
                ))
                writer.changeFormat(
                    AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!, reason: "bluetooth"
                )
                writer.enqueueSynchronously(AudioBufferPacket(
                    buffer: makeTone(seconds: 2, sampleRate: 16_000), hostTime: 2
                ))
                writer.finish(reason: "test")
                manifest.close()

                let timeline = try ManifestReader.timeline(contentsOf: layout.manifest)
                let stream = TrackAudioStream(
                    segments: timeline.segments(track: .mic),
                    segmentsDirectory: layout.segments,
                    targetFormat: AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
                )
                var frames: Int64 = 0
                try stream.forEachBuffer { buffer, _ in
                    frames += Int64(buffer.frameLength)
                    return true
                }
                expect.close(Double(frames) / 16_000, 4.0, tolerance: 0.15, "read back the whole track")
            },

            test("an aggregate device's own stream is not mistaken for the tap") { expect in
                // Measured on this machine: a stereo process tap arrives as
                // [8ch/16384B, 2ch/4096B], the output device's stream first and
                // the tap's second, both carrying 512 frames. Reading the first
                // stream's bytes as frames recorded eight seconds of audio for
                // every second of the meeting.
                let frames = 512
                let deviceChannels = 8
                let tapChannels = 2
                let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
                var deviceSamples = [Float](repeating: 0.9, count: frames * deviceChannels)
                var tapSamples = [Float](repeating: 0.25, count: frames * tapChannels)

                let result: AVAudioPCMBuffer? = deviceSamples.withUnsafeMutableBufferPointer { device in
                    tapSamples.withUnsafeMutableBufferPointer { tap in
                        let storage = AudioBufferList.allocate(maximumBuffers: 2)
                        defer { free(storage.unsafeMutablePointer) }
                        storage[0] = AudioBuffer(
                            mNumberChannels: UInt32(deviceChannels),
                            mDataByteSize: UInt32(frames * deviceChannels * MemoryLayout<Float>.size),
                            mData: UnsafeMutableRawPointer(device.baseAddress)
                        )
                        storage[1] = AudioBuffer(
                            mNumberChannels: UInt32(tapChannels),
                            mDataByteSize: UInt32(frames * tapChannels * MemoryLayout<Float>.size),
                            mData: UnsafeMutableRawPointer(tap.baseAddress)
                        )
                        return makeBuffer(from: storage.unsafePointer, format: format)
                    }
                }
                guard let buffer = result else { return expect.fail("no buffer produced") }
                expect.equal(
                    Int(buffer.frameLength), frames,
                    "the frame count comes from the stream's own channels"
                )
                expect.close(
                    Double(buffer.floatChannelData![0][0]), 0.25, tolerance: 0.001,
                    "the audio comes from the tap's stream, not the device's"
                )
            },

            test("a single interleaved stream keeps its frame count") { expect in
                let frames = 256
                let channels = 2
                let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
                var samples = [Float](repeating: 0.5, count: frames * channels)
                let result: AVAudioPCMBuffer? = samples.withUnsafeMutableBufferPointer { pointer in
                    var list = AudioBufferList(
                        mNumberBuffers: 1,
                        mBuffers: AudioBuffer(
                            mNumberChannels: UInt32(channels),
                            mDataByteSize: UInt32(frames * channels * MemoryLayout<Float>.size),
                            mData: UnsafeMutableRawPointer(pointer.baseAddress)
                        )
                    )
                    return withUnsafePointer(to: &list) { makeBuffer(from: $0, format: format) }
                }
                expect.equal(Int(result?.frameLength ?? 0), frames)
            },

            test("a three-channel microphone is still audible when it is read back") { expect in
                // The built-in microphone on this machine reports three channels.
                // A file with that many channels and no surround layout has no
                // mixdown matrix, and a converter left to itself returns silence,
                // so the recording exists at full duration and contains nothing.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let layout = MeetingLayout(root: root)
                try FileManager.default.createDirectory(at: layout.segments, withIntermediateDirectories: true)
                let manifest = try ManifestWriter(url: layout.manifest)
                let tone = makeDiscreteTone(seconds: 2, sampleRate: 48_000, channels: 3)
                let writer = SegmentWriter(
                    track: .mic, layout: layout, manifest: manifest,
                    format: tone.format, segmentSeconds: 60
                )
                writer.enqueueSynchronously(AudioBufferPacket(buffer: tone, hostTime: 0))
                writer.finish(reason: "test")
                manifest.close()

                let timeline = try ManifestReader.timeline(contentsOf: layout.manifest)
                expect.equal(timeline.segments(track: .mic).first?.format.channelCount, 3)

                let stream = TrackAudioStream(
                    segments: timeline.segments(track: .mic),
                    segmentsDirectory: layout.segments,
                    targetFormat: AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
                )
                var peak: Float = 0
                var frames: Int64 = 0
                try stream.forEachBuffer { buffer, _ in
                    frames += Int64(buffer.frameLength)
                    if let data = buffer.floatChannelData {
                        for frame in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[0][frame])) }
                    }
                    return true
                }
                expect.close(Double(frames) / 16_000, 2.0, tolerance: 0.15, "the whole track reads back")
                expect.isTrue(peak > 0.2, "the audio read back silent: peak \(peak)")
            },

            test("a chunk exports to an m4a small enough for the request limit") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let layout = MeetingLayout(root: root)
                try FileManager.default.createDirectory(at: layout.segments, withIntermediateDirectories: true)
                let manifest = try ManifestWriter(url: layout.manifest)
                let writer = SegmentWriter(
                    track: .mic, layout: layout, manifest: manifest,
                    format: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!,
                    segmentSeconds: 5
                )
                for index in 0..<6 {
                    writer.enqueueSynchronously(AudioBufferPacket(
                        buffer: makeTone(seconds: 2, sampleRate: 48_000), hostTime: Double(index) * 2
                    ))
                }
                writer.finish(reason: "test")
                manifest.close()

                let timeline = try ManifestReader.timeline(contentsOf: layout.manifest)
                let destination = root.appendingPathComponent("chunk_001.m4a")
                let exporter = ChunkExporter()
                let written = try exporter.export(
                    plan: ChunkPlan(index: 1, start: 2, end: 8, overlapEnd: 0),
                    segments: timeline.segments(track: .mic),
                    segmentsDirectory: layout.segments,
                    to: destination
                )
                expect.isTrue(written > 0, "nothing was written")
                let info = try AudioFileInspector().inspect(url: destination)
                expect.close(info.seconds, 6.0, tolerance: 0.35, "exported the requested span")

                // 20 minutes at this bit rate has to stay well under 25 MiB.
                let bytesPerSecond = Double(info.byteCount) / max(info.seconds, 0.001)
                expect.isTrue(
                    bytesPerSecond * 1_200 < 25 * 1_024 * 1_024,
                    "a 20-minute chunk would be \(Int(bytesPerSecond * 1_200 / 1_048_576)) MiB"
                )
            },

            test("mixing aligns the two tracks by their first-frame host times") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let layout = MeetingLayout(root: root)
                try FileManager.default.createDirectory(at: layout.segments, withIntermediateDirectories: true)
                let manifest = try ManifestWriter(url: layout.manifest)
                let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

                let remoteWriter = SegmentWriter(
                    track: .remote, layout: layout, manifest: manifest, format: format, segmentSeconds: 60
                )
                remoteWriter.enqueueSynchronously(AudioBufferPacket(
                    buffer: makeTone(seconds: 4, sampleRate: 48_000, frequency: 220), hostTime: 100.0
                ))
                remoteWriter.finish(reason: "test")

                // The microphone starts a second later, exactly as it does in a real
                // session where the tap comes up first.
                let micWriter = SegmentWriter(
                    track: .mic, layout: layout, manifest: manifest, format: format, segmentSeconds: 60
                )
                micWriter.enqueueSynchronously(AudioBufferPacket(
                    buffer: makeTone(seconds: 3, sampleRate: 48_000, frequency: 440), hostTime: 101.0
                ))
                micWriter.finish(reason: "test")
                manifest.close()

                let timeline = try ManifestReader.timeline(contentsOf: layout.manifest)
                try AudioMixer().mix(
                    mic: TrackAudioLocation(
                        segments: timeline.segments(track: .mic), directory: layout.segments
                    ),
                    remote: TrackAudioLocation(
                        segments: timeline.segments(track: .remote), directory: layout.segments
                    ),
                    to: layout.recordingAudio
                )
                let info = try AudioFileInspector().inspect(url: layout.recordingAudio)
                // Remote runs 0–4 s, mic is delayed to 1–4 s, so the mix is 4 s long.
                expect.close(info.seconds, 4.0, tolerance: 0.1)

                // The final name appears only once the mix is complete. It is
                // written incrementally, and the caller skips the mix when that
                // path already exists, so a quit part way through used to leave a
                // short but perfectly valid file that nothing would ever rebuild.
                let partial = layout.recordingAudio.deletingPathExtension()
                    .appendingPathExtension("partial")
                    .appendingPathExtension(layout.recordingAudio.pathExtension)
                expect.isFalse(
                    FileManager.default.fileExists(atPath: partial.path),
                    "and the partial it was built under is gone"
                )
            },

            test("a mix that cannot finish leaves no file to be mistaken for one") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let layout = MeetingLayout(root: root)
                try FileManager.default.createDirectory(
                    at: layout.segments, withIntermediateDirectories: true
                )
                let manifest = try ManifestWriter(url: layout.manifest)
                let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
                let writer = SegmentWriter(
                    track: .remote, layout: layout, manifest: manifest,
                    format: format, segmentSeconds: 60
                )
                writer.enqueueSynchronously(AudioBufferPacket(
                    buffer: makeTone(seconds: 4, sampleRate: 48_000, frequency: 220),
                    hostTime: 100.0
                ))
                writer.finish(reason: "test")
                manifest.close()
                let timeline = try ManifestReader.timeline(contentsOf: layout.manifest)

                // The manifest still names the segment; the audio is gone, which
                // is what a half-written archive looks like after a SIGKILL.
                for file in try FileManager.default.contentsOfDirectory(
                    at: layout.segments, includingPropertiesForKeys: nil
                ) {
                    try FileManager.default.removeItem(at: file)
                }
                try? AudioMixer().mix(
                    mic: TrackAudioLocation(
                        segments: timeline.segments(track: .mic), directory: layout.segments
                    ),
                    remote: TrackAudioLocation(
                        segments: timeline.segments(track: .remote), directory: layout.segments
                    ),
                    to: layout.recordingAudio
                )
                expect.isFalse(
                    FileManager.default.fileExists(atPath: layout.recordingAudio.path),
                    "nothing at the final path, rather than an empty file that reads as done"
                )
            },

            test("importing preserves the original and produces normal segments") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let sourceURL = root.appendingPathComponent("voice-memo.caf")
                let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
                let sourceFile = try AVAudioFile(
                    forWriting: sourceURL,
                    settings: [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVSampleRateKey: 44_100,
                        AVNumberOfChannelsKey: 2,
                        AVLinearPCMBitDepthKey: 32,
                        AVLinearPCMIsFloatKey: true,
                        AVLinearPCMIsNonInterleaved: false,
                    ]
                )
                _ = sourceFormat
                try sourceFile.write(from: makeTone(seconds: 6, sampleRate: 44_100, channels: 2))
                let originalBytes = try Data(contentsOf: sourceURL)

                let archive = root.appendingPathComponent("archive", isDirectory: true)
                let repository = MeetingRepository(root: archive)
                let now = Date(timeIntervalSince1970: 1_787_070_000)
                let created = try repository.createMeeting(
                    source: .imported, provider: .unknown, startedAt: now, now: now
                )
                let result = try AudioImporter(segmentSeconds: 2).import(
                    source: sourceURL, into: created.store, meetingID: created.metadata.id
                )

                expect.close(result.durationSeconds, 6.0, tolerance: 0.1)
                expect.equal(result.segmentCount, 3)
                expect.equal(result.originalFilename, "voice-memo.caf")

                let preserved = created.store.layout.originals.appendingPathComponent("voice-memo.caf")
                expect.equal(try Data(contentsOf: preserved), originalBytes, "the original was modified")

                let timeline = try created.store.readTimeline()
                expect.close(timeline.duration(track: .mic), 6.0, tolerance: 0.1)
                expect.isTrue(timeline.isComplete)
            },
        ])
    }
}
