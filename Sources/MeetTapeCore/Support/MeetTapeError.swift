import Foundation

/// Capture-side failures. These are distinguished on purpose: silence and an idle
/// remote application are normal, a rebuild in flight is temporary, and only the
/// last two categories mean audio is being lost right now.
public enum CaptureError: LogSafeError, Equatable {
    case microphonePermissionDenied
    case microphoneEngineStartFailed(status: Int32)
    case noMatchingAudioProcess(prefixes: [String])
    case processTapCreationFailed(status: Int32)
    case aggregateDeviceCreationFailed(status: Int32)
    case ioProcCreationFailed(status: Int32)
    case tapFormatUnavailable
    case segmentWriteFailed(path: String, underlying: String)
    case storageUnavailable(path: String)

    public var logSafeDescription: String {
        switch self {
        case .microphonePermissionDenied: "microphonePermissionDenied"
        case .microphoneEngineStartFailed(let status): "microphoneEngineStartFailed(\(status))"
        case .noMatchingAudioProcess(let prefixes): "noMatchingAudioProcess(\(prefixes.count) prefixes)"
        case .processTapCreationFailed(let status): "processTapCreationFailed(\(status))"
        case .aggregateDeviceCreationFailed(let status): "aggregateDeviceCreationFailed(\(status))"
        case .ioProcCreationFailed(let status): "ioProcCreationFailed(\(status))"
        case .tapFormatUnavailable: "tapFormatUnavailable"
        case .segmentWriteFailed: "segmentWriteFailed"
        case .storageUnavailable: "storageUnavailable"
        }
    }
}

/// Storage failures. Paths are included because they are MeetTape's own directory
/// layout, not meeting content.
public enum StorageError: LogSafeError, Equatable {
    case directoryCreationFailed(path: String, underlying: String)
    case fileWriteFailed(path: String, underlying: String)
    case fileReadFailed(path: String, underlying: String)
    case decodeFailed(path: String, underlying: String)
    case meetingNotFound(id: String)

    /// Paths are omitted: a meeting directory's name embeds the meeting title,
    /// and the unified log is collected wholesale by sysdiagnose.
    public var logSafeDescription: String {
        switch self {
        case .directoryCreationFailed: "directoryCreationFailed"
        case .fileWriteFailed: "fileWriteFailed"
        case .fileReadFailed: "fileReadFailed"
        case .decodeFailed: "decodeFailed"
        case .meetingNotFound: "meetingNotFound"
        }
    }
}

/// Failures from the AI backend. `retryable` drives the processing state machine:
/// a retryable failure keeps the job alive, a permanent one stops the retry loop
/// but never touches the source audio.
public enum ProcessingError: LogSafeError, Equatable {
    case missingAPIKey
    case authenticationFailed
    case rateLimited(retryAfter: TimeInterval?)
    case serverError(status: Int)
    case requestTooLarge(bytes: Int, limit: Int)
    case durationTooLong(seconds: Double, limit: Double)
    case malformedResponse(reason: String)
    case transport(reason: String)
    case audioUnreadable(path: String)
    /// A correction arrived for a transcript line that no longer exists,
    /// which happens when a re-analysis lands between the click and the write.
    case utteranceNotFound(id: String)
    case cancelled

    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .serverError, .transport: true
        case .missingAPIKey, .authenticationFailed, .requestTooLarge, .durationTooLong,
             .malformedResponse, .audioUnreadable, .utteranceNotFound, .cancelled: false
        }
    }

    public var logSafeDescription: String {
        switch self {
        case .missingAPIKey: "missingAPIKey"
        case .authenticationFailed: "authenticationFailed"
        case .rateLimited(let after): "rateLimited(retryAfter: \(after.map { String(format: "%.0f", $0) } ?? "-"))"
        case .serverError(let status): "serverError(\(status))"
        case .requestTooLarge(let bytes, let limit): "requestTooLarge(\(bytes)/\(limit))"
        case .durationTooLong(let seconds, let limit): "durationTooLong(\(Int(seconds))/\(Int(limit)))"
        case .malformedResponse(let reason): "malformedResponse(\(reason))"
        case .transport(let reason): "transport(\(reason))"
        case .audioUnreadable(let path): "audioUnreadable(\(path))"
        case .utteranceNotFound: "utteranceNotFound"
        case .cancelled: "cancelled"
        }
    }

    /// The message shown to the user. Every one of these reassures about the audio,
    /// because the recording is safe in all of them.
    public var userMessage: String {
        switch self {
        case .missingAPIKey: "Add an OpenAI API key in Settings to transcribe this meeting. Your recording is safe."
        case .authenticationFailed: "OpenAI rejected the API key. Your recording is safe."
        case .rateLimited: "OpenAI is rate limiting requests. MeetTape will retry. Your recording is safe."
        case .serverError: "OpenAI returned a server error. MeetTape will retry. Your recording is safe."
        case .requestTooLarge: "An audio chunk exceeded the OpenAI upload limit. Your recording is safe."
        case .durationTooLong: "An audio chunk exceeded the OpenAI duration limit. Your recording is safe."
        case .malformedResponse: "OpenAI returned an unexpected response. Your recording is safe."
        case .transport: "MeetTape could not reach OpenAI. It will retry. Your recording is safe."
        case .audioUnreadable: "MeetTape could not read the recorded audio for this stage."
        case .utteranceNotFound:
            "That line has moved since the transcript was last analysed. Reopen the meeting and try again."
        case .cancelled: "Processing was cancelled. Your recording is safe."
        }
    }
}
