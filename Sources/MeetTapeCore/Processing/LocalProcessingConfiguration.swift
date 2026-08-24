import Foundation

/// The on-device speech stack, named in one place.
///
/// These identifiers are pinned rather than resolved at runtime: the accuracy,
/// speed and threshold numbers MeetTape ships against were measured on exactly
/// these revisions, so moving to another one is a re-evaluation.
public enum LocalSpeechStack {
    /// Whisper Large-v3-Turbo through WhisperKit. 624 MB, RTFx about 15 on an
    /// M2 Pro, content parity with `whisper-1` on technical vocabulary.
    public static let whisperModel = "openai_whisper-large-v3-v20240930_turbo_632MB"
    public static let whisperPackage = "argmax-oss-swift 1.1.0"
    public static let diarizerPackage = "FluidAudio 0.15.6"
    /// What goes in `DiarizationRun.backend`.
    public static let diarizerBackendIdentifier = "fluidaudio-offline-0.15.6"
    public static let whisperBackendIdentifier = "whisperkit-large-v3-turbo"

    public static let approximateWhisperBytes: Int64 = 624 * 1_024 * 1_024
    public static let approximateDiarizerBytes: Int64 = 21 * 1_024 * 1_024

    /// Parakeet TDT v3 through FluidAudio. 25 languages, word timings, over
    /// 100x realtime on Apple Silicon, 9.4% WER on AMI meeting audio against
    /// Whisper Turbo's 13.9% (Open ASR leaderboard, cleaned references,
    /// 2026-08).
    public static let parakeetBackendIdentifier = "fluidaudio-parakeet-tdt-v3"
    public static let approximateParakeetBytes: Int64 = 460 * 1_024 * 1_024

    /// Cohere Transcribe 03-2026 through FluidAudio, the INT8 hybrid build.
    /// The most accurate local model on meeting audio as a raw model (7.0% AMI
    /// WER), around 8x realtime warm, with a one-time ANE compile of several
    /// minutes on first load. Returns text with no timings; the CTC aligner
    /// supplies them.
    ///
    /// End to end that ranking reverses. Through this pipeline, chunked,
    /// aligned and assembled, it measured 36.0% median filler-stripped WER
    /// over 14 AMI cases against Parakeet's 20.2%, and lost every one of the
    /// 14, which is why Parakeet is the default.
    public static let cohereBackendIdentifier = "fluidaudio-cohere-transcribe-03-2026-q8"
    public static let approximateCohereBytes: Int64 = 2_100 * 1_024 * 1_024

    /// Parakeet CTC 0.6B, the forced-alignment model. Recorded as alignment
    /// provenance on every aligned chunk. The 110M variant was measured first
    /// and warped badly where a voice gave it weak posteriors, stacking whole
    /// turns onto single frames; the 0.6B held the same audio to about a
    /// second.
    public static let alignerIdentifier = "fluidaudio-parakeet-ctc-0.6b"
    public static let approximateAlignerBytes: Int64 = 600 * 1_024 * 1_024

    /// Silero VAD v6.2.1 through FluidAudio, the unified 256 ms Core ML build.
    /// Recorded on the speech evidence as what judged the microphone track.
    /// 1.1 MB installed, and it reads a 30-minute track in a second or two, so
    /// it costs nothing measurable against a transcription pass.
    public static let voiceActivityIdentifier = "silero-vad-unified-256ms-v6.2.1"
    public static let approximateVoiceActivityBytes: Int64 = 2 * 1_024 * 1_024

    /// What each unit's files came from, written into its receipt so a
    /// dependency or variant bump reads as a stale install rather than as
    /// strange results.
    public static func revision(for unit: LocalModelUnit) -> String {
        switch unit {
        case .whisper: "\(whisperModel) @ \(whisperPackage)"
        case .parakeet: "parakeet-tdt-0.6b-v3-int8 @ \(diarizerPackage)"
        case .cohere: "cohere-transcribe-03-2026-q8 @ \(diarizerPackage)"
        case .ctcAligner: "parakeet-ctc-0.6b @ \(diarizerPackage)"
        case .diarizer: diarizerPackage
        case .voiceActivity: "\(voiceActivityIdentifier) @ \(diarizerPackage)"
        }
    }
}

/// One independently installable set of model files.
///
/// Which units a configuration needs is a pure decision made here; how each is
/// fetched and loaded lives with the implementations.
public enum LocalModelUnit: String, Codable, CaseIterable, Sendable {
    case whisper
    case parakeet
    case cohere
    case ctcAligner = "ctc-aligner"
    case diarizer
    case voiceActivity = "voice-activity"

    /// The units the given settings actually use.
    ///
    /// The diarizer is always in the set when anything local runs: local
    /// diarization needs it outright, and voice memory embeds with its models
    /// in every configuration. The aligner is required by any chosen
    /// transcription model that returns text without timings.
    public static func required(for settings: AppSettings) -> Set<LocalModelUnit> {
        // Always. Local diarization needs it outright, and voice memory embeds
        // a cloud diarizer's intervals with the same models, so a cloud-only
        // configuration needs it too. Leaving it out of that set made
        // `ensureInstalled` report success for a machine with no models at
        // all, and the embedding extractor then threw from inside a stage
        // instead of the meeting skipping voice memory.
        // The detector is required for the same reason and in the same set.
        // Every backend fabricates filler for a microphone track that is mostly
        // not speech, cloud ones included: 179 of 222 segments on the local
        // user's track across five meetings were words nobody said. Leaving it
        // optional would mean the configuration most exposed to the defect,
        // cloud transcription of a listener's own microphone, is the one
        // shipped without the guard.
        var units: Set<LocalModelUnit> = [.diarizer, .voiceActivity]
        if settings.processing.usesLocalTranscription {
            switch settings.processing.localTranscriptionModel {
            case .cohere:
                units.insert(.cohere)
                units.insert(.ctcAligner)
            case .parakeet:
                units.insert(.parakeet)
            case .whisper:
                units.insert(.whisper)
            }
        }
        if !settings.processing.usesLocalTranscription,
            AIModelSettings.transcriptionTiming(for: settings.models.transcription) == .text {
            units.insert(.ctcAligner)
        }
        return units
    }

    public var approximateBytes: Int64 {
        switch self {
        case .whisper: LocalSpeechStack.approximateWhisperBytes
        case .parakeet: LocalSpeechStack.approximateParakeetBytes
        case .cohere: LocalSpeechStack.approximateCohereBytes
        case .ctcAligner: LocalSpeechStack.approximateAlignerBytes
        case .diarizer: LocalSpeechStack.approximateDiarizerBytes
        case .voiceActivity: LocalSpeechStack.approximateVoiceActivityBytes
        }
    }
}

/// Which engine transcribes when transcription runs on this Mac.
public enum LocalTranscriptionModel: String, Codable, CaseIterable, Sendable {
    /// The strongest raw model on the meeting-audio leaderboard, and behind
    /// Parakeet through this pipeline: 36.0% median filler-stripped WER over
    /// 14 AMI cases against Parakeet's 20.2%. Text only, aligned locally.
    case cohere
    /// Fast, word timings of its own, 25 languages.
    case parakeet
    /// The original local engine, kept for installs that already have it.
    case whisper

    /// The engines in the order they are offered, recommended first.
    /// `allCases` is declaration order, which is alphabetical and puts a 2.1 GB
    /// engine above the one that won every meeting of the benchmark.
    public static let offered: [LocalTranscriptionModel] = [.parakeet, .cohere, .whisper]

    public var backendIdentifier: String {
        switch self {
        case .cohere: LocalSpeechStack.cohereBackendIdentifier
        case .parakeet: LocalSpeechStack.parakeetBackendIdentifier
        case .whisper: LocalSpeechStack.whisperBackendIdentifier
        }
    }
}

/// The forced-alignment settings MeetTape depends on.
public enum LocalAlignmentTuning {
    /// Aligned words group into segments at pauses past this, before the
    /// assembler applies its own tuned utterance thresholds.
    public static let segmentPauseSeconds: Double = 1.0
    /// And never longer than this, so duplicate detection over chunk overlaps
    /// keeps something to compare.
    public static let segmentMaximumSeconds: Double = 30
    /// A cloud text-only backend is chunked to this length so every chunk's
    /// Viterbi trellis stays small; the planner still moves boundaries to
    /// silence.
    public static let chunkSeconds: Double = 300
}

/// The local Cohere engine's chunking.
public enum LocalCohereTuning {
    /// One model window per chunk, so the library's own overlap stitching
    /// never runs. Its LCS merge dropped a five-second span at the 35-second
    /// window boundary on the 38.5-second fixture; MeetTape's energy-guided
    /// chunk boundaries and the assembler's overlap dedup do the same job and
    /// are the machinery the cloud path has always used. Matches
    /// `CohereAsrConfig.maxAudioSeconds`.
    public static let chunkSeconds: Double = 35
}

/// The offline diarizer settings MeetTape overrides, and why.
///
/// Held here, in the module that imports nothing, so the values are assertable
/// in a test without loading a CoreML model, and so the one tuned number is not
/// a literal buried in a call site.
public enum LocalDiarizationTuning {
    /// VBx acoustic scaling. The library ships 0.07, which under-counts badly
    /// once a meeting passes eight speakers: over 32 recordings of 2 to 21
    /// speakers it found 8 where there were 17, left 35.4% of reference
    /// speakers without a cluster, and put 92.8% of words on the right speaker.
    /// At 0.20 the same corpus gives DER 6.22% to 4.06%, JER 51.3% to 30.7%,
    /// mean speaker-count error at ten or more speakers 6.25 to 1.38, word
    /// attribution 95.5%, and 11.9% of speakers lost.
    ///
    /// Tuned on VoxConverse, which is broadcast panels rather than conference
    /// calls, so it is a measured default and not a solved constant.
    public static let warmStartFa: Double = 0.20

    /// The library default, kept so the A/B comparison in the evaluation tool
    /// names the same number the probe did.
    public static let libraryDefaultWarmStartFa: Double = 0.07

    /// Never set automatically. The tuned configuration beats even the exact
    /// true speaker count on word attribution (95.5% against 94.4%), on merges
    /// a user has to perform (0.8 against 2.2 per recording) and on speakers
    /// recovered. A participant list, a calendar attendee count and a human
    /// guess are all worse than not asking, and the first two are usually wrong
    /// in the expensive direction, because an invited-but-silent attendee
    /// inflates the count and under-counting cannot be undone with a merge.
    public static let automaticSpeakerCount: Int? = nil
}

/// Whisper decode options MeetTape depends on.
public enum LocalTranscriptionTuning {
    /// The default is false, which leaks `<|startoftranscript|><|en|>` into the
    /// transcript text.
    public static let skipSpecialTokens = true
    /// Word timings are what speaker attribution consumes.
    public static let wordTimestamps = true
    /// Prompt conditioning improves punctuation and destroys word timings: 198
    /// distinct word starts became 153, with 43 words reporting zero duration
    /// and 16 collapsed onto one timestamp. Punctuation is a rendering problem;
    /// timings are not recoverable.
    public static let usesPromptConditioning = false
    /// VAD chunking was 15% faster over 65 minutes and dropped 231 of 9278
    /// words, and introduced a segment whose start went backwards. WhisperKit's
    /// own long-file handling held timestamps monotonic over the same file.
    public static let usesVADChunking = false
}
