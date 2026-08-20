import Foundation
import Synchronization
import MeetTapeAudio
import MeetTapeCore
import MeetTapeIntegrations
import MeetTapeLocalAI
import MeetTapeSpeakers

/// Which backends a meeting runs through, resolved per meeting from settings.
///
/// Transcription and diarization are chosen independently, and neither is tied
/// to enrichment. Speaker memory is local in every combination: the store never
/// moves, and a cloud diarizer's labels are embedded on this Mac so choosing it
/// costs the vectors rather than the voice memory.
public struct ProcessingBackends: Sendable {
    public var transcription: @Sendable (AppSettings, String) -> any TranscriptionBackend
    public var diarization: @Sendable (AppSettings, String) -> any DiarizationBackend
    /// Puts speaker vectors back when the diarizer did not return them.
    public var embeddings: (any SpeakerEmbeddingExtractor)?
    public var speakers: SpeakerRecognitionService?
    /// Called before a local stage runs, so a meeting queued while the models
    /// are still downloading waits instead of failing.
    public var prepareLocalModels: (@Sendable () async throws -> Void)?
    /// Called before work that happens because voice memory is on rather than
    /// because the user chose a local backend. Waits for an install already
    /// running and refuses rather than starting one, so a cloud-only setup never
    /// downloads models it was not asked for.
    public var requireLocalModels: (@Sendable () async throws -> Void)?
    /// Extracts one vector for a track known to hold a single speaker, used for
    /// the microphone track where the speaker is the local user by construction.
    public var singleSpeakerEmbedding: (@Sendable (URL) async throws -> (vector: [Float], speechSeconds: Double, quality: Double)?)?
    /// Re-clusters one meeting, reusing the prepared state from its first pass
    /// where that is still in memory. Absent when local diarization is not
    /// available, which is what makes the re-analysis control unavailable too.
    public var reanalyzeDiarization: (@Sendable (String, URL, Int?) async throws -> DiarizationOutput)?

    public init(
        transcription: @escaping @Sendable (AppSettings, String) -> any TranscriptionBackend,
        diarization: @escaping @Sendable (AppSettings, String) -> any DiarizationBackend,
        embeddings: (any SpeakerEmbeddingExtractor)? = nil,
        speakers: SpeakerRecognitionService? = nil,
        prepareLocalModels: (@Sendable () async throws -> Void)? = nil,
        requireLocalModels: (@Sendable () async throws -> Void)? = nil,
        singleSpeakerEmbedding: (@Sendable (URL) async throws -> (vector: [Float], speechSeconds: Double, quality: Double)?)? = nil,
        reanalyzeDiarization: (@Sendable (String, URL, Int?) async throws -> DiarizationOutput)? = nil
    ) {
        self.transcription = transcription
        self.diarization = diarization
        self.embeddings = embeddings
        self.speakers = speakers
        self.prepareLocalModels = prepareLocalModels
        self.requireLocalModels = requireLocalModels
        self.singleSpeakerEmbedding = singleSpeakerEmbedding
        self.reanalyzeDiarization = reanalyzeDiarization
    }

    /// Cloud only, which is what the pipeline did before local processing
    /// existed. Used by tests that have no interest in speakers.
    public static func openAIOnly(_ backend: any AIBackend) -> ProcessingBackends {
        ProcessingBackends(
            transcription: { _, model in OpenAITranscriptionBackend(backend: backend, model: model) },
            diarization: { _, model in OpenAIDiarizationBackend(backend: backend, model: model) }
        )
    }
}

/// Decides when a heavy processing stage may start.
///
/// Capture reliability outranks processing latency in every case, so a job waits
/// here rather than competing with a live recording. The cost is a few minutes
/// of delay on a job that takes about four.
public protocol ProcessingGate: Sendable {
    /// Returns once heavy work is allowed to begin.
    func waitUntilAllowed() async
    /// Whether work would have to wait right now.
    var isBlocked: Bool { get }
}

/// The gate a test uses, and the one a cloud-only configuration needs: nothing
/// is ever held back.
public struct AlwaysAllowed: ProcessingGate {
    public init() {}
    public func waitUntilAllowed() async {}
    public var isBlocked: Bool { false }
}

/// Holds processing while a meeting is being recorded.
///
/// Polls rather than signals because the recording state lives on the main
/// actor and the pipeline does not: a shared box read on a timer keeps the two
/// apart, and a two-second granularity on a job measured in minutes costs
/// nothing.
public struct RecordingAwareGate: ProcessingGate {
    private let isRecording: @Sendable () -> Bool
    private let pollSeconds: Double

    public init(pollSeconds: Double = 2, isRecording: @escaping @Sendable () -> Bool) {
        self.isRecording = isRecording
        self.pollSeconds = pollSeconds
    }

    public var isBlocked: Bool { isRecording() }

    public func waitUntilAllowed() async {
        while isRecording() {
            try? await Task.sleep(nanoseconds: UInt64(pollSeconds * 1_000_000_000))
            if Task.isCancelled { return }
        }
    }
}

/// One heavy job at a time, in the order they arrived.
///
/// Transcription is 92% of processing time and both local libraries target the
/// Neural Engine, so running two meetings at once contends for one unit and
/// wins nothing. Diarization costs 16 seconds against transcription's 249 on a
/// 65-minute file; there is no second job worth starting.
public final class ProcessingJobLock: Sendable {
    private struct State {
        var busy = false
        var waiting: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    public init() {}

    public func acquire() async {
        let taken = state.withLock { state -> Bool in
            guard !state.busy else { return false }
            state.busy = true
            return true
        }
        if taken { return }
        await withCheckedContinuation { continuation in
            // The slot can be released between the check above and here, so the
            // decision is made once more under the lock rather than assumed.
            let free = state.withLock { state -> Bool in
                guard !state.busy else {
                    state.waiting.append(continuation)
                    return false
                }
                state.busy = true
                return true
            }
            if free { continuation.resume() }
        }
    }

    /// Synchronous on purpose, so a caller can hand the slot back in a `defer`
    /// without leaving a task to do it later, and so the next holder starts
    /// immediately rather than at the next scheduling point.
    public func release() {
        let next = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard !state.waiting.isEmpty else {
                state.busy = false
                return nil
            }
            return state.waiting.removeFirst()
        }
        next?.resume()
    }
}

/// Decoded track audio for one meeting, kept out of the archive.
///
/// The archive holds source segments; these are 16 kHz mono working copies the
/// local models read. They live in Caches, are derived from audio that is never
/// modified, and are deleted when the meeting finishes.
public struct ProcessingScratch: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public static func defaultRoot() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appendingPathComponent("MeetTape/processing", isDirectory: true)
    }

    public func directory(for meetingID: String) -> URL {
        root.appendingPathComponent(
            MeetingArchiveLayout.slugify(meetingID, maxLength: 96), isDirectory: true
        )
    }

    /// The whole track as one 16 kHz mono file, exported once and reused by
    /// every stage that needs it.
    public func trackAudio(
        meetingID: String, track: CaptureTrack, segments: [RecordedSegment], segmentsDirectory: URL
    ) throws -> URL? {
        guard !segments.isEmpty else { return nil }
        let directory = directory(for: meetingID)
        let destination = directory.appendingPathComponent("\(track.rawValue).wav")
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let frames = try TrackFileExporter().export(
            segments: segments, segmentsDirectory: segmentsDirectory, to: destination
        )
        guard frames > 0 else {
            try? FileManager.default.removeItem(at: destination)
            return nil
        }
        return destination
    }

    public func discard(meetingID: String) {
        try? FileManager.default.removeItem(at: directory(for: meetingID))
    }
}
