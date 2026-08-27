import Foundation
import PipitCore
import PipitSpeakers

/// One unnamed voice offered as somebody, with what a reader needs to decide.
///
/// Built for the second look rather than for the first. Everything here except
/// the score answers "why was this missed, and what happens if I say yes",
/// because a match found months after the meeting has to argue for itself.
public struct VoiceRematch: Sendable, Equatable, Identifiable {
    /// The voice nobody has named.
    public var voice: Identity
    /// Who it matches now.
    public var match: Identity
    public var band: SpeakerConfidenceBand
    public var score: Double
    public var runnerUpScore: Double?
    /// Clean speech behind the unnamed voice's profile.
    public var speechSeconds: Double
    /// The meetings it was heard in, newest first.
    public var heardIn: [PersonAppearance]
    /// When this voice is forgotten. Nil once it has been heard twice, which is
    /// what makes an unnamed voice persistent.
    public var forgottenAt: Date?
    /// When the match's voice profile begins. A meeting processed before this
    /// date had nothing to match against, which is the usual reason the first
    /// pass left the voice a number.
    public var matchProfileBegan: Date?

    public var id: IdentityID { voice.id }

    public init(
        voice: Identity, match: Identity, band: SpeakerConfidenceBand, score: Double,
        runnerUpScore: Double?, speechSeconds: Double, heardIn: [PersonAppearance],
        forgottenAt: Date?, matchProfileBegan: Date?
    ) {
        self.voice = voice
        self.match = match
        self.band = band
        self.score = score
        self.runnerUpScore = runnerUpScore
        self.speechSeconds = speechSeconds
        self.heardIn = heardIn
        self.forgottenAt = forgottenAt
        self.matchProfileBegan = matchProfileBegan
    }

    /// Whether the match's profile did not exist when this voice was last heard.
    public var profileCameLater: Bool {
        guard let began = matchProfileBegan, let heard = heardIn.first?.startedAt else {
            return false
        }
        return began > heard
    }
}

extension PipitRuntime {
    // MARK: - looking again

    /// Scores every unnamed voice against the voice profiles as they stand now.
    ///
    /// Reads only. The matches come back to be offered, and a person applies
    /// one with `confirmRematch`.
    public func rematchUnnamedVoices() async -> [VoiceRematch] {
        guard let service = speakers, let store = speakerStore else { return [] }
        do {
            let matches = try await service.rematchUnnamedVoices()
            let expiryDays = await service.resolutionPolicy.ephemeralExpiryDays
            var rows: [VoiceRematch] = []
            for match in matches {
                let heardIn = await appearances(of: match.voice.id, limit: 3)
                rows.append(VoiceRematch(
                    voice: match.voice,
                    match: match.match,
                    band: match.resolution.band,
                    score: match.resolution.best?.score ?? 0,
                    runnerUpScore: match.resolution.runnerUp?.score,
                    speechSeconds: match.speechSeconds,
                    heardIn: heardIn,
                    // Only a voice heard once is on a clock. Hearing it again is
                    // what makes it persistent, and a persistent voice is kept.
                    forgottenAt: match.voice.state == .ephemeral
                        ? (match.voice.lastSeenAt ?? match.voice.createdAt)
                            .addingTimeInterval(Double(expiryDays) * 86_400)
                        : nil,
                    matchProfileBegan: try? await store.firstEnrolment(of: match.match.id)
                ))
            }
            Log.app.info("re-scored unnamed voices: \(rows.count, privacy: .public) matched")
            // Most certain first. A reader works down the list and stops when
            // the rows stop being obvious.
            return rows.sorted { $0.score > $1.score }
        } catch {
            Log.app.error("re-score failed: \(logSafeDescription(error), privacy: .public)")
            return []
        }
    }

    /// Applies one match: the voice becomes that person, everywhere it was
    /// heard.
    ///
    /// Not offered with an undo. Confirmation retracts the provisional seed
    /// this voice was remembered from and re-enrols that audio under the person,
    /// which is right and is not reversible: unmerging afterwards would hand
    /// back an identity with no voice behind it. A wrong answer is corrected
    /// the way every other wrong name is, by retyping it on the meeting.
    public func confirmRematch(_ rematch: VoiceRematch) async {
        do {
            try await pipeline.applyRematch(
                voice: rematch.voice.id, into: rematch.match.id,
                named: rematch.match.resolvedName
            )
            refreshRecentMeetings()
        } catch {
            Log.app.error("match not applied: \(logSafeDescription(error), privacy: .public)")
        }
    }
}
