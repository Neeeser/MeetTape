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

    /// Roughly what a first run downloads: 624 MB of Whisper plus about 21 MB
    /// of diarizer models.
    public static let approximateDownloadBytes: Int64 = 650 * 1_024 * 1_024
    public static let approximateWhisperBytes: Int64 = 624 * 1_024 * 1_024
    public static let approximateDiarizerBytes: Int64 = 21 * 1_024 * 1_024
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
