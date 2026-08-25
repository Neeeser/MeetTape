import Foundation
import PipitAudio
import PipitCore
import WhisperKit

/// On-device transcription with Whisper Large-v3-Turbo.
///
/// A thin adapter: the work happens inside `LocalModelManager`, which owns the
/// loaded pipeline and, by being an actor, keeps one heavy local job running at
/// a time.
public struct WhisperTranscriptionBackend: TranscriptionBackend {
    private let models: LocalModelManager

    public init(models: LocalModelManager) {
        self.models = models
    }

    public var identifier: String { LocalSpeechStack.whisperBackendIdentifier }
    public var isLocal: Bool { true }
    /// None. WhisperKit handles a whole meeting and held timestamps monotonic
    /// over a 65-minute file, so nothing is chunked before it.
    public var limits: BackendAudioLimits { .none }
    public var timing: TranscriptTiming {
        LocalTranscriptionTuning.wordTimestamps ? .words : .segments
    }

    public func transcribe(
        audio: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TranscriptionOutput {
        try await models.transcribe(audio: audio, progress: progress)
    }
}

extension LocalModelManager {
    /// The decoder settings, in one place a test can read.
    ///
    /// Every one of these is a measured rule, and each was written as a literal
    /// at the call site where nothing could check it: VAD chunking was 15%
    /// faster over 65 minutes and dropped 231 of 9278 words with one segment
    /// starting before its predecessor; prompting improves punctuation and
    /// collapses word timings, taking 198 distinct word starts to 153 with 43 of
    /// them zero-length, which attribution consumes; and leaving special tokens
    /// in leaks <|startoftranscript|> into the transcript text.
    public static func decodingOptions() -> DecodingOptions {
        var options = DecodingOptions()
        options.skipSpecialTokens = LocalTranscriptionTuning.skipSpecialTokens
        options.wordTimestamps = LocalTranscriptionTuning.wordTimestamps
        options.chunkingStrategy = LocalTranscriptionTuning.usesVADChunking ? .vad : nil
        options.promptTokens = nil
        options.usePrefillPrompt = LocalTranscriptionTuning.usesPromptConditioning
        options.detectLanguage = true
        options.verbose = false
        return options
    }

    func transcribe(
        audio: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TranscriptionOutput {
        let pipeline = try await loadedWhisper()

        let options = Self.decodingOptions()

        let duration = MonoAudioDecoder.durationSeconds(audio)
        let results = try await pipeline.transcribe(
            audioPath: audio.path,
            decodeOptions: options,
            callback: { window in
                // The decoder reports which 30-second window it is on, which is
                // the only position it exposes while a file is in flight.
                guard duration > 0 else { return true }
                let seconds = Double(window.windowId + 1) * 30
                progress(min(max(seconds / duration, 0), 1))
                return true
            }
        )
        progress(1)

        let merged = results.count == 1
            ? results[0]
            : TranscriptionUtilities.mergeTranscriptionResults(results)

        var segments: [RawTranscriptSegment] = []
        segments.reserveCapacity(merged.segments.count)
        for segment in merged.segments {
            var words: [RawTranscriptWord]?
            if let timings = segment.words {
                var collected: [RawTranscriptWord] = []
                collected.reserveCapacity(timings.count)
                for timing in timings {
                    collected.append(RawTranscriptWord(
                        start: Double(timing.start),
                        end: Double(timing.end),
                        text: timing.word,
                        probability: Double(timing.probability)
                    ))
                }
                words = collected
            }
            segments.append(RawTranscriptSegment(
                start: Double(segment.start),
                end: Double(segment.end),
                text: segment.text.trimmingCharacters(in: .whitespaces),
                speaker: nil,
                words: words
            ))
        }
        return TranscriptionOutput(
            segments: segments,
            text: merged.text,
            language: merged.language,
            durationSeconds: duration > 0 ? duration : nil,
            rawBody: nil
        )
    }
}
