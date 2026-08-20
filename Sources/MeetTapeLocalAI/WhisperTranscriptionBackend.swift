import Foundation
import MeetTapeAudio
import MeetTapeCore
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
    public var producesWordTimestamps: Bool { LocalTranscriptionTuning.wordTimestamps }

    public func transcribe(
        audio: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TranscriptionOutput {
        try await models.transcribe(audio: audio, progress: progress)
    }
}

extension LocalModelManager {
    /// Transcribes one file.
    ///
    /// The decode options are the ones the local-processing probe settled on,
    /// and two of them are load-bearing rather than preferences. Special tokens
    /// are skipped because the library default leaks
    /// `<|startoftranscript|><|en|>` into the text. Word timings are on because
    /// speaker attribution consumes them. Prompt conditioning and VAD chunking
    /// are both deliberately absent: the first improves punctuation and
    /// destroys word timings, and the second was 15% faster over 65 minutes
    /// while dropping 231 of 9278 words and producing a segment whose start
    /// went backwards.
    func transcribe(
        audio: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TranscriptionOutput {
        let pipeline = try await loadedWhisper()

        var options = DecodingOptions()
        options.skipSpecialTokens = LocalTranscriptionTuning.skipSpecialTokens
        options.wordTimestamps = LocalTranscriptionTuning.wordTimestamps
        // Read from the tuning rather than written as literals, so the tests
        // that assert these values fail when the decoder stops honouring them.
        // VAD chunking was 15% faster over 65 minutes and dropped 231 of 9278
        // words, one segment starting before the one before it. Prompting
        // improves punctuation and collapses word timings: 198 distinct word
        // starts became 153, 43 of them zero-length, and attribution consumes
        // those timings.
        options.chunkingStrategy = LocalTranscriptionTuning.usesVADChunking ? .vad : nil
        options.promptTokens = nil
        options.usePrefillPrompt = LocalTranscriptionTuning.usesPromptConditioning
        options.detectLanguage = true
        options.verbose = false

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
