import Foundation
import FluidAudio
import PipitCore

/// Silero VAD behind the voice activity protocol.
///
/// Reads one track once and reports a speech probability every 256 ms. Fast
/// enough not to register beside a transcription pass: a 29-minute meeting took
/// under two seconds to measure, both tracks included.
public struct FluidAudioVoiceActivityBackend: VoiceActivityBackend {
    private let models: LocalModelManager

    public init(models: LocalModelManager) {
        self.models = models
    }

    public var identifier: String { LocalSpeechStack.voiceActivityIdentifier }
    public var sampleRate: Double { Double(VadManager.sampleRate) }

    public func probabilities(
        reading next: @escaping @Sendable () async throws -> [Float]?
    ) async throws -> VoiceActivityProfile {
        try await models.detectVoiceActivity(reading: next)
    }
}
