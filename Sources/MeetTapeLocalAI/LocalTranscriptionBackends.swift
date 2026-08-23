import Foundation
import MeetTapeCore

/// Parakeet TDT v3 behind the transcription protocol.
///
/// Takes a whole track in one pass and returns word timings of its own, so it
/// needs neither chunking nor the aligner.
public struct ParakeetTranscriptionBackend: TranscriptionBackend {
    private let models: LocalModelManager

    public init(models: LocalModelManager) {
        self.models = models
    }

    public var identifier: String { LocalSpeechStack.parakeetBackendIdentifier }
    public var isLocal: Bool { true }
    public var limits: BackendAudioLimits { .none }
    public var timing: TranscriptTiming { .words }

    public func transcribe(
        audio: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TranscriptionOutput {
        let result = try await models.transcribeParakeet(audio: audio)
        progress(1)
        return TranscriptionOutput(
            segments: CtcForcedAlignment.segments(
                from: result.words,
                pauseSeconds: LocalAlignmentTuning.segmentPauseSeconds,
                maximumSeconds: LocalAlignmentTuning.segmentMaximumSeconds
            ),
            text: result.text,
            durationSeconds: result.durationSeconds
        )
    }
}

/// Cohere Transcribe behind the transcription protocol.
///
/// The most accurate local engine on meeting audio, and a text-only one: it
/// returns no timings, so the alignment stage supplies them per chunk. Chunks
/// are one model window long, which keeps the library's own window stitching
/// out of the path and every alignment trellis short.
public struct CohereTranscriptionBackend: TranscriptionBackend {
    private let models: LocalModelManager

    public init(models: LocalModelManager) {
        self.models = models
    }

    public var identifier: String { LocalSpeechStack.cohereBackendIdentifier }
    public var isLocal: Bool { true }
    public var limits: BackendAudioLimits {
        BackendAudioLimits(maximumSeconds: LocalCohereTuning.chunkSeconds)
    }
    public var timing: TranscriptTiming { .text }

    public func transcribe(
        audio: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TranscriptionOutput {
        let text = try await models.transcribeCohere(audio: audio)
        progress(1)
        return TranscriptionOutput(segments: [], text: text)
    }
}

/// The CTC forced aligner behind the alignment protocol.
public struct CtcTranscriptAligner: TranscriptAligner {
    private let models: LocalModelManager

    public init(models: LocalModelManager) {
        self.models = models
    }

    public var identifier: String { LocalSpeechStack.alignerIdentifier }

    public func align(audio: URL, text: String) async throws -> [RawTranscriptSegment] {
        try await models.alignTranscript(audio: audio, text: text)
    }
}
