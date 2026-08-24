import Foundation
import FluidAudio
import MeetTapeCore

/// Silero VAD behind the voice activity protocol.
///
/// Reads one track once and reports a speech probability every 256 ms. Fast
/// enough not to register beside a transcription pass: a 30-minute track takes
/// a second or two.
public struct FluidAudioVoiceActivityBackend: VoiceActivityBackend {
    private let models: LocalModelManager

    public init(models: LocalModelManager) {
        self.models = models
    }

    public var identifier: String { LocalSpeechStack.voiceActivityIdentifier }
    public var sampleRate: Double { Double(VadManager.sampleRate) }

    public func probabilities(
        samples: AsyncThrowingStream<[Float], any Error>
    ) async throws -> VoiceActivityProfile {
        try await models.detectVoiceActivity(samples: samples)
    }
}
