import AVFoundation
import Foundation
import PipitAudio
import PipitCore

/// Measures what a meeting's recorded audio holds, so the assembler can tell a
/// sentence the local user said from one a speech model invented for the gaps.
///
/// Reads each track once at 16 kHz mono, the rate every model here works at.
/// The level pass is arithmetic and the detector pass is Silero. A 29-minute
/// meeting measured in under two seconds.
///
/// Everything is put on the meeting timeline before it is stored. The two
/// tracks do not start at the same instant, and the transcript segments this is
/// compared against already carry their track's lead-in, so a profile measured
/// from each track's own zero would put the microphone and the far end a second
/// out of step with each other.
public enum SpeechEvidenceBuilder {
    /// Seconds one level sample covers.
    ///
    /// Measured against the labelled segments at 0.05, 0.1, 0.25 and 0.5
    /// seconds, the gate keeps and drops exactly the same segments at every one
    /// of them. A quarter of a second is the coarsest that showed no change,
    /// and it keeps a 30-minute meeting's evidence near 85 KB.
    public static let levelWindowSeconds = 0.25

    /// The format both passes read at. 16 kHz mono is what the detector
    /// requires and what the chunk exporter already sends.
    static let readFormat = AudioFormatDescriptor(sampleRate: 16_000, channelCount: 1)

    /// - Parameter detector: absent on a machine whose detector is not
    ///   installed. The evidence is still written, and the policy then decides
    ///   on levels alone rather than dropping everything for want of a reading.
    public static func build(
        store: MeetingStore,
        metadata: MeetingMetadata,
        timeline: RecordingTimeline,
        detector: (any VoiceActivityBackend)?
    ) async throws -> SpeechEvidence {
        var levels: [CaptureTrack: [Int8]] = [:]
        var speech: [Int8] = []
        var speechWindowSeconds = 0.0
        var detectorIdentifier: String?

        for track in CaptureTrack.allCases {
            let location = store.trackAudioLocation(
                track: track, metadata: metadata, timeline: timeline
            )
            guard !location.isEmpty else { continue }
            let stream = TrackAudioStream(
                segments: location.segments,
                segmentsDirectory: location.directory,
                format: readFormat
            )
            let leadIn = timeline.leadIn(track: track)
            let profile = try EnergyProfile.compute(
                stream: stream, windowSeconds: levelWindowSeconds
            )
            levels[track] = padded(
                profile.values.map(SpeechEvidence.decibels(rms:)),
                by: leadIn, windowSeconds: levelWindowSeconds,
                filler: Int8(EmptyTranscriptPolicy.silenceFloorDBFS)
            )

            guard track == .mic, let detector else { continue }
            // The detector's own rate or nothing. Handing it audio at another
            // rate would move every reading in time against the levels beside
            // it, which is worse than having no readings at all.
            guard detector.sampleRate == readFormat.sampleRate else {
                Log.processing.notice(
                    "voice detection skipped: detector wants \(detector.sampleRate, format: .fixed(precision: 0)) Hz"
                )
                continue
            }
            // A detector that is not installed yet costs its clause, not the
            // measurement: levels alone still remove most of what a model
            // invents, and the evidence records that nothing judged the audio.
            do {
                let reader = try SampleReader(stream: stream)
                let readings = try await detector.probabilities(reading: { try await reader.next() })
                speechWindowSeconds = readings.windowSeconds
                speech = padded(
                    readings.values.map { Int8(max(0, min(100, ($0 * 100).rounded()))) },
                    by: leadIn, windowSeconds: readings.windowSeconds, filler: 0
                )
                detectorIdentifier = detector.identifier
            } catch is CancellationError {
                // Not a detector that refused, a pass that was stopped. Writing
                // what it had would record a half-measurement as the finished
                // one, and the measure-once rule would then leave the meeting
                // gated on levels alone for good.
                throw CancellationError()
            } catch {
                Log.processing.notice(
                    "voice detection skipped: \(logSafeDescription(error), privacy: .public)"
                )
            }
        }

        return SpeechEvidence(
            levelWindowSeconds: levelWindowSeconds,
            speechWindowSeconds: speechWindowSeconds,
            micLevels: levels[.mic] ?? [],
            remoteLevels: levels[.remote] ?? [],
            micSpeech: speech,
            micEchoReturnLoss: try echoReturnLoss(
                store: store, metadata: metadata, timeline: timeline
            ),
            detector: detectorIdentifier
        )
    }

    /// How much of each window of the microphone the far end's own audio
    /// accounts for.
    ///
    /// Two passes over the pair of tracks. The first looks for the delay the
    /// speakers put between the far end being captured and it arriving back in
    /// the microphone, sampling stretches from across the meeting and keeping
    /// the one whose peak stands clearest. The second fits and subtracts.
    ///
    /// A failure here costs the clause, not the measurement: the rest of the
    /// evidence is still written and the gate decides on levels and the detector
    /// as it did before.
    static func echoReturnLoss(
        store: MeetingStore, metadata: MeetingMetadata, timeline: RecordingTimeline
    ) throws -> [Int16] {
        let locations = CaptureTrack.allCases.reduce(into: [CaptureTrack: TrackAudioLocation]()) {
            $0[$1] = store.trackAudioLocation(track: $1, metadata: metadata, timeline: timeline)
        }
        // One track is a recording with no far end to have leaked, which is
        // every import and every in-person session.
        guard let micLocation = locations[.mic], !micLocation.isEmpty,
              let remoteLocation = locations[.remote], !remoteLocation.isEmpty
        else { return [] }

        let rate = readFormat.sampleRate
        func pair() -> (mic: TimelineTrackReader, remote: TimelineTrackReader)? {
            guard let mic = TimelineTrackReader(
                location: micLocation, format: readFormat,
                offsetSeconds: gridLeadIn(track: .mic, timeline: timeline)
            ), let remote = TimelineTrackReader(
                location: remoteLocation, format: readFormat,
                offsetSeconds: gridLeadIn(track: .remote, timeline: timeline)
            ) else { return nil }
            return (mic, remote)
        }

        do {
            guard let first = pair() else { return [] }
            let delay = try searchDelay(
                mic: first.mic, remote: first.remote,
                durationSeconds: metadata.durationSeconds, rate: rate
            )
            guard let second = pair() else { return [] }
            let profile = try measure(
                mic: second.mic, remote: second.remote, delay: delay.samples, rate: rate
            )
            try Task.checkCancellation()
            Log.processing.notice(
                """
                echo measured: delay \(Double(delay.samples) / rate, format: .fixed(precision: 3)) s, \
                sharpness \(delay.sharpness, format: .fixed(precision: 1)), \
                windows \(profile.count)
                """
            )
            return profile
        } catch is CancellationError {
            // A pass that was stopped, not a pair of tracks that refused. Writing
            // what it had would record a half-measurement as the finished one,
            // and the measure-once rule would leave the meeting judged on it.
            throw CancellationError()
        } catch {
            Log.processing.notice(
                "echo measurement skipped: \(logSafeDescription(error), privacy: .public)"
            )
            return []
        }
    }

    /// Seconds of one stretch handed to the delay search, and how many stretches
    /// are taken. Nine stretches of thirty seconds covers a meeting of any
    /// length for the price of nine transforms.
    private static let delayStretchSeconds = 30.0
    private static let delayStretches = 9

    private static func searchDelay(
        mic: TimelineTrackReader, remote: TimelineTrackReader,
        durationSeconds: Double, rate: Double
    ) throws -> EchoReturnLossProfile.Delay {
        let stretch = Int(delayStretchSeconds * rate)
        let total = max(1, Int(durationSeconds / delayStretchSeconds))
        let step = max(1, total / delayStretches)
        var best = EchoReturnLossProfile.Delay.none
        var index = 0
        while true {
            try Task.checkCancellation()
            let micSamples = try mic.next(count: stretch)
            let remoteSamples = try remote.next(count: stretch)
            if micSamples.isEmpty || remoteSamples.isEmpty { break }
            defer { index += 1 }
            guard index % step == 0 else { continue }
            let found = EchoReturnLossProfile.delay(
                mic: micSamples, remote: remoteSamples,
                maxLag: Int(EchoReturnLossProfile.searchSeconds * rate)
            )
            if found.sharpness > best.sharpness { best = found }
        }
        return best
    }

    /// Measured a few minutes at a time, so a long meeting never holds both
    /// tracks in memory at once.
    ///
    /// Rounded down to a whole number of filter blocks, and each block is
    /// already a whole number of level windows, so a chunk boundary never falls
    /// inside either. A chunk that ended mid-window would drop the remainder and
    /// slide every later window of the series against the levels it is weighted
    /// by.
    private static let chunkSeconds = 300.0

    private static func chunkSamples(rate: Double) -> Int {
        let window = Int(levelWindowSeconds * rate)
        let block = max(1, Int(EchoReturnLossProfile.blockSeconds / levelWindowSeconds)) * window
        return max(block, (Int(chunkSeconds * rate) / block) * block)
    }

    private static func measure(
        mic: TimelineTrackReader, remote: TimelineTrackReader, delay: Int, rate: Double
    ) throws -> [Int16] {
        let chunk = chunkSamples(rate: rate)
        // The far end from before this chunk that the filter reaches back over.
        let lead = EchoReturnLossProfile.filterTaps + max(0, delay)
        // And from after it. A delay found below zero puts the far end's copy
        // ahead of the microphone rather than behind it, and the end of every
        // chunk would otherwise be fitted against silence that has not been read
        // yet. Only a meeting with no acoustic path measures below zero, so this
        // costs nothing on the meetings it matters for and keeps the arithmetic
        // honest on the ones it does not.
        let ahead = max(0, -delay)
        var history = [Float](repeating: 0, count: lead)
        var carried: [Float] = []
        var profile: [Int16] = []
        while true {
            try Task.checkCancellation()
            let micSamples = try mic.next(count: chunk)
            guard !micSamples.isEmpty else { break }
            let wanted = micSamples.count + ahead
            var body = carried
            if body.count < wanted {
                body += try remote.next(count: wanted - body.count)
            }
            // The far end's tap can stop before the microphone does. What it did
            // not record is silence, and silence explains nothing, which leaves
            // those windows reading zero.
            if body.count < wanted {
                body += [Float](repeating: 0, count: wanted - body.count)
            }
            profile += EchoReturnLossProfile.measure(
                mic: micSamples, remote: history + body, delay: delay,
                sampleRate: rate, windowSeconds: levelWindowSeconds, remoteLead: lead
            )
            // What the next chunk needs: the last `lead` samples before its
            // start, and whatever was read past it. Taken from `body` alone
            // wherever that is long enough, so the chunk is not copied again.
            let boundary = body.prefix(micSamples.count)
            history = boundary.count >= lead
                ? Array(boundary.suffix(lead))
                : Array((history + boundary).suffix(lead))
            carried = Array(body.dropFirst(micSamples.count))
            if micSamples.count < chunk { break }
        }
        return profile
    }

    /// A track's lead-in, rounded to a whole number of level windows.
    ///
    /// `padded` rounds the level series the same way and the gate reads the two
    /// side by side. Rounding them differently would slide the echo series up to
    /// half a window against the levels it is weighted by, and weight each
    /// reading with a neighbouring window's energy.
    private static func gridLeadIn(track: CaptureTrack, timeline: RecordingTimeline) -> Double {
        let leadIn = timeline.leadIn(track: track)
        guard leadIn > 0 else { return 0 }
        return Double(max(0, Int((leadIn / levelWindowSeconds).rounded()))) * levelWindowSeconds
    }

    /// Moves a track's own measurements onto the meeting timeline by filling
    /// the seconds before it started recording.
    private static func padded(
        _ values: [Int8], by leadIn: Double, windowSeconds: Double, filler: Int8
    ) -> [Int8] {
        guard leadIn > 0, windowSeconds > 0 else { return values }
        let windows = Int((leadIn / windowSeconds).rounded())
        guard windows > 0 else { return values }
        return Array(repeating: filler, count: windows) + values
    }
}

/// One track, read a block at a time on demand.
///
/// The detector pulls through this, so no more of the track is decoded than the
/// model has asked for. The reader is a stateful class that is not `Sendable`;
/// the actor is what makes handing a closure over it across isolation safe.
private actor SampleReader {
    private let reader: TrackAudioReader
    private let frames: AVAudioFrameCount

    init(stream: TrackAudioStream, frames: AVAudioFrameCount = 8_192) throws {
        guard let reader = stream.makeReader() else {
            throw ProcessingError.audioUnreadable(path: stream.segmentsDirectory.lastPathComponent)
        }
        self.reader = reader
        self.frames = frames
    }

    /// The next block of mono samples, or nil at the end of the track.
    func next() throws -> [Float]? {
        while true {
            guard let buffer = try reader.read(frames: frames), buffer.frameLength > 0 else {
                return nil
            }
            guard let channel = buffer.floatChannelData?[0] else { continue }
            return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }
    }
}
