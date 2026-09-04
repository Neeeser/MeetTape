import AVFoundation
import Foundation
import PipitAudio
import PipitCore
import TestKit

/// Real audio through the real writers and readers. These use AVFoundation but no
/// audio hardware, so they run anywhere.
enum AudioTests {
    /// A deinterleaved tone, which is the shape a process tap delivers. Its
    /// format is always `standardFormatWithSampleRate:channels:`, so every
    /// channel has its own pointer.
    ///
    /// `toneChannel` puts the tone on one channel and leaves the others at
    /// zero, which is what a far end talking on one side of a stereo mixdown
    /// sounds like.
    static func makeTone(
        seconds: Double, sampleRate: Double, channels: AVAudioChannelCount = 1,
        frequency: Double = 440, amplitude: Float = 0.5, toneChannel: Int? = nil
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData!
        for frame in 0..<Int(frames) {
            let value = amplitude * Float(sin(2 * Double.pi * frequency * Double(frame) / sampleRate))
            for channel in 0..<Int(channels) {
                data[channel][frame] = toneChannel == nil || toneChannel == channel ? value : 0
            }
        }
        return buffer
    }

    /// A buffer in the shape a multi-channel built-in microphone delivers: more
    /// than two channels, discrete, with no surround layout to mix down from.
    ///
    /// `toneChannel` puts the tone on one channel and leaves the rest at zero,
    /// which is the shape that made channel 0 the wrong channel to keep.
    static func makeDiscreteTone(
        seconds: Double, sampleRate: Double, channels: UInt32,
        frequency: Double = 440, amplitude: Float = 0.5, toneChannel: Int? = nil
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
            for channel in 0..<Int(channels) {
                data[channel][frame] = toneChannel == nil || toneChannel == channel ? value : 0
            }
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

    /// A tone in a flat run of samples, which is the shape the echo canceller
    /// takes. `from` leaves everything before it silent.
    static func makeToneSamples(
        count: Int, sampleRate: Double, frequency: Double, amplitude: Float, from: Int = 0
    ) -> [Float] {
        var samples = [Float](repeating: 0, count: count)
        for index in from..<count {
            let phase = 2 * Double.pi * frequency * Double(index) / sampleRate
            samples[index] = amplitude * Float(sin(phase))
        }
        return samples
    }

    /// Energy summed across the whole band.
    ///
    /// Use this where the microphone holds no copy of the far end. There is
    /// nothing to subtract, so the difference between input and output is
    /// what the canceller took out of the user.
    static func energy(_ samples: [Float]) -> Double {
        samples.reduce(0.0) { $0 + Double($1) * Double($1) }
    }

    /// Energy at one frequency, by the Goertzel recurrence.
    ///
    /// One narrow band rather than the whole spectrum. Where the microphone
    /// does hold a copy of the far end, broadband energy after cancellation is
    /// mostly residue from subtracting it, so it says nothing about whether
    /// the user's own voice came through.
    static func toneEnergy(_ samples: [Float], frequency: Double, sampleRate: Double) -> Double {
        let coefficient = 2 * cos(2 * Double.pi * frequency / sampleRate)
        var previous = 0.0
        var older = 0.0
        for sample in samples {
            let current = Double(sample) + coefficient * previous - older
            older = previous
            previous = current
        }
        return previous * previous + older * older - coefficient * previous * older
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

            test("a microphone holding nothing but the far end loses more than 20 dB") { expect in
                // A call taken on speakers. The far end left the speakers,
                // crossed the room and arrived back at the capsule a few
                // milliseconds later and quieter. Nothing downstream can unmix
                // that, because the mixing happened in the air.
                //
                // The reference is the recording of the far end, which is what
                // Apple's own unit never had here: it subtracts what its host
                // plays, and Pipit plays nothing.
                let canceller = try expect.unwrap(EchoCanceller(sampleRate: 16_000))
                let block = canceller.blockFrames
                let blocks = 400
                let delay = 48  // 3 ms across the desk
                var far = [Float](repeating: 0, count: block * blocks)
                for index in far.indices {
                    let phase: Double = 2.0 * Double.pi * 440.0 * Double(index) / 16_000.0
                    far[index] = Float(0.5 * sin(phase))
                }
                // The user says nothing at all, so everything in the microphone
                // is the far end coming back.
                var heard = [Float](repeating: 0, count: far.count)
                for index in delay..<heard.count { heard[index] = far[index - delay] * 0.35 }

                var before: Double = 0
                var after: Double = 0
                for index in 0..<blocks {
                    let range = (index * block)..<((index + 1) * block)
                    var microphone = Array(heard[range])
                    let reference = Array(far[range])
                    expect.isTrue(canceller.process(microphone: &microphone, reference: reference))
                    // The filter needs to hear the room before it can subtract
                    // it, so the score is the second half.
                    guard index >= blocks / 2 else { continue }
                    for sample in heard[range] { before += Double(sample) * Double(sample) }
                    for sample in microphone { after += Double(sample) * Double(sample) }
                }
                let removedDB = 10 * log10((before + 1e-12) / (after + 1e-12))
                expect.isTrue(
                    removedDB > 20,
                    "the far end should be gone, removed \(Int(removedDB)) dB"
                )
            },

            test("a rate the library cannot take is refused at the door") { expect in
                // The library reports an unsupported format on every block
                // below 8 kHz, so a canceller built at such a rate would take
                // audio and fail on all of it. Task 3 hands it rates read from
                // recorded files.
                expect.isNil(EchoCanceller(sampleRate: 4_000))
                expect.isNil(EchoCanceller(sampleRate: 0))
                // 8 kHz is the lowest rate the library supports, so it is the
                // rate a one-off in the guard would refuse.
                expect.isTrue(EchoCanceller(sampleRate: 8_000) != nil)
                expect.isTrue(EchoCanceller(sampleRate: 16_000) != nil)
            },

            test("the user's own voice survives while the far end is cancelled") { expect in
                // The user speaks over the far end. Every earlier attempt at
                // this problem cut whole words out of the user, so the number
                // held here is how much of the user's own voice is still there
                // once the far end has been subtracted.
                let canceller = try expect.unwrap(EchoCanceller(sampleRate: 16_000))
                let block = canceller.blockFrames
                // The canceller spends its first 2.5 s in a starting state
                // where it reports nothing, so 8 s of audio leaves it time to
                // settle and then time to be measured.
                let blocks = 800
                let rate = 16_000.0
                let total = block * blocks
                let delay = 48  // 3 ms across the desk
                let far = makeToneSamples(
                    count: total, sampleRate: rate, frequency: 440, amplitude: 0.5
                )
                // The user starts talking halfway through, which leaves the
                // first half for the canceller to learn the room and the second
                // to show it subtracts the far end and nothing else.
                let near = makeToneSamples(
                    count: total, sampleRate: rate, frequency: 1300, amplitude: 0.3,
                    from: total / 2
                )
                var heard = near
                for index in delay..<total { heard[index] += far[index - delay] * 0.35 }

                var cleaned = [Float](repeating: 0, count: total)
                for index in 0..<blocks {
                    let range = (index * block)..<((index + 1) * block)
                    var microphone = Array(heard[range])
                    expect.isTrue(
                        canceller.process(microphone: &microphone, reference: Array(far[range]))
                    )
                    cleaned.replaceSubrange(range, with: microphone)
                }

                let talking = (total / 2)..<total
                let kept = toneEnergy(Array(cleaned[talking]), frequency: 1300, sampleRate: rate)
                let spoken = toneEnergy(Array(near[talking]), frequency: 1300, sampleRate: rate)
                let lossDB = 10 * log10((spoken + 1e-12) / (kept + 1e-12))
                expect.isTrue(
                    lossDB < 3,
                    "the user lost \(lossDB) dB of their own voice"
                )
                expect.isTrue(
                    canceller.echoRemovedDB > 10,
                    "an echo path is present and the canceller reports removing "
                        + "\(canceller.echoRemovedDB) dB"
                )
            },

            test("a reference with no echo path is reported as nothing removed") { expect in
                // A meeting taken on headphones. The far end never reaches the
                // microphone, so there is nothing to subtract.
                //
                // Bypassing this case is not optional, and both numbers below
                // are what the bypass rests on. With no echo to lock onto, the
                // canceller estimates the residual from render power and an
                // assumed path gain, knowing nothing about whether the
                // microphone holds any of it, and tears the user's own voice
                // apart.
                //
                // The low reading below is not a measure of that damage. It
                // comes from the linear filter, and the suppressor that does
                // the damage runs after it. A low reading says the filter never
                // locked on to an echo path, and that is the reason to discard
                // the output.
                let canceller = try expect.unwrap(EchoCanceller(sampleRate: 16_000))
                let block = canceller.blockFrames
                let blocks = 800
                let rate = 16_000.0
                let total = block * blocks
                let far = makeToneSamples(
                    count: total, sampleRate: rate, frequency: 440, amplitude: 0.5
                )
                let heard = makeToneSamples(
                    count: total, sampleRate: rate, frequency: 700, amplitude: 0.3
                )

                var cleaned = [Float](repeating: 0, count: total)
                for index in 0..<blocks {
                    let range = (index * block)..<((index + 1) * block)
                    var microphone = Array(heard[range])
                    expect.isTrue(
                        canceller.process(microphone: &microphone, reference: Array(far[range]))
                    )
                    cleaned.replaceSubrange(range, with: microphone)
                }

                let second = (total / 2)..<total
                let damageDB = 10 * log10(
                    (energy(Array(heard[second])) + 1e-12)
                        / (energy(Array(cleaned[second])) + 1e-12)
                )
                expect.isTrue(
                    damageDB > 20,
                    "a microphone with no echo in it came through only \(damageDB) dB down, "
                        + "so the canceller is gentler on clean audio than the bypass assumes"
                )
                expect.isTrue(
                    canceller.echoRemovedDB < 3,
                    "no echo path is present and the canceller reports removing "
                        + "\(canceller.echoRemovedDB) dB"
                )
            },

            test("audio lost to an engine rebuild is written as silence") { expect in
                // Measured across 34 recordings on disk: 3750 rotation
                // boundaries lose a median of 11 microseconds, and the only
                // real losses are 9 engine rebuilds costing 1.01 to 3.47 s,
                // every one of them the microphone changing format underneath
                // capture.
                //
                // The frames are gone either way. What matters is that the file
                // still says how long the silence was, because everything above
                // reads a track's audio as one contiguous run: without this the
                // microphone ran 0.74 s ahead of the far end for a whole
                // meeting, and every time downstream was measured against it.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let layout = MeetingLayout(root: root)
                try FileManager.default.createDirectory(
                    at: layout.segments, withIntermediateDirectories: true
                )
                let manifest = try ManifestWriter(url: layout.manifest)
                let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
                let writer = SegmentWriter(
                    track: .mic, layout: layout, manifest: manifest,
                    format: format, segmentSeconds: 60
                )

                writer.enqueueSynchronously(AudioBufferPacket(
                    buffer: makeTone(seconds: 0.5, sampleRate: 48_000), hostTime: 100
                ))
                // The engine tears down and rebuilds. Nothing arrives for
                // 1.13 s, then capture resumes.
                writer.enqueueSynchronously(AudioBufferPacket(
                    buffer: makeTone(seconds: 0.5, sampleRate: 48_000), hostTime: 101.6317
                ))
                writer.finish(reason: "test")
                manifest.close()

                let timeline = try ManifestReader.timeline(contentsOf: layout.manifest)
                expect.close(
                    timeline.duration(track: .mic), 2.1317, tolerance: 0.01,
                    "1 s of audio plus the 1.1317 s nobody recorded"
                )
                expect.isTrue(
                    timeline.isContiguous(track: .mic),
                    "and the track now reads as the unbroken run it claims to be"
                )
            },

            test("an ordinary rotation writes no silence") { expect in
                // The fill has to stay off the path it does not belong on.
                // A rotation boundary costs microseconds, and padding those
                // would stretch every meeting a little.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let layout = MeetingLayout(root: root)
                try FileManager.default.createDirectory(
                    at: layout.segments, withIntermediateDirectories: true
                )
                let manifest = try ManifestWriter(url: layout.manifest)
                let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
                let writer = SegmentWriter(
                    track: .mic, layout: layout, manifest: manifest,
                    format: format, segmentSeconds: 1
                )
                for index in 0..<5 {
                    writer.enqueueSynchronously(AudioBufferPacket(
                        buffer: makeTone(seconds: 0.5, sampleRate: 48_000),
                        // A hair late every time, as a real clock is.
                        hostTime: Double(index) * 0.5 + Double(index) * 0.000_02
                    ))
                }
                writer.finish(reason: "test")
                manifest.close()

                let timeline = try ManifestReader.timeline(contentsOf: layout.manifest)
                expect.close(timeline.duration(track: .mic), 2.5, tolerance: 0.001)
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
                        return makeBuffer(
                            from: storage.unsafePointer, format: format, tapStreamIndex: nil
                        ).buffer
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

            test("tap stream is selected by index, not by channel count") { expect in
                // Jump Desktop Audio and a stereo USB interface both publish a
                // two-channel input stream ahead of the tap. Matching on channel
                // count reads that device's silence and the far side of the call
                // is lost, so the tap is taken from the index the aggregate's
                // input stream count gives.
                let frames = 512
                let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
                var silent = [Float](repeating: 0, count: frames * 2)
                var tone = [Float](repeating: 0, count: frames * 2)
                for frame in 0..<frames {
                    let sample = Float(sin(2 * Double.pi * 1_000 * Double(frame) / 48_000))
                    tone[frame * 2] = sample
                    tone[frame * 2 + 1] = sample
                }

                let result: AVAudioPCMBuffer? = silent.withUnsafeMutableBufferPointer { first in
                    tone.withUnsafeMutableBufferPointer { second in
                        let storage = AudioBufferList.allocate(maximumBuffers: 2)
                        defer { free(storage.unsafeMutablePointer) }
                        storage[0] = AudioBuffer(
                            mNumberChannels: 2,
                            mDataByteSize: UInt32(frames * 2 * MemoryLayout<Float>.size),
                            mData: UnsafeMutableRawPointer(first.baseAddress)
                        )
                        storage[1] = AudioBuffer(
                            mNumberChannels: 2,
                            mDataByteSize: UInt32(frames * 2 * MemoryLayout<Float>.size),
                            mData: UnsafeMutableRawPointer(second.baseAddress)
                        )
                        return makeBuffer(
                            from: storage.unsafePointer, format: format, tapStreamIndex: 1
                        ).buffer
                    }
                }
                guard let buffer = result else { return expect.fail("no buffer produced") }
                let samples = buffer.floatChannelData![0]
                var peak: Float = 0
                for frame in 0..<Int(buffer.frameLength) { peak = max(peak, abs(samples[frame])) }
                expect.isTrue(
                    peak > 0.5,
                    "the tap's stream carries the tone, and the first stereo stream is silent"
                )
            },

            test("an out-of-range tap index falls back to channel-count matching") { expect in
                // A list that does not line up with the reported stream count
                // still has to produce audio, so the old match stays as a
                // fallback and the caller logs that it was used.
                let frames = 256
                let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
                var first = [Float](repeating: 0.4, count: frames * 2)
                var second = [Float](repeating: 0.9, count: frames * 2)

                let selection: TapStreamSelection = first.withUnsafeMutableBufferPointer { one in
                    second.withUnsafeMutableBufferPointer { two in
                        let storage = AudioBufferList.allocate(maximumBuffers: 2)
                        defer { free(storage.unsafeMutablePointer) }
                        storage[0] = AudioBuffer(
                            mNumberChannels: 2,
                            mDataByteSize: UInt32(frames * 2 * MemoryLayout<Float>.size),
                            mData: UnsafeMutableRawPointer(one.baseAddress)
                        )
                        storage[1] = AudioBuffer(
                            mNumberChannels: 2,
                            mDataByteSize: UInt32(frames * 2 * MemoryLayout<Float>.size),
                            mData: UnsafeMutableRawPointer(two.baseAddress)
                        )
                        return makeBuffer(
                            from: storage.unsafePointer, format: format, tapStreamIndex: 7
                        )
                    }
                }
                guard let buffer = selection.buffer else { return expect.fail("no buffer produced") }
                expect.close(
                    Double(buffer.floatChannelData![0][0]), 0.4, tolerance: 0.001,
                    "the first stream matching the tap's channel count is read"
                )
                expect.isTrue(selection.usedFallback, "the fallback is reported to the caller")
            },

            test("a non-interleaved list is not reported as the fallback") { expect in
                // One buffer per channel is what a non-interleaved source
                // delivers, and the tap index counts streams, so it never
                // addresses those buffers. Reporting the miss made a device
                // where nothing is wrong log that the index was unusable on
                // every bind.
                let frames = 128
                let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
                var left = [Float](repeating: 0.3, count: frames)
                var right = [Float](repeating: 0.6, count: frames)

                let selection: TapStreamSelection = left.withUnsafeMutableBufferPointer { one in
                    right.withUnsafeMutableBufferPointer { two in
                        let storage = AudioBufferList.allocate(maximumBuffers: 2)
                        defer { free(storage.unsafeMutablePointer) }
                        storage[0] = AudioBuffer(
                            mNumberChannels: 1,
                            mDataByteSize: UInt32(frames * MemoryLayout<Float>.size),
                            mData: UnsafeMutableRawPointer(one.baseAddress)
                        )
                        storage[1] = AudioBuffer(
                            mNumberChannels: 1,
                            mDataByteSize: UInt32(frames * MemoryLayout<Float>.size),
                            mData: UnsafeMutableRawPointer(two.baseAddress)
                        )
                        return makeBuffer(
                            from: storage.unsafePointer, format: format, tapStreamIndex: 1
                        )
                    }
                }
                guard let buffer = selection.buffer else { return expect.fail("no buffer produced") }
                expect.close(Double(buffer.floatChannelData![1][0]), 0.6, tolerance: 0.001)
                expect.isFalse(
                    selection.usedFallback,
                    "an index that cannot address per-channel buffers is not a fallback"
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
                    return withUnsafePointer(to: &list) {
                        makeBuffer(from: $0, format: format, tapStreamIndex: nil).buffer
                    }
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

            test("the loudest channel is the one read back, not channel 0") { expect in
                // The raw built-in microphone presents three channels and the
                // voice is not always on the first. On 2026-09-02 and
                // 2026-09-03 channel 0 of a three-channel track came out around
                // -47.8 dBFS at p99 against the usual -17 to -18 dBFS, about
                // 30 dB down, and that meeting transcribed badly end to end.
                for (channels, toneChannel) in [(UInt32(3), 2), (UInt32(9), 4)] {
                    let root = try ManifestTests.makeTemporaryDirectory()
                    defer { try? FileManager.default.removeItem(at: root) }
                    let layout = MeetingLayout(root: root)
                    try FileManager.default.createDirectory(
                        at: layout.segments, withIntermediateDirectories: true
                    )
                    let manifest = try ManifestWriter(url: layout.manifest)
                    // -6 dBFS on one channel, digital silence on the rest.
                    let tone = makeDiscreteTone(
                        seconds: 3, sampleRate: 48_000, channels: channels,
                        amplitude: 0.5, toneChannel: toneChannel
                    )
                    let writer = SegmentWriter(
                        track: .mic, layout: layout, manifest: manifest,
                        format: tone.format, segmentSeconds: 60
                    )
                    writer.enqueueSynchronously(AudioBufferPacket(buffer: tone, hostTime: 0))
                    writer.finish(reason: "test")
                    manifest.close()

                    let timeline = try ManifestReader.timeline(contentsOf: layout.manifest)
                    expect.equal(
                        timeline.segments(track: .mic).first?.format.channelCount, Int(channels)
                    )

                    let stream = TrackAudioStream(
                        segments: timeline.segments(track: .mic),
                        segmentsDirectory: layout.segments,
                        targetFormat: AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
                    )
                    var sumOfSquares: Double = 0
                    var frames = 0
                    try stream.forEachBuffer { buffer, _ in
                        guard let data = buffer.floatChannelData else { return true }
                        for frame in 0..<Int(buffer.frameLength) {
                            sumOfSquares += Double(data[0][frame] * data[0][frame])
                        }
                        frames += Int(buffer.frameLength)
                        return true
                    }
                    let rms = frames > 0 ? (sumOfSquares / Double(frames)).squareRoot() : 0
                    let dBFS = 20 * log10(max(rms, 1e-9))
                    expect.isTrue(
                        dBFS > -12,
                        "channel \(toneChannel) of \(channels) read back at \(Int(dBFS)) dBFS"
                    )
                }
            },

            test("a group that opens with 30 s of silence keeps channel 0") { expect in
                // The scan measures the group's first file only, and a file of
                // digital silence is a tie, which answers channel 0. So a
                // meeting whose first half minute is silent on every channel
                // reads back silent even though a later segment has audio.
                // Pinned rather than fixed: reaching past the first file means
                // opening segments the reader has not got to yet.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let layout = MeetingLayout(root: root)
                try FileManager.default.createDirectory(
                    at: layout.segments, withIntermediateDirectories: true
                )
                let manifest = try ManifestWriter(url: layout.manifest)
                let silence = makeDiscreteTone(
                    seconds: 31, sampleRate: 16_000, channels: 3, amplitude: 0
                )
                let tone = makeDiscreteTone(
                    seconds: 3, sampleRate: 16_000, channels: 3, amplitude: 0.5, toneChannel: 2
                )
                let writer = SegmentWriter(
                    track: .mic, layout: layout, manifest: manifest,
                    format: silence.format, segmentSeconds: 30
                )
                writer.enqueueSynchronously(AudioBufferPacket(buffer: silence, hostTime: 0))
                writer.enqueueSynchronously(AudioBufferPacket(buffer: tone, hostTime: 31))
                writer.finish(reason: "test")
                manifest.close()

                let timeline = try ManifestReader.timeline(contentsOf: layout.manifest)
                expect.equal(timeline.segments(track: .mic).count, 2, "the group has two segments")

                let stream = TrackAudioStream(
                    segments: timeline.segments(track: .mic),
                    segmentsDirectory: layout.segments,
                    targetFormat: AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
                )
                var peak: Float = 0
                try stream.forEachBuffer { buffer, _ in
                    guard let data = buffer.floatChannelData else { return true }
                    for frame in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[0][frame])) }
                    return true
                }
                expect.equal(peak, 0, "channel 0 is kept, so the later tone is not read back")
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
