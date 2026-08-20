import Foundation
import WhisperKit

/// The loaded Whisper pipeline, behind a reference that can cross an isolation
/// boundary.
///
/// `WhisperKit` is a class with no `Sendable` conformance, so under Swift 6 it
/// can neither be returned from its own nonisolated initializer into an actor
/// nor handed to its own nonisolated `transcribe` from one. Which of those two a
/// given compiler release diagnoses varies: 6.4 accepts both call sites and
/// 6.1.2 rejects all three, so the type is kept out of actor-isolated code
/// entirely rather than left to region inference.
///
/// What makes the unchecked conformance sound is where the box lives.
/// `LocalModelManager` holds the only reference, in a private property, and
/// every path to `transcribe` is an isolated method on that actor, so calls
/// arrive one at a time and no two threads are ever inside the pipeline.
final class LoadedWhisper: @unchecked Sendable {
    private let pipeline: WhisperKit

    private init(pipeline: WhisperKit) {
        self.pipeline = pipeline
    }

    /// Loads from a folder that already holds the model.
    ///
    /// `modelFolder` is passed on every load because WhisperKit with
    /// `download: false` does not resolve its own download cache and fails with
    /// "Model folder is not set".
    static func load(
        model: String, downloadBase: URL, modelFolder: String
    ) async throws -> LoadedWhisper {
        let pipeline = try await WhisperKit(WhisperKitConfig(
            model: model,
            downloadBase: downloadBase,
            modelFolder: modelFolder,
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: false
        ))
        return LoadedWhisper(pipeline: pipeline)
    }

    func transcribe(
        audioPath: String,
        decodeOptions: DecodingOptions,
        callback: @escaping TranscriptionCallback
    ) async throws -> [TranscriptionResult] {
        try await pipeline.transcribe(
            audioPath: audioPath, decodeOptions: decodeOptions, callback: callback
        )
    }
}
