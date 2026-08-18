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
        metadata: String = "gpt-5.1"
    ) {
        self.transcription = transcription
        self.diarization = diarization
        self.metadata = metadata
    }

    /// Models known to return the timing structure the canonical timeline needs.
    public static let timestampCapableTranscription = ["whisper-1"]
    public static let diarizationCapable = ["gpt-4o-transcribe-diarize"]
    public static let metadataChoices = ["gpt-5.1", "gpt-5.1-mini", "gpt-4.1"]
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
}

/// Everything the user can configure. Stored as JSON in Application Support so it
/// is readable and portable, with the API key deliberately absent: that lives in
/// the keychain and nowhere else.
public struct AppSettings: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var storageRootPath: String
    public var launchAtLogin: Bool
    public var showNotifications: Bool
    public var models: AIModelSettings
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

    public init(
        version: Int = AppSettings.currentVersion,
        storageRootPath: String = MeetingArchiveLayout.defaultRoot.path,
        launchAtLogin: Bool = false,
        showNotifications: Bool = true,
        models: AIModelSettings = AIModelSettings(),
        enrichment: EnrichmentSettings = EnrichmentSettings(),
        providers: ProviderPolicies = ProviderPolicies(),
        localUserName: String = "Me",
        segmentSeconds: Double = 30,
        preRollSeconds: Double = 15,
        alwaysRecordApplications: [String] = [],
        neverRecordApplications: [String] = [],
        hasCompletedOnboarding: Bool = false,
        preferBuiltInMicrophone: Bool = false
    ) {
        self.version = version
        self.storageRootPath = storageRootPath
        self.launchAtLogin = launchAtLogin
        self.showNotifications = showNotifications
        self.models = models
        self.enrichment = enrichment
        self.providers = providers
        self.localUserName = localUserName
        self.segmentSeconds = segmentSeconds
        self.preRollSeconds = preRollSeconds
        self.alwaysRecordApplications = alwaysRecordApplications
        self.neverRecordApplications = neverRecordApplications
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.preferBuiltInMicrophone = preferBuiltInMicrophone
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
