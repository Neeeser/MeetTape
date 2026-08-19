import Foundation

/// What the user is shown about an automatic identification.
///
/// Bands rather than a percentage. A cosine similarity of 0.92 is not a 92%
/// probability: genuine scores occupy 0.72 to 0.96 and impostor scores 0.00 to
/// 0.96, and no calibration in the measurements supports reading one as the
/// other.
public enum SpeakerConfidenceBand: String, Codable, Sendable, CaseIterable {
    /// Named automatically.
    case high
    /// Offered for confirmation and never written anywhere on its own.
    case medium
    case unknown

    public var displayName: String {
        switch self {
        case .high: "High"
        case .medium: "Likely"
        case .unknown: "Unknown"
        }
    }
}

/// One identity scored against a speaker occurrence.
public struct SpeakerCandidate: Sendable, Equatable, Codable {
    public var identityID: IdentityID
    public var kind: IdentityKind
    public var displayName: String
    public var score: Double
    /// The user listed this identity as expected in this meeting. A soft prior
    /// only: it relaxes the margin requirement and nothing else.
    public var isExpectedParticipant: Bool

    public init(
        identityID: IdentityID, kind: IdentityKind, displayName: String,
        score: Double, isExpectedParticipant: Bool = false
    ) {
        self.identityID = identityID
        self.kind = kind
        self.displayName = displayName
        self.score = score
        self.isExpectedParticipant = isExpectedParticipant
    }
}

/// The thresholds, in one place.
///
/// Every value here comes from a measurement recorded in the speaker-scale
/// probe. They are gathered into one struct so a change is a change to one
/// value, and so tests can assert on the shipping numbers rather than on
/// literals scattered through the call sites.
public struct SpeakerResolutionPolicy: Sendable, Equatable, Codable {
    // Named people.

    /// Auto-naming needs all three of score, margin and duration. Over a
    /// 326-speaker gallery this produced zero wrong automatic names at 97.9%
    /// recall. Score alone does not: the worst impostor there reached 0.957,
    /// above the true speaker's own 0.951.
    public var namedHighScore: Double
    public var namedHighMargin: Double
    public var namedHighSpeechSeconds: Double
    /// Relaxed margin for someone the user listed as present. Reasoned from the
    /// open-set results rather than measured directly, so it is kept as its own
    /// value and is easy to raise back to `namedHighMargin`.
    public var expectedParticipantMargin: Double

    /// Suggestion band. Below this score the number carries no information:
    /// genuine matches at 9 seconds of speech have a 5th percentile of 0.59.
    public var mediumScore: Double
    public var mediumSpeechSeconds: Double

    // Recurring unnamed voices. Stricter, because the false-link rate for a
    // genuinely new voice grows with pool size where named matching does not,
    // and because a wrong anonymous merge corrupts a profile no human has ever
    // looked at.
    public var anonymousLinkScore: Double
    public var anonymousLinkMargin: Double
    public var anonymousLinkSpeechSeconds: Double
    public var anonymousSuggestScore: Double
    public var anonymousSuggestSpeechSeconds: Double

    /// Below this, the identity is Unknown whatever it scored. At 9 seconds of
    /// speech the 1st percentile of genuine scores is 0.282.
    public var hardUnknownSpeechSeconds: Double

    /// Clean speech needed before an embedding may enter a profile, and before
    /// an unnamed voice is worth remembering at all.
    public var enrolmentSpeechSeconds: Double

    /// Retained embeddings per identity. Separation is flat beyond about five
    /// confirmed recordings, so the cap costs nothing and bounds the store.
    public var maximumEmbeddingsPerIdentity: Int

    /// An unnamed voice heard once and never again is forgotten after this.
    public var ephemeralExpiryDays: Int

    /// How many candidates to offer in the suggestion band.
    public var maximumSuggestions: Int

    public init(
        namedHighScore: Double = 0.70,
        namedHighMargin: Double = 0.10,
        namedHighSpeechSeconds: Double = 45,
        expectedParticipantMargin: Double = 0.05,
        mediumScore: Double = 0.55,
        mediumSpeechSeconds: Double = 10,
        anonymousLinkScore: Double = 0.75,
        anonymousLinkMargin: Double = 0.10,
        anonymousLinkSpeechSeconds: Double = 45,
        anonymousSuggestScore: Double = 0.65,
        anonymousSuggestSpeechSeconds: Double = 20,
        hardUnknownSpeechSeconds: Double = 10,
        enrolmentSpeechSeconds: Double = 45,
        maximumEmbeddingsPerIdentity: Int = 20,
        ephemeralExpiryDays: Int = 90,
        maximumSuggestions: Int = 3
    ) {
        self.namedHighScore = namedHighScore
        self.namedHighMargin = namedHighMargin
        self.namedHighSpeechSeconds = namedHighSpeechSeconds
        self.expectedParticipantMargin = expectedParticipantMargin
        self.mediumScore = mediumScore
        self.mediumSpeechSeconds = mediumSpeechSeconds
        self.anonymousLinkScore = anonymousLinkScore
        self.anonymousLinkMargin = anonymousLinkMargin
        self.anonymousLinkSpeechSeconds = anonymousLinkSpeechSeconds
        self.anonymousSuggestScore = anonymousSuggestScore
        self.anonymousSuggestSpeechSeconds = anonymousSuggestSpeechSeconds
        self.hardUnknownSpeechSeconds = hardUnknownSpeechSeconds
        self.enrolmentSpeechSeconds = enrolmentSpeechSeconds
        self.maximumEmbeddingsPerIdentity = maximumEmbeddingsPerIdentity
        self.ephemeralExpiryDays = ephemeralExpiryDays
        self.maximumSuggestions = maximumSuggestions
    }

    public static let shipping = SpeakerResolutionPolicy()
}

/// What resolving one occurrence against the gallery concluded.
public struct SpeakerResolution: Sendable, Equatable, Codable {
    public enum Outcome: Sendable, Equatable, Codable {
        /// Display this person's name.
        case assign(IdentityID)
        /// A voice heard before that still has no name.
        case seenBefore(IdentityID)
        /// Offer `suggestions` and wait for the user.
        case suggest
        case unknown

        public var identityID: IdentityID? {
            switch self {
            case .assign(let id), .seenBefore(let id): id
            case .suggest, .unknown: nil
            }
        }

        public var isAutomatic: Bool {
            switch self {
            case .assign, .seenBefore: true
            case .suggest, .unknown: false
            }
        }
    }

    public var outcome: Outcome
    public var band: SpeakerConfidenceBand
    public var best: SpeakerCandidate?
    public var runnerUp: SpeakerCandidate?
    public var margin: Double?
    /// Candidates worth putting in front of the user, best first. Empty unless
    /// the band is medium.
    public var suggestions: [SpeakerCandidate]
    public var speechSeconds: Double

    public init(
        outcome: Outcome, band: SpeakerConfidenceBand, best: SpeakerCandidate?,
        runnerUp: SpeakerCandidate?, margin: Double?, suggestions: [SpeakerCandidate],
        speechSeconds: Double
    ) {
        self.outcome = outcome
        self.band = band
        self.best = best
        self.runnerUp = runnerUp
        self.margin = margin
        self.suggestions = suggestions
        self.speechSeconds = speechSeconds
    }

    public static func unknown(speechSeconds: Double) -> SpeakerResolution {
        SpeakerResolution(
            outcome: .unknown, band: .unknown, best: nil, runnerUp: nil,
            margin: nil, suggestions: [], speechSeconds: speechSeconds
        )
    }
}

extension SpeakerResolutionPolicy {
    /// Decides what one speaker occurrence is, from its scored candidates.
    ///
    /// Only the top-ranked candidate can ever be named automatically. That is
    /// what the margin means: if a different identity scores higher, naming the
    /// runner-up would be naming someone the audio matches less well.
    public func resolve(
        candidates: [SpeakerCandidate], speechSeconds: Double
    ) -> SpeakerResolution {
        let ranked = candidates.sorted { $0.score > $1.score }
        guard let best = ranked.first else { return .unknown(speechSeconds: speechSeconds) }
        let runnerUp = ranked.dropFirst().first
        let margin = best.score - (runnerUp?.score ?? 0)

        // Too little speech to trust any score. The best match is still carried
        // so the reason for the decision can be shown.
        guard speechSeconds >= hardUnknownSpeechSeconds else {
            return SpeakerResolution(
                outcome: .unknown, band: .unknown, best: best, runnerUp: runnerUp,
                margin: margin, suggestions: [], speechSeconds: speechSeconds
            )
        }

        switch best.kind {
        case .person:
            let requiredMargin = best.isExpectedParticipant ? expectedParticipantMargin : namedHighMargin
            if best.score >= namedHighScore, margin >= requiredMargin,
               speechSeconds >= namedHighSpeechSeconds {
                return SpeakerResolution(
                    outcome: .assign(best.identityID), band: .high, best: best,
                    runnerUp: runnerUp, margin: margin, suggestions: [],
                    speechSeconds: speechSeconds
                )
            }
        case .anonymous:
            if best.score >= anonymousLinkScore, margin >= anonymousLinkMargin,
               speechSeconds >= anonymousLinkSpeechSeconds {
                return SpeakerResolution(
                    outcome: .seenBefore(best.identityID), band: .high, best: best,
                    runnerUp: runnerUp, margin: margin, suggestions: [],
                    speechSeconds: speechSeconds
                )
            }
        }

        let suggestions = Array(
            ranked.filter { isSuggestable($0, speechSeconds: speechSeconds) }
                .prefix(maximumSuggestions)
        )
        guard !suggestions.isEmpty else {
            return SpeakerResolution(
                outcome: .unknown, band: .unknown, best: best, runnerUp: runnerUp,
                margin: margin, suggestions: [], speechSeconds: speechSeconds
            )
        }
        return SpeakerResolution(
            outcome: .suggest, band: .medium, best: best, runnerUp: runnerUp,
            margin: margin, suggestions: suggestions, speechSeconds: speechSeconds
        )
    }

    private func isSuggestable(_ candidate: SpeakerCandidate, speechSeconds: Double) -> Bool {
        switch candidate.kind {
        case .person:
            candidate.score >= mediumScore && speechSeconds >= mediumSpeechSeconds
        case .anonymous:
            candidate.score >= anonymousSuggestScore && speechSeconds >= anonymousSuggestSpeechSeconds
        }
    }

    /// Whether a cluster holds enough speech for its centroid to be remembered
    /// as a recurring voice.
    public func qualifiesForAnonymousProfile(speechSeconds: Double) -> Bool {
        speechSeconds >= enrolmentSpeechSeconds
    }

    /// Whether accumulated human-confirmed speech is enough to enrol.
    public func qualifiesForEnrolment(speechSeconds: Double) -> Bool {
        speechSeconds >= enrolmentSpeechSeconds
    }
}
