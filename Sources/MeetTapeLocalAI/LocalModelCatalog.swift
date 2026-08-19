import Foundation
import FluidAudio
import WhisperKit

/// Placeholder while the dependency graph is verified.
public enum LocalModelCatalog {
    public static let whisperModel = "openai_whisper-large-v3-v20240930_turbo_632MB"
    public static var diarizerDefaults: OfflineDiarizerConfig { OfflineDiarizerConfig.default }
    public static func decodeOptions() -> DecodingOptions { DecodingOptions() }
}
