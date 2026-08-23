import Foundation
import MeetTapeCore

/// Measured API limits. These came from probing the live API, not documentation.
public enum AILimits {
    /// HTTP 400 at 1848 s; anything longer must be chunked.
    public static let maximumDiarizationSeconds: Double = 1_400
    /// HTTP 413 at 26,297,270 bytes.
    public static let maximumRequestBytes = 25 * 1_024 * 1_024
}

public struct TranscriptionRequest: Sendable {
    public var audio: URL
    public var model: String
    public var language: String?
    /// Context that improves recognition of names and jargon.
    public var prompt: String?
    /// Words the model should expect. Only the timing-free transcription
    /// models take these; the client drops them for every other model.
    public var keywords: [String]

    public init(
        audio: URL, model: String, language: String? = nil, prompt: String? = nil,
        keywords: [String] = []
    ) {
        self.audio = audio
        self.model = model
        self.language = language
        self.prompt = prompt
        self.keywords = keywords
    }
}

public struct DiarizationRequest: Sendable {
    public var audio: URL
    public var model: String
    /// Reference clips for speakers whose identity is already known.
    ///
    /// Only ever used for the local user. Enrolling a partial set of remote
    /// speakers measured worse than enrolling none, because unenrolled speakers
    /// get forced into an enrolled identity instead of a fresh label.
    public var knownSpeakers: [KnownSpeaker]

    public struct KnownSpeaker: Sendable {
        public var name: String
        public var wavData: Data

        public init(name: String, wavData: Data) {
            self.name = name
            self.wavData = wavData
        }
    }

    public init(audio: URL, model: String, knownSpeakers: [KnownSpeaker] = []) {
        self.audio = audio
        self.model = model
        self.knownSpeakers = knownSpeakers
    }
}

public struct TranscriptionResponse: Sendable, Equatable {
    public var segments: [RawTranscriptSegment]
    public var text: String
    public var durationSeconds: Double?
    /// The response body exactly as received, stored as ground truth.
    public var rawBody: Data

    public init(
        segments: [RawTranscriptSegment], text: String, durationSeconds: Double?, rawBody: Data
    ) {
        self.segments = segments
        self.text = text
        self.durationSeconds = durationSeconds
        self.rawBody = rawBody
    }
}

/// A speaker identity the model proposes, always a suggestion and never truth.
public struct SpeakerSuggestion: Sendable, Equatable, Codable {
    public var label: String
    public var name: String
    public var confidence: Double
    public var evidence: String

    public init(label: String, name: String, confidence: Double, evidence: String) {
        self.label = label
        self.name = name
        self.confidence = confidence
        self.evidence = evidence
    }
}

public struct MeetingEnrichment: Sendable, Equatable, Codable {
    public var title: String?
    public var summary: String?
    public var description: String?
    public var notes: String?

    public init(title: String? = nil, summary: String? = nil, description: String? = nil, notes: String? = nil) {
        self.title = title
        self.summary = summary
        self.description = description
        self.notes = notes
    }
}

public struct EnrichmentRequest: Sendable {
    public var transcript: String
    public var humanNotes: String?
    public var participants: [String]
    public var provider: MeetingProvider
    public var durationSeconds: Double
    public var wantsTitle: Bool
    public var wantsDescription: Bool
    public var wantsSummary: Bool
    public var wantsNotes: Bool

    public init(
        transcript: String, humanNotes: String?, participants: [String], provider: MeetingProvider,
        durationSeconds: Double, wantsTitle: Bool, wantsDescription: Bool,
        wantsSummary: Bool, wantsNotes: Bool
    ) {
        self.transcript = transcript
        self.humanNotes = humanNotes
        self.participants = participants
        self.provider = provider
        self.durationSeconds = durationSeconds
        self.wantsTitle = wantsTitle
        self.wantsDescription = wantsDescription
        self.wantsSummary = wantsSummary
        self.wantsNotes = wantsNotes
    }
}

public struct SpeakerResolutionRequest: Sendable {
    /// Anonymous transcript with namespaced labels.
    public var transcript: String
    public var labels: [String]
    public var humanContext: String?
    public var calendarAttendees: [String]
    public var browserParticipants: [String]
    public var localUserName: String?

    public init(
        transcript: String, labels: [String], humanContext: String?,
        calendarAttendees: [String], browserParticipants: [String], localUserName: String?
    ) {
        self.transcript = transcript
        self.labels = labels
        self.humanContext = humanContext
        self.calendarAttendees = calendarAttendees
        self.browserParticipants = browserParticipants
        self.localUserName = localUserName
    }
}

/// The AI backend, behind a protocol so the pipeline can be tested without the
/// network and so a different provider can be substituted later.
public protocol AIBackend: Sendable {
    /// Whether this backend has what it needs to make a request.
    ///
    /// The optional cloud stages ask before calling, because the local pipeline
    /// is the default and a user who never entered a key has not opted into
    /// anything that can fail. Without this the meeting stops at the first cloud
    /// stage and never reaches the step that writes the markdown and the mixdown.
    /// Deliberately not defaulted: a new backend that forgets to answer should
    /// fail to compile rather than claim it is ready.
    func isConfigured() async -> Bool

    func verifyCredentials(model: String) async throws
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResponse
    func diarize(_ request: DiarizationRequest) async throws -> TranscriptionResponse
    func resolveSpeakers(_ request: SpeakerResolutionRequest, model: String) async throws -> [SpeakerSuggestion]
    func enrich(_ request: EnrichmentRequest, model: String) async throws -> MeetingEnrichment
}
