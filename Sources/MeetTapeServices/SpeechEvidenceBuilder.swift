import AVFoundation
import Foundation
import MeetTapeAudio
import MeetTapeCore

/// Measures what a meeting's recorded audio holds, so the assembler can tell a
/// sentence the local user said from one a speech model invented for the gaps.
///
/// Reads each track once at 16 kHz mono, the rate every model here works at.
/// The level pass is arithmetic and the detector pass is Silero, which reads
/// two and a half hours in about seven seconds.
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
            // A detector that is not installed yet costs its clause, not the
            // measurement: levels alone still remove most of what a model
            // invents, and the evidence records that nothing judged the audio
            // so a later pass can measure it again.
            do {
                let readings = try await detector.probabilities(samples: samples(of: stream))
                speechWindowSeconds = readings.windowSeconds
                speech = padded(
                    readings.values.map { Int8(max(0, min(100, ($0 * 100).rounded()))) },
                    by: leadIn, windowSeconds: readings.windowSeconds, filler: 0
                )
                detectorIdentifier = detector.identifier
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
            detector: detectorIdentifier
        )
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

    /// The track's samples, block by block, for a detector that carries state
    /// across the whole pass.
    ///
    /// The reader is synchronous and the detector is an actor, so the read runs
    /// on its own task and the blocks cross over the stream's buffer. Nothing
    /// holds the track whole: two hours at 16 kHz float32 is over 400 MB.
    private static func samples(
        of stream: TrackAudioStream
    ) -> AsyncThrowingStream<[Float], any Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .utility) {
                do {
                    try stream.forEachBuffer { buffer, _ in
                        guard let channel = buffer.floatChannelData?[0] else { return true }
                        let frames = Int(buffer.frameLength)
                        guard frames > 0 else { return true }
                        continuation.yield(Array(UnsafeBufferPointer(start: channel, count: frames)))
                        return !Task.isCancelled
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
