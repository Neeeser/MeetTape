import Foundation

/// The durable processing state machine. Each transition is written to disk before
/// the next stage starts, so an interrupted run resumes where it stopped.
///
/// `audioSafe` is the boundary that matters: nothing touches OpenAI before it, and
/// every stage after it is retryable without risking the recording.
public enum ProcessingState: String, Codable, Sendable, CaseIterable, Comparable {
    case recording
    case finalizing
    case audioSafe = "audio_safe"
    case transcribing
    case diarizing
    case resolvingSpeakers = "resolving_speakers"
    case enriching
    case complete
    case failed

    private var order: Int {
        switch self {
        case .recording: 0
        case .finalizing: 1
        case .audioSafe: 2
        case .transcribing: 3
        case .diarizing: 4
        case .resolvingSpeakers: 5
        case .enriching: 6
        case .complete: 7
        case .failed: 8
        }
    }

    public static func < (lhs: ProcessingState, rhs: ProcessingState) -> Bool {
        lhs.order < rhs.order
    }

    /// True once the source audio and its manifest are durable.
    public var isAudioSafe: Bool {
        switch self {
        case .recording, .finalizing: false
        case .audioSafe, .transcribing, .diarizing, .resolvingSpeakers, .enriching, .complete, .failed: true
        }
    }

    public var isTerminal: Bool { self == .complete }

    /// The stage that runs next when this one succeeds.
    public var next: ProcessingState? {
        switch self {
        case .recording: .finalizing
        case .finalizing: .audioSafe
        case .audioSafe: .transcribing
        case .transcribing: .diarizing
        case .diarizing: .resolvingSpeakers
        case .resolvingSpeakers: .enriching
        case .enriching: .complete
        case .complete, .failed: nil
        }
    }

    public var displayName: String {
        switch self {
        case .recording: "Recording"
        case .finalizing: "Finalizing"
        case .audioSafe: "Saved"
        case .transcribing: "Transcribing"
        case .diarizing: "Identifying speakers"
        case .resolvingSpeakers: "Matching names"
        case .enriching: "Writing notes"
        case .complete: "Complete"
        case .failed: "Needs attention"
        }
    }
}

public struct ProcessingFailure: Codable, Sendable, Equatable {
    public var stage: ProcessingState
    public var message: String
    public var isRetryable: Bool
    public var occurredAt: Date

    public init(stage: ProcessingState, message: String, isRetryable: Bool, occurredAt: Date) {
        self.stage = stage
        self.message = message
        self.isRetryable = isRetryable
        self.occurredAt = occurredAt
    }
}

/// Persisted processing status for one meeting.
public struct ProcessingStatus: Codable, Sendable, Equatable {
    public var state: ProcessingState
    public var updatedAt: Date
    /// Stage name to attempt count, so a retry loop is visible and boundable.
    public var attempts: [String: Int]
    public var lastFailure: ProcessingFailure?
    /// Stages that finished successfully. A resumed run skips these.
    public var completedStages: [ProcessingState]
    /// The stage that failed, kept so `failed` knows where to resume from.
    public var failedStage: ProcessingState?

    public init(
        state: ProcessingState = .recording,
        updatedAt: Date = Date(),
        attempts: [String: Int] = [:],
        lastFailure: ProcessingFailure? = nil,
        completedStages: [ProcessingState] = [],
        failedStage: ProcessingState? = nil
    ) {
        self.state = state
        self.updatedAt = updatedAt
        self.attempts = attempts
        self.lastFailure = lastFailure
        self.completedStages = completedStages
        self.failedStage = failedStage
    }

    public func hasCompleted(_ stage: ProcessingState) -> Bool {
        completedStages.contains(stage)
    }

    public func attemptCount(for stage: ProcessingState) -> Int {
        attempts[stage.rawValue] ?? 0
    }

    /// The stage a resumed run should start from. A failed job resumes at the stage
    /// that failed; source audio is never revisited.
    public var resumeStage: ProcessingState? {
        if state == .complete { return nil }
        if state == .failed { return failedStage ?? .audioSafe }
        return state
    }

    public mutating func advance(to stage: ProcessingState, at date: Date) {
        if let current = state.next, current == stage || stage == .complete {
            if !completedStages.contains(state), state != .failed { completedStages.append(state) }
        }
        state = stage
        updatedAt = date
        if stage != .failed {
            lastFailure = nil
            failedStage = nil
        }
    }

    public mutating func recordAttempt(for stage: ProcessingState) {
        attempts[stage.rawValue, default: 0] += 1
    }

    public mutating func recordFailure(_ failure: ProcessingFailure, at date: Date) {
        state = .failed
        failedStage = failure.stage
        lastFailure = failure
        updatedAt = date
    }
}
