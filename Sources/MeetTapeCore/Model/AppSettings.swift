import Foundation

/// Model identifiers, held as configuration rather than scattered through the
/// code so a newer model is a settings change, not a rewrite.
public struct AIModelSettings: Codable, Sendable, Equatable {
    /// Plain transcription for the local track. `whisper-1` with `verbose_json` is
    /// the default because it returns the timings a timeline needs; several newer
    /// models return excellent text with no segments and no words at all.
    public var transcription: String
    /// Speaker-attributed transcription for the remote track.
    public var diarization: String
    /// Reasoning model for speaker resolution, titles and summaries.
    public var metadata: String

    public init(
        transcription: String = "whisper-1",
        diarization: String = "gpt-4o-transcribe-diarize",
        metadata: String = "gpt-5.6-luna"
    ) {
        self.transcription = transcription
        self.diarization = diarization
        self.metadata = metadata
    }

    /// Models known to return the timing structure the canonical timeline needs.
    public static let timestampCapableTranscription = ["whisper-1"]
    public static let diarizationCapable = ["gpt-4o-transcribe-diarize"]
    public static let metadataChoices = ["gpt-5.6-luna", "gpt-5.1", "gpt-5.1-mini", "gpt-4.1"]

    /// One missing key must not reset the other two.
    ///
    /// The synthesized decoder throws on an absent field, and the enclosing
    /// `AppSettings` decoder falls back to the whole default struct when this
    /// one throws, so adding a field here would silently discard every model
    /// identifier the user had chosen.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AIModelSettings()
        transcription =
            try container.decodeIfPresent(String.self, forKey: .transcription) ?? defaults.transcription
        diarization =
            try container.decodeIfPresent(String.self, forKey: .diarization) ?? defaults.diarization
        metadata = try container.decodeIfPresent(String.self, forKey: .metadata) ?? defaults.metadata
    }

    /// Whether the responses endpoint accepts a `reasoning` parameter for this
    /// model. GPT-4-generation models reject the field with a 400.
    public static func acceptsReasoningEffort(_ model: String) -> Bool {
        if model.hasPrefix("gpt-5") { return true }
        // The o-series: o1, o3, o4-mini and their dated variants.
        return model.range(of: "^o[0-9]", options: .regularExpression) != nil
    }
}

/// Which AI enrichment runs. Recording and the transcript stay useful with every
/// one of these switched off.
public struct EnrichmentSettings: Codable, Sendable, Equatable {
    public var generateTitle: Bool
    public var generateDescription: Bool
    public var generateNotes: Bool
    public var generateSummary: Bool
    public var suggestSpeakers: Bool

    public init(
        generateTitle: Bool = true,
        generateDescription: Bool = true,
        generateNotes: Bool = true,
        generateSummary: Bool = true,
        suggestSpeakers: Bool = true
    ) {
        self.generateTitle = generateTitle
        self.generateDescription = generateDescription
        self.generateNotes = generateNotes
        self.generateSummary = generateSummary
        self.suggestSpeakers = suggestSpeakers
    }

    public var wantsAnything: Bool {
        generateTitle || generateDescription || generateNotes || generateSummary
    }

    /// As above: one absent switch must not reset the rest.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = EnrichmentSettings()
        generateTitle =
            try container.decodeIfPresent(Bool.self, forKey: .generateTitle) ?? defaults.generateTitle
        generateDescription =
            try container.decodeIfPresent(Bool.self, forKey: .generateDescription)
            ?? defaults.generateDescription
        generateNotes =
            try container.decodeIfPresent(Bool.self, forKey: .generateNotes) ?? defaults.generateNotes
        generateSummary =
            try container.decodeIfPresent(Bool.self, forKey: .generateSummary)
            ?? defaults.generateSummary
        suggestSpeakers =
            try container.decodeIfPresent(Bool.self, forKey: .suggestSpeakers) ?? defaults.suggestSpeakers
    }
}

/// Which backend runs one processing stage.
///
/// Transcription and diarization choose independently, and neither is tied to
/// enrichment. A user can run words locally and speakers in the cloud, or the
/// reverse, and speaker memory stays local either way.
public enum ProcessingBackendChoice: String, Codable, Sendable, CaseIterable {
    case local
    case openAI = "openai"

    public var displayName: String {
        switch self {
        case .local: "Local"
        case .openAI: "OpenAI"
        }
    }
}

/// What the local voice memory is allowed to do.
public struct SpeakerRecognitionSettings: Codable, Sendable, Equatable {
    /// Match speakers against the people the user has named.
    public var recognizeKnownVoices: Bool
    /// Keep a profile for a voice that recurs across meetings but has no name.
    public var rememberRecurringVoices: Bool
    /// Build the local user's own profile from microphone-track audio, where
    /// the speaker is known by construction. That profile is what makes an
    /// in-person or imported recording recognizable.
    public var learnMyVoice: Bool
    /// Turn confirmed speaker corrections into enrolment material once enough
    /// clean speech has accumulated.
    public var learnFromCorrections: Bool

    public init(
        recognizeKnownVoices: Bool = true,
        rememberRecurringVoices: Bool = true,
        learnMyVoice: Bool = true,
        learnFromCorrections: Bool = true
    ) {
        self.recognizeKnownVoices = recognizeKnownVoices
        self.rememberRecurringVoices = rememberRecurringVoices
        self.learnMyVoice = learnMyVoice
        self.learnFromCorrections = learnFromCorrections
    }

    /// As above.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SpeakerRecognitionSettings()
        recognizeKnownVoices =
            try container.decodeIfPresent(Bool.self, forKey: .recognizeKnownVoices)
            ?? defaults.recognizeKnownVoices
        rememberRecurringVoices =
            try container.decodeIfPresent(Bool.self, forKey: .rememberRecurringVoices)
            ?? defaults.rememberRecurringVoices
        learnMyVoice =
            try container.decodeIfPresent(Bool.self, forKey: .learnMyVoice) ?? defaults.learnMyVoice
        learnFromCorrections =
            try container.decodeIfPresent(Bool.self, forKey: .learnFromCorrections)
            ?? defaults.learnFromCorrections
    }
}

/// Where each processing stage runs.
///
/// Local is the default for both, so a fresh installation records,
/// transcribes, diarizes and recognizes speakers with no API key at all.
public struct ProcessingSettings: Codable, Sendable, Equatable {
    public var transcription: ProcessingBackendChoice
    public var diarization: ProcessingBackendChoice
    public var speakers: SpeakerRecognitionSettings
    /// The identity that represents the person using this Mac.
    public var localUserIdentityID: IdentityID?

    public init(
        transcription: ProcessingBackendChoice = .local,
        diarization: ProcessingBackendChoice = .local,
        speakers: SpeakerRecognitionSettings = SpeakerRecognitionSettings(),
        localUserIdentityID: IdentityID? = nil
    ) {
        self.transcription = transcription
        self.diarization = diarization
        self.speakers = speakers
        self.localUserIdentityID = localUserIdentityID
    }

    public var usesLocalTranscription: Bool { transcription == .local }
    public var usesLocalDiarization: Bool { diarization == .local }
    /// True when nothing in the transcript path needs an API key.
    public var isFullyLocal: Bool { usesLocalTranscription && usesLocalDiarization }

    /// As above.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ProcessingSettings()
        transcription =
            try container.decodeIfPresent(ProcessingBackendChoice.self, forKey: .transcription)
            ?? defaults.transcription
        diarization =
            try container.decodeIfPresent(ProcessingBackendChoice.self, forKey: .diarization)
            ?? defaults.diarization
        speakers =
            try container.decodeIfPresent(SpeakerRecognitionSettings.self, forKey: .speakers)
            ?? defaults.speakers
        localUserIdentityID = try container.decodeIfPresent(IdentityID.self, forKey: .localUserIdentityID)
    }
}

/// Everything the user can configure. Stored as JSON in Application Support so it
/// is readable and portable, with the API key deliberately absent: that lives in
/// the keychain and nowhere else.
public struct AppSettings: Codable, Sendable, Equatable {
    /// 2 added the processing backends. The number is read on decode, because a
    /// file written before it existed was configured under a different default
    /// and must not be moved off it silently.
    public static let currentVersion = 2

    public var version: Int
    public var storageRootPath: String
    public var launchAtLogin: Bool
    public var showNotifications: Bool
    public var models: AIModelSettings
    public var processing: ProcessingSettings
    public var enrichment: EnrichmentSettings
    public var providers: ProviderPolicies
    /// Name used for the local speaker, which the microphone track is by
    /// construction on a remote call.
    public var localUserName: String
    public var segmentSeconds: Double
    public var preRollSeconds: Double
    /// Applications the user chose to always or never record.
    public var alwaysRecordApplications: [String]
    public var neverRecordApplications: [String]
    public var hasCompletedOnboarding: Bool
    /// Prefer the built-in microphone when a Bluetooth headset is used for output,
    /// which avoids the hands-free profile dropping input to 16 kHz.
    public var preferBuiltInMicrophone: Bool
    /// Run the microphone through the system voice-processing unit, which
    /// subtracts what the speakers are playing. Without it, a user on speakers
    /// gets the remote side of the call recorded onto their own track.
    public var echoCancellation: Bool

    public init(
        version: Int = AppSettings.currentVersion,
        storageRootPath: String = MeetingArchiveLayout.defaultRoot.path,
        launchAtLogin: Bool = false,
        showNotifications: Bool = true,
        models: AIModelSettings = AIModelSettings(),
        processing: ProcessingSettings = ProcessingSettings(),
        enrichment: EnrichmentSettings = EnrichmentSettings(),
        providers: ProviderPolicies = ProviderPolicies(),
        localUserName: String = "Me",
        segmentSeconds: Double = 30,
        preRollSeconds: Double = 15,
        alwaysRecordApplications: [String] = [],
        neverRecordApplications: [String] = [],
        hasCompletedOnboarding: Bool = false,
        preferBuiltInMicrophone: Bool = false,
        echoCancellation: Bool = true
    ) {
        self.version = version
        self.storageRootPath = storageRootPath
        self.launchAtLogin = launchAtLogin
        self.showNotifications = showNotifications
        self.models = models
        self.processing = processing
        self.enrichment = enrichment
        self.providers = providers
        self.localUserName = localUserName
        self.segmentSeconds = segmentSeconds
        self.preRollSeconds = preRollSeconds
        self.alwaysRecordApplications = alwaysRecordApplications
        self.neverRecordApplications = neverRecordApplications
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.preferBuiltInMicrophone = preferBuiltInMicrophone
        self.echoCancellation = echoCancellation
    }

    /// Every field decodes with its default when absent, so a settings file
    /// written by an older build survives a new field instead of resetting the
    /// whole configuration to defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? defaults.version
        storageRootPath =
            try container.decodeIfPresent(String.self, forKey: .storageRootPath)
            ?? defaults.storageRootPath
        launchAtLogin =
            try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? defaults.launchAtLogin
        showNotifications =
            try container.decodeIfPresent(Bool.self, forKey: .showNotifications)
            ?? defaults.showNotifications
        models = try container.decodeIfPresent(AIModelSettings.self, forKey: .models) ?? defaults.models
        // An existing installation keeps the backend it was configured with. A
        // settings file written before local processing existed described a
        // machine that transcribed in the cloud, and switching it over on the
        // next launch would change the transcript, the model recorded on every
        // chunk, and start a 650 MB download nobody asked for. Local is the
        // default for a fresh installation, which has no file at all.
        if let stored = try container.decodeIfPresent(ProcessingSettings.self, forKey: .processing) {
            processing = stored
        } else if version < 2 {
            processing = ProcessingSettings(transcription: .openAI, diarization: .openAI)
        } else {
            processing = defaults.processing
        }
        enrichment =
            try container.decodeIfPresent(EnrichmentSettings.self, forKey: .enrichment)
            ?? defaults.enrichment
        providers =
            try container.decodeIfPresent(ProviderPolicies.self, forKey: .providers)
            ?? defaults.providers
        localUserName =
            try container.decodeIfPresent(String.self, forKey: .localUserName) ?? defaults.localUserName
        segmentSeconds =
            try container.decodeIfPresent(Double.self, forKey: .segmentSeconds)
            ?? defaults.segmentSeconds
        preRollSeconds =
            try container.decodeIfPresent(Double.self, forKey: .preRollSeconds)
            ?? defaults.preRollSeconds
        // Both lists hold applications. Reading them through the same
        // normalisation the prompt writes means a choice saved when the
        // identifier was stored verbatim covers the application it was always
        // meant to, and three helpers of one application read back as the one
        // application the user chose.
        alwaysRecordApplications = Self.applications(
            try container.decodeIfPresent([String].self, forKey: .alwaysRecordApplications)
                ?? defaults.alwaysRecordApplications
        )
        neverRecordApplications = Self.applications(
            try container.decodeIfPresent([String].self, forKey: .neverRecordApplications)
                ?? defaults.neverRecordApplications
        )
        hasCompletedOnboarding =
            try container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding)
            ?? defaults.hasCompletedOnboarding
        preferBuiltInMicrophone =
            try container.decodeIfPresent(Bool.self, forKey: .preferBuiltInMicrophone)
            ?? defaults.preferBuiltInMicrophone
        echoCancellation =
            try container.decodeIfPresent(Bool.self, forKey: .echoCancellation)
            ?? defaults.echoCancellation
    }

    /// The applications a saved list of process identifiers names, in the order
    /// the user chose them and without repeats.
    private static func applications(_ identifiers: [String]) -> [String] {
        identifiers
            .map(MicrophoneIgnoreList.applicationIdentifier(for:))
            .reduce(into: [String]()) { unique, application in
                guard !unique.contains(application) else { return }
                unique.append(application)
            }
    }

    public var storageRoot: URL { URL(fileURLWithPath: storageRootPath) }

    public var genericDetectorConfiguration: GenericCallDetector.Configuration {
        GenericCallDetector.Configuration(
            alwaysRecord: Set(alwaysRecordApplications),
            neverRecord: Set(neverRecordApplications)
        )
    }
}

/// Reads and writes `settings.json`.
public struct SettingsStore: Sendable {
    public let url: URL

    public init(directory: URL) {
        self.url = directory.appendingPathComponent("settings.json")
    }

    public func load() -> AppSettings {
        guard let data = try? Data(contentsOf: url),
              let settings = try? ArchiveCoding.decode(AppSettings.self, from: data, path: url.path)
        else { return AppSettings() }
        return settings
    }

    public func save(_ settings: AppSettings) throws {
        try AtomicFile.write(try ArchiveCoding.encode(settings), to: url)
    }
}
