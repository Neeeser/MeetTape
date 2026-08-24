import AVFoundation
import Foundation
import MeetTapeCore
import Speech

/// Apple's SpeechAnalyzer behind the transcription protocol, macOS 26 and
/// later.
///
/// A benchmark candidate: word timings of its own, models that are system
/// assets the OS installs and owns, so the configuration downloads nothing.
/// On an older OS `transcribe` fails the stage rather than pretending; the
/// bench and any future settings surface gate on availability before naming
/// it.
public struct AppleSpeechTranscriptionBackend: TranscriptionBackend {
    public init() {}

    public var identifier: String { LocalSpeechStack.appleBackendIdentifier }
    public var isLocal: Bool { true }
    public var limits: BackendAudioLimits { .none }
    public var timing: TranscriptTiming { .words }

    public static var isAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    public func transcribe(
        audio: URL, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TranscriptionOutput {
        guard #available(macOS 26.0, *) else {
            throw AppleSpeechError.requiresNewerMacOS
        }
        let result = try await AppleSpeechAnalyzerRunner.transcribe(audio: audio)
        progress(1)
        let words = Self.words(from: result.runs)
        return TranscriptionOutput(
            segments: CtcForcedAlignment.segments(
                from: words,
                pauseSeconds: LocalAlignmentTuning.segmentPauseSeconds,
                maximumSeconds: LocalAlignmentTuning.segmentMaximumSeconds
            ),
            text: result.text,
            durationSeconds: result.durationSeconds
        )
    }

    /// Attributed-run spans as aligned words: each run's tokens split its span
    /// evenly, and a run the recognizer left untimed rides the previous
    /// word's end rather than inventing a time. Tokens stay bare: `segments`
    /// adds the assembler's leading space itself, and a token arriving with
    /// one rendered every gap as a double space.
    public static func words(
        from runs: [(text: String, start: Double?, end: Double?)]
    ) -> [CtcForcedAlignment.AlignedWord] {
        var out: [CtcForcedAlignment.AlignedWord] = []
        var reach = 0.0
        for run in runs {
            let tokens = run.text.split(whereSeparator: \.isWhitespace).map(String.init)
            guard !tokens.isEmpty else { continue }
            let start = run.start ?? reach
            let end = max(run.end ?? reach, start)
            let width = (end - start) / Double(tokens.count)
            for (index, token) in tokens.enumerated() {
                let wordStart = start + Double(index) * width
                out.append(CtcForcedAlignment.AlignedWord(
                    text: token, start: wordStart, end: wordStart + width
                ))
            }
            reach = max(reach, end)
        }
        return out
    }
}

public enum AppleSpeechError: Error, CustomStringConvertible {
    case requiresNewerMacOS
    case localeUnsupported

    public var description: String {
        switch self {
        case .requiresNewerMacOS: "Apple speech transcription requires macOS 26 or later"
        case .localeUnsupported: "Apple speech transcription does not support this locale"
        }
    }
}

@available(macOS 26.0, *)
enum AppleSpeechAnalyzerRunner {
    struct Output {
        var text: String
        var runs: [(text: String, start: Double?, end: Double?)]
        var durationSeconds: Double
    }

    /// One file through SpeechAnalyzer, results collected until the module
    /// finishes. Selecting this engine is the consent for the system's own
    /// asset download, the way picking any model is; the OS shows and owns
    /// that download.
    static func transcribe(audio: URL) async throws -> Output {
        guard
            let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
        else { throw AppleSpeechError.localeUnsupported }
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        if await AssetInventory.status(forModules: [transcriber]) != .installed {
            // Reserving an already-reserved locale is a no-op; a failure here
            // surfaces through the installation request below.
            _ = try? await AssetInventory.reserve(locale: locale)
            if let request = try await AssetInventory.assetInstallationRequest(
                supporting: [transcriber]
            ) {
                try await request.downloadAndInstall()
            }
        }

        let file = try AVAudioFile(forReading: audio)
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        let analyzer = try await SpeechAnalyzer(
            inputAudioFile: file, modules: [transcriber], finishAfterFile: true
        )
        _ = analyzer

        var runs: [(text: String, start: Double?, end: Double?)] = []
        var text = ""
        for try await result in transcriber.results {
            let attributed = result.text
            text += String(attributed.characters)
            for run in attributed.runs {
                let piece = String(attributed[run.range].characters)
                guard !piece.isEmpty else { continue }
                if let range = run.audioTimeRange {
                    runs.append((piece, range.start.seconds, range.end.seconds))
                } else {
                    runs.append((piece, nil, nil))
                }
            }
        }
        return Output(text: text, runs: runs, durationSeconds: seconds)
    }
}
