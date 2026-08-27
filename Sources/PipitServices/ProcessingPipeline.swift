import AVFoundation
import Foundation
import PipitAudio
import PipitCore
import PipitIntegrations
import PipitSpeakers

/// Runs a meeting through transcription, diarization, speaker resolution and
/// enrichment.
///
/// Every stage commits its state to disk before the next begins, and every stage
/// after `audio_safe` is retryable. Until a meeting is `complete`, nothing here
/// deletes or rewrites source audio: a failure leaves the recording exactly
/// where it was and the job waiting. After `complete`, compaction replaces the
/// PCM segments with verified archive files; it never deletes the only copy.
public actor ProcessingPipeline {
    public struct Progress: Sendable, Equatable {
        public var meetingID: String
        public var state: ProcessingState
        public var completedChunks: Int
        public var totalChunks: Int
        public var title: String
        /// How far through the current stage, where the backend reports it.
        /// A local transcription has no chunks to count, and a stage showing
        /// 0 of 0 for four minutes reads as hung.
        public var fraction: Double?
        /// What is happening, for a stage whose name is not enough: waiting for
        /// a recording to finish, or downloading the models.
        public var detail: String?

        public init(
            meetingID: String, state: ProcessingState, completedChunks: Int, totalChunks: Int,
            title: String, fraction: Double? = nil, detail: String? = nil
        ) {
            self.meetingID = meetingID
            self.state = state
            self.completedChunks = completedChunks
            self.totalChunks = totalChunks
            self.title = title
            self.fraction = fraction
            self.detail = detail
        }
    }

    private let repository: MeetingRepository
    /// The cloud client. Still the only thing that writes titles, summaries and
    /// textual speaker suggestions, and still optional in every configuration.
    private let backend: any AIBackend
    private let backends: ProcessingBackends
    private let gate: any ProcessingGate
    private let scratch: ProcessingScratch
    private let clock: any Clock
    private let settingsProvider: @Sendable () -> AppSettings
    private let onProgress: @Sendable (Progress) -> Void
    private let onFailure: @Sendable (String, ProcessingError) -> Void
    private let calendar: CalendarService?
    private let wait: @Sendable (TimeInterval) async -> Void
    /// Chunk sizing, injectable so tests can exercise multi-chunk behaviour
    /// without minutes of audio.
    private let chunking: ChunkPlanner.Configuration

    private var running: Set<String> = []
    /// Meetings whose folders left the archive while a job was running.
    ///
    /// Every write here goes through `AtomicFile`, which creates the
    /// directories it needs, so a job that carried on after the move put the
    /// meeting back as a row holding no audio and no transcript.
    private var goneWhileRunning: Set<String> = []
    /// One heavy job at a time. Transcription is 92% of the work and the local
    /// models share one Neural Engine, so a second concurrent meeting takes
    /// time from the first rather than adding any.
    private let jobLock = ProcessingJobLock()

    /// How many times one stage is attempted before the meeting is left for the
    /// user, and the delays between those attempts.
    static let maxAttemptsPerStage = 3
    static let retryDelaysSeconds: [TimeInterval] = [20, 90]
    static let maxRetryDelaySeconds: TimeInterval = 300

    public init(
        repository: MeetingRepository,
        backend: any AIBackend,
        backends: ProcessingBackends? = nil,
        gate: any ProcessingGate = AlwaysAllowed(),
        scratch: ProcessingScratch = ProcessingScratch(root: ProcessingScratch.defaultRoot()),
        calendar: CalendarService? = nil,
        clock: any Clock = SystemClock(),
        settingsProvider: @escaping @Sendable () -> AppSettings,
        onProgress: @escaping @Sendable (Progress) -> Void = { _ in },
        onFailure: @escaping @Sendable (String, ProcessingError) -> Void = { _, _ in },
        wait: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        },
        chunking: ChunkPlanner.Configuration = .openAIDiarization
    ) {
        self.repository = repository
        self.backend = backend
        self.backends = backends ?? .openAIOnly(backend)
        self.gate = gate
        self.scratch = scratch
        self.calendar = calendar
        self.clock = clock
        self.settingsProvider = settingsProvider
        self.onProgress = onProgress
        self.onFailure = onFailure
        self.wait = wait
        self.chunking = chunking
    }

    /// Removes what a stage wrote into a folder that is no longer meant to
    /// exist, and says whether the job should stop.
    ///
    /// A stage already running when the meeting was trashed finishes and writes
    /// its output through `AtomicFile`, which creates the directories it needs.
    /// What it left is removed here rather than guarded at every write. Removed
    /// outright rather than trashed, because the meeting as the user had it is
    /// already whole in the Trash and this is the scrap written over the top of
    /// where it used to be.
    private func discardIfGone(_ meetingID: String, store: MeetingStore) -> Bool {
        guard goneWhileRunning.remove(meetingID) != nil else { return false }
        try? FileManager.default.removeItem(at: store.layout.root)
        scratch.discard(meetingID: meetingID)
        Log.processing.notice("meeting left the archive while it processed, so the job stopped")
        return true
    }

    /// Takes back a `forget` for a folder the move could not take. Its job
    /// carries on, because the meeting is still in the list.
    public func keep(meetingID: String) {
        goneWhileRunning.remove(meetingID)
    }

    /// Stops the job on a meeting whose folder has just been deleted.
    ///
    /// The window offers Delete as soon as the recording is over, which is
    /// minutes before transcription finishes. The job notices at its next stage
    /// boundary, removes whatever it wrote in the meantime, and stops.
    public func forget(meetingID: String) {
        guard running.contains(meetingID) else { return }
        goneWhileRunning.insert(meetingID)
    }

    /// Runs or resumes a meeting. Safe to call repeatedly; a meeting already in
    /// flight is left alone.
    public func process(meetingID: String) async {
        guard !running.contains(meetingID) else { return }
        // includingMerged, because a reconnected meeting is folded into the
        // earlier one and hidden from the archive listing while its own segments
        // are the only copy of the second half of the call. Refusing it here
        // left that audio permanently untranscribed with nothing able to retry.
        guard let found = repository.findMeeting(id: meetingID, includingMerged: true) else {
            return
        }
        running.insert(meetingID)
        await jobLock.acquire()
        var holdsSlot = true
        defer {
            running.remove(meetingID)
            // Nothing writes after this, and a flag left set would take the
            // folder out from under a later job on the same meeting.
            goneWhileRunning.remove(meetingID)
            if holdsSlot { jobLock.release() }
        }

        var metadata = found.metadata
        let store = found.store
        let settings = settingsProvider()

        while let stage = metadata.processing.resumeStage, stage != .complete {
            if discardIfGone(metadata.id, store: store) { return }
            do {
                // Capture always wins. A job started before a meeting parks here
                // between stages rather than competing for the microphone, the
                // disk and the Neural Engine with a live recording.
                //
                // The slot is handed back while waiting: one heavy job at a time
                // should mean one job doing work, not one job holding the queue
                // shut for the length of somebody's call.
                // Looped, not two sequential checks. Acquiring the slot can wait
                // out another meeting's transcription, and a recording started
                // in that time made the gate reading stale: the job resumed and
                // ran a Whisper pass on the Neural Engine alongside a live call.
                // Re-check after every wait, both of which can be long.
                while true {
                    if gate.isBlocked {
                        report(metadata, chunks: nil, detail: "Waiting until recording finishes")
                        if holdsSlot {
                            jobLock.release()
                            holdsSlot = false
                        }
                        await gate.waitUntilAllowed()
                    }
                    if !holdsSlot {
                        await jobLock.acquire()
                        holdsSlot = true
                    }
                    if !gate.isBlocked { break }
                }
                // The wait above runs for the length of somebody else's call,
                // which is long enough for the user to trash this meeting.
                // Without this the job ran a whole transcription pass on it and
                // reported progress for a folder that was already gone.
                if discardIfGone(metadata.id, store: store) { return }
                metadata.processing.recordAttempt(for: stage)
                try persist(metadata, to: store)
                report(metadata, chunks: nil)

                switch stage {
                case .recording, .finalizing:
                    // Reaching here means finalization never completed; recovery
                    // owns that path, so nothing is done to the audio.
                    metadata.processing.advance(to: .audioSafe, at: clock.now)
                case .audioSafe:
                    metadata.processing.advance(to: .transcribing, at: clock.now)
                case .transcribing:
                    try await runTranscription(store: store, metadata: &metadata, settings: settings)
                    metadata.processing.advance(to: .diarizing, at: clock.now)
                case .diarizing:
                    try await runDiarization(store: store, metadata: &metadata, settings: settings)
                    metadata.processing.advance(to: .resolvingSpeakers, at: clock.now)
                case .resolvingSpeakers:
                    try await runSpeakerResolution(store: store, metadata: &metadata, settings: settings)
                    metadata.processing.advance(to: .enriching, at: clock.now)
                case .enriching:
                    // Enrichment is the one part that needs the cloud, and it is
                    // not what makes a meeting readable. Failing it used to take
                    // finish() with it, so a lost connection at the end of a call
                    // left no transcript.md and no mixdown, recoverable only
                    // through Rebuild Transcript for the first and not at all for
                    // the second. The words are already on disk; the archive gets
                    // written either way and the failure is still reported.
                    var enrichmentFailure: (any Error)?
                    do {
                        try await runEnrichment(store: store, metadata: &metadata, settings: settings)
                    } catch {
                        enrichmentFailure = error
                    }
                    try await finish(store: store, metadata: &metadata, settings: settings)
                    if let enrichmentFailure { throw enrichmentFailure }
                    metadata.processing.advance(to: .complete, at: clock.now)
                    // The decoded working copies are derived from audio that is
                    // never modified, so they are thrown away as soon as the
                    // meeting stops needing them.
                    scratch.discard(meetingID: metadata.id)
                case .complete, .failed:
                    break
                }
                try persist(metadata, to: store)
                report(metadata, chunks: nil)
            } catch {
                let failure = Self.processingError(from: error)
                metadata.processing.recordFailure(
                    ProcessingFailure(
                        stage: stage,
                        message: failure.userMessage,
                        isRetryable: failure.isRetryable,
                        occurredAt: clock.now
                    ),
                    at: clock.now
                )
                try? persist(metadata, to: store)
                Log.processing.error(
                    "stage \(stage.rawValue, privacy: .public) failed: \(failure.logSafeDescription, privacy: .public)"
                )
                report(metadata, chunks: nil)

                // A rate limit or a server error usually clears on its own, and the
                // failure message tells the user Pipit will try again. Attempts
                // are bounded so a persistent outage stops asking.
                let attempts = metadata.processing.attemptCount(for: stage)
                if failure.isRetryable, attempts < Self.maxAttemptsPerStage {
                    // The slot goes back first. A rate limit can ask for five
                    // minutes, and holding the one heavy-job slot through it
                    // kept a meeting that had just finished recording waiting
                    // on a job that was doing nothing at all.
                    if holdsSlot {
                        jobLock.release()
                        holdsSlot = false
                    }
                    await wait(retryDelay(after: failure, attempt: attempts))
                    metadata.processing.advance(to: stage, at: clock.now)
                    continue
                }
                onFailure(metadata.id, failure)
                // Nothing else will read the decoded working copies now.
                scratch.discard(meetingID: metadata.id)
                _ = discardIfGone(metadata.id, store: store)
                return
            }
        }
        // The last stage advances to complete, which ends the loop without
        // coming back to the check at the top of it.
        if discardIfGone(metadata.id, store: store) { return }

        // Compaction runs strictly after `complete`: every model has read the
        // PCM at full fidelity by now. A failure leaves the segments as the
        // source and the startup sweep retries; it never fails the meeting.
        // The gate is re-checked the way every stage checks it: a recording
        // that started during enrichment must not share the disk with a
        // transcode and a bulk delete.
        if metadata.processing.state == .complete,
           AudioCompactor.hasWork(store: store, metadata: metadata) {
            while gate.isBlocked {
                report(metadata, chunks: nil, detail: "Waiting until recording finishes")
                if holdsSlot {
                    jobLock.release()
                    holdsSlot = false
                }
                await gate.waitUntilAllowed()
                if !holdsSlot {
                    await jobLock.acquire()
                    holdsSlot = true
                }
            }
            // The gate wait above is as long as another call, so the move can
            // land before the transcode even starts.
            if discardIfGone(metadata.id, store: store) { return }
            await compactQuietly(store: store)
            // Compaction is minutes of transcoding on a long meeting, and it
            // writes the archives through AtomicFile like everything else, so
            // a move landing inside it recreated the folder holding nothing but
            // audio.
            _ = discardIfGone(metadata.id, store: store)
        }
    }

    /// Replaces a finished meeting's PCM segments with verified archives.
    /// Public entry for the startup sweep; `process` compacts inline.
    public func compactAudio(meetingID: String) async {
        guard let found = repository.findMeeting(id: meetingID, includingMerged: true) else { return }
        guard AudioCompactor.hasWork(store: found.store, metadata: found.metadata) else { return }
        await waitForSlot()
        defer { jobLock.release() }
        await compactQuietly(store: found.store)
    }

    /// Compacts every finished meeting that still has PCM audio, one at a
    /// time. Folded continuations are enumerated explicitly: the archive
    /// listing hides them, but their folders hold the only copy of the second
    /// half of a dropped call.
    public func compactPending() async {
        var candidates = repository.listMeetings()
            .filter { $0.processingState == .complete }
            .map(\.id)
        candidates.append(contentsOf: repository.mergedMeetingIDs())
        for meetingID in candidates {
            await compactAudio(meetingID: meetingID)
        }
    }

    /// The transcode is minutes of synchronous CPU work for a long meeting, so
    /// it runs detached rather than on this actor's executor: the job slot is
    /// already held, and the actor must stay free to answer a rename or a line
    /// correction from the panel while the encode runs.
    private func compactQuietly(store: MeetingStore) async {
        let compactor = AudioCompactor(clock: clock)
        do {
            let outcome = try await Task.detached(priority: .utility) {
                try compactor.compact(store: store)
            }.value
            if outcome == .compacted {
                Log.processing.info("audio compacted")
            }
        } catch {
            Log.processing.error(
                "audio compaction failed: \(logSafeDescription(error), privacy: .public)"
            )
        }
    }

    /// How long to wait before attempting a stage again. The server's own
    /// `Retry-After` wins when it sent one.
    private func retryDelay(after failure: ProcessingError, attempt: Int) -> TimeInterval {
        if case .rateLimited(let retryAfter) = failure, let retryAfter {
            return min(max(retryAfter, 0), Self.maxRetryDelaySeconds)
        }
        let index = min(max(attempt - 1, 0), Self.retryDelaysSeconds.count - 1)
        return Self.retryDelaysSeconds[index]
    }

    /// Retries a failed meeting from the stage that failed.
    ///
    /// A meeting already in flight is left alone: rewriting its stage from here
    /// would be overwritten by the run that is mid-request anyway.
    public func retry(meetingID: String) async {
        guard !running.contains(meetingID) else { return }
        // Same reason as process: a meeting folded into an earlier one is hidden
        // from the archive, and refusing it here made the Retry button on its own
        // failure notification a silent no-op.
        guard let found = repository.findMeeting(id: meetingID, includingMerged: true) else {
            return
        }
        var metadata = found.metadata
        guard metadata.processing.state == .failed, let stage = metadata.processing.resumeStage else {
            await process(meetingID: meetingID)
            return
        }
        metadata.processing.advance(to: stage, at: clock.now)
        try? persist(metadata, to: found.store)
        await process(meetingID: meetingID)
    }

    /// Writes back only the fields this pipeline owns.
    ///
    /// The user can rename a meeting or edit its notes while a request is in
    /// flight. Writing the whole copy that was read before the request would
    /// silently discard that edit.
    private func persist(_ metadata: MeetingMetadata, to store: MeetingStore) throws {
        guard (try? store.readMetadata()) != nil else {
            // No metadata.json is either a job whose first write this is, or a
            // meeting somebody trashed underneath it. The folder tells the two
            // apart, and writing into a trashed meeting recreates it.
            guard FileManager.default.fileExists(atPath: store.layout.root.path) else { return }
            try store.writeMetadata(metadata)
            return
        }
        // Through updateMetadata so the read and the write are one operation: a
        // rename landing between them would otherwise be overwritten.
        try store.updateMetadata { current in
            current.processing = metadata.processing
            // Not the duration: it is read once at the start of the job, and
            // folding a reconnected meeting into this one rewrites it on disk
            // meanwhile. Writing the snapshot back reported twenty minutes for
            // a meeting the app had recorded forty-five of. finish() derives it
            // from the timeline at the end.

            current.titles.ai = metadata.titles.ai
            current.titles.calendar = metadata.titles.calendar ?? current.titles.calendar
            current.descriptionText = current.descriptionText ?? metadata.descriptionText
            current.calendar = current.calendar ?? metadata.calendar
            for participant in metadata.participants
            where !current.participants.contains(where: { $0.displayName == participant.displayName }) {
                current.participants.append(participant)
            }
        }
    }

    /// Resumes everything interrupted, called at launch.
    public func resumeInterrupted() async {
        for summary in repository.listMeetings() {
            guard summary.processingState != .complete else { continue }
            guard summary.processingState != .recording else { continue }
            await process(meetingID: summary.id)
        }
        // Meetings folded into an earlier one are hidden from the listing, and
        // their own folder is the only copy of the audio a reconnection
        // recorded: without this a quit or a crash part-way through left the
        // second half of a dropped call untranscribed with nothing to resume it.
        for meetingID in repository.mergedMeetingIDs() {
            await process(meetingID: meetingID)
        }
    }

    // MARK: - stages

    /// Which track holds people whose identity has to be worked out.
    ///
    /// On a remote call it is the meeting audio: the microphone holds the local
    /// user by construction, and taking them out of the diarization problem
    /// measured 97% attribution against 84% for diarizing a mixdown. An
    /// in-person or imported recording has one track holding everyone.
    private func diarizedTrack(_ metadata: MeetingMetadata) -> CaptureTrack {
        metadata.source.micTrackIsLocalUser ? .remote : .mic
    }

    /// Transcribes every track that needs words.
    ///
    /// The microphone track when it is the local user, and the diarized track
    /// whenever the diarization backend does not return words of its own. The
    /// cloud diarizer transcribes as it diarizes; the local one decides speakers
    /// only, so its track is transcribed here.
    private func runTranscription(
        store: MeetingStore, metadata: inout MeetingMetadata, settings: AppSettings
    ) async throws {
        let transcriber = backends.transcription(settings, settings.models.transcription)
        let diarizer = backends.diarization(settings, settings.models.diarization)

        var tracks: [CaptureTrack] = []
        if metadata.source.micTrackIsLocalUser { tracks.append(.mic) }
        // The cloud diarizer transcribes as it diarizes, so its words serve when
        // it is also the transcription backend. They must not serve when the
        // user chose to transcribe on this Mac: taking them would mean the far
        // end's audio is transcribed in the cloud regardless of that choice, and
        // an imported recording, whose only track is the diarized one, would not
        // be transcribed locally at all.
        if !diarizer.producesTranscript || transcriberOwnsWords(settings) {
            let track = diarizedTrack(metadata)
            if !tracks.contains(track) { tracks.append(track) }
        }
        guard !tracks.isEmpty else { return }

        if transcriber.isLocal { try await prepareLocalModels(metadata: metadata) }
        let timeline = try store.readTimeline()
        let existing = try store.readRawTranscript()
        for track in tracks {
            let location = store.trackAudioLocation(track: track, metadata: metadata, timeline: timeline)
            guard !location.isEmpty else { continue }
            // One track's words come from one backend. A failed cloud run that
            // the user retried after switching to Local resumed at this stage,
            // and the resume guards match on chunk identifier, which the two
            // paths namespace differently: both sets landed on the same track as
            // `.words` and the meeting was assembled twice, once in each
            // model's phrasing. Near-duplicate merging only catches pairs that
            // group turns the same way, which two different decoders do not.
            let foreign = existing.chunks(track: track, purpose: .words)
                .contains { $0.model != transcriber.identifier }
            if foreign {
                Log.processing.notice(
                    "track \(track.rawValue, privacy: .public) already transcribed by another backend, keeping those words"
                )
                continue
            }
            if transcriber.limits.requiresChunking {
                try await runChunks(
                    store: store, metadata: &metadata, track: track, location: location,
                    model: transcriber.identifier,
                    configuration: ChunkPlanner.Configuration.fitting(
                        transcriber.limits, timing: transcriber.timing
                    ),
                    // A local engine is one process on one Neural Engine, so
                    // its chunks go one at a time; the cloud takes three.
                    concurrency: transcriber.isLocal ? 1 : nil
                ) { url, _ in
                    let output = try await transcriber.transcribe(audio: url, progress: { _ in })
                    return output
                }
            } else {
                try await runWholeTrack(
                    store: store, metadata: &metadata, track: track,
                    location: location, timeline: timeline, backend: transcriber
                )
            }
        }

        // A text-only backend's words cannot reach the timeline until they
        // carry timings; recover them now, while this stage's retry semantics
        // still apply.
        try await alignTextChunks(store: store, metadata: &metadata)
    }

    /// Forces timings onto every chunk whose model returned text alone.
    ///
    /// Idempotent: a chunk with an alignment on disk is skipped, so a resumed
    /// run aligns only what the interruption left. A chunk the aligner refuses
    /// (no monotonic path) gets a coarse whole-chunk alignment written instead:
    /// the words still reach the timeline at chunk precision, and the refusal
    /// does not fail a meeting whose words are already safe on disk.
    private func alignTextChunks(
        store: MeetingStore, metadata: inout MeetingMetadata
    ) async throws {
        let raw = try store.readRawTranscript()
        let pending = raw.chunks.filter {
            $0.text != nil && $0.purpose == .words && !store.hasAlignment(chunkID: $0.id)
        }
        guard !pending.isEmpty else { return }
        guard let aligner = backends.aligner else {
            Log.processing.notice(
                "no aligner configured; \(pending.count, privacy: .public) text chunks keep chunk-level timing"
            )
            return
        }
        // The aligner specifically, not whatever the current settings need:
        // these chunks were written by whichever model was chosen at the time,
        // and a switch since then would install the wrong unit and leave the
        // stage throwing.
        do {
            try await backends.prepareAligner?()
        } catch {
            // A model that would not download is not a refusal. Swallowing it
            // completed the meeting with one five-minute utterance per chunk,
            // each attributed whole to a single speaker, and nothing revisits
            // a finished meeting: this stage is the only caller of alignment.
            // Failing keeps it retryable, which is the only recovery: the
            // meeting has no canonical transcript yet, so Rebuild Transcript
            // is unavailable to it.
            Log.processing.error(
                "aligner unavailable: \(logSafeDescription(error), privacy: .public)"
            )
            throw ProcessingError.localProcessingFailed(
                reason: "The timing model could not be downloaded, so the transcript's "
                    + "word timings are missing. The words are saved.",
                retryable: true
            )
        }

        let timeline = try store.readTimeline()
        let exporter = ChunkExporter()
        let workingDirectory = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: store.layout.root,
            create: true
        )
        defer { try? FileManager.default.removeItem(at: workingDirectory) }
        // Resolved per track the same way transcription resolves it, so a
        // meeting whose segments have been compacted into per-track archives
        // aligns from the archive rather than from a directory that is gone.
        var locations: [CaptureTrack: TrackAudioLocation] = [:]

        for (index, chunk) in pending.enumerated() {
            report(
                metadata, chunks: (index + 1, pending.count),
                detail: "Aligning transcript timings"
            )
            guard let text = chunk.text else { continue }
            // The chunk's audio span, re-exported from the immutable segments
            // exactly as the transcription export cut it.
            let leadIn = timeline.leadIn(track: chunk.track)
            let plan = ChunkPlan(
                index: index + 1,
                start: chunk.timelineOffset - leadIn,
                end: chunk.timelineOffset - leadIn + chunk.durationSeconds,
                overlapEnd: 0
            )
            let location = try locations[chunk.track]
                ?? store.trackAudioLocation(
                    track: chunk.track, metadata: store.readMetadata(), timeline: timeline
                )
            locations[chunk.track] = location
            let audioURL = workingDirectory.appendingPathComponent("\(chunk.id).m4a")
            let frames = try exporter.export(
                plan: plan, segments: location.segments, segmentsDirectory: location.directory,
                to: audioURL
            )
            defer { try? FileManager.default.removeItem(at: audioURL) }
            guard frames > 0 else { continue }

            do {
                let segments = try await aligner.align(audio: audioURL, text: text)
                try store.writeAlignment(
                    ChunkAlignment(aligner: aligner.identifier, alignedAt: clock.now, segments: segments),
                    chunkID: chunk.id
                )
            } catch let refusal as TranscriptAlignmentRefused {
                // Recorded as a refusal rather than as timings, so a later
                // build with a better aligner can tell the difference and try
                // again. Assembly falls back to whole-chunk timing either way.
                Log.processing.notice(
                    "alignment refused for one chunk, keeping chunk-level timing: \(refusal.reason, privacy: .public)"
                )
                try store.writeAlignment(
                    ChunkAlignment(
                        aligner: aligner.identifier, alignedAt: clock.now,
                        segments: [], refused: true
                    ),
                    chunkID: chunk.id
                )
            } catch {
                // Something broke rather than refused: a missing model, an
                // unreadable export. Nothing is written, so the next run tries
                // again, and assembly meanwhile reads the chunk as untimed.
                Log.processing.notice(
                    "alignment failed for one chunk: \(logSafeDescription(error), privacy: .public)"
                )
            }
        }
    }

    /// Sends a whole track in one request.
    ///
    /// The local transcriber has no request limits and holds timestamps
    /// monotonic over a 65-minute file, so there is nothing to chunk and no
    /// boundary to de-duplicate. One raw chunk per track keeps the stored shape
    /// identical to the cloud path.
    private func runWholeTrack(
        store: MeetingStore,
        metadata: inout MeetingMetadata,
        track: CaptureTrack,
        location: TrackAudioLocation,
        timeline: RecordingTimeline,
        backend: any TranscriptionBackend
    ) async throws {
        var raw = try store.readRawTranscript()
        let chunkID = "\(track.rawValue)_full"
        guard !raw.chunks.contains(where: { $0.id == chunkID }) else { return }
        guard let audio = try scratch.trackAudio(
            meetingID: metadata.id, track: track, segments: location.segments,
            segmentsDirectory: location.directory
        ) else { return }

        let meetingID = metadata.id
        let title = metadata.displayTitle
        let state = metadata.processing.state
        let progress = onProgress
        let output = try await backend.transcribe(audio: audio) { fraction in
            progress(Progress(
                meetingID: meetingID, state: state, completedChunks: 0, totalChunks: 0,
                title: title, fraction: fraction, detail: nil
            ))
        }

        let textOnly = output.segments.isEmpty && !output.text.isEmpty
        try Self.requireTranscribedOrSilent(
            response: output, audio: audio, chunkID: chunkID, purpose: .words
        )
        let looping = try Self.dropIfLooping(
            response: output, chunkID: chunkID, purpose: .words,
            isLastAttempt: metadata.processing.attemptCount(for: .transcribing)
                >= Self.maxAttemptsPerStage,
            scope: .wholeTrack
        )
        raw.chunks.append(RawTranscriptChunk(
            id: chunkID,
            track: track,
            timelineOffset: timeline.leadIn(track: track),
            durationSeconds: output.durationSeconds ?? location.seconds,
            model: backend.identifier,
            responseFormat: Self.localResponseFormat(for: backend.timing),
            segments: looping ? [] : output.segments,
            text: looping || !textOnly ? nil : output.text,
            rawResponseFile: nil
        ))
        try store.writeRawTranscript(raw)
    }

    /// Fails a chunk whose response carried neither segments nor text, unless
    /// the audio behind it holds no speech.
    ///
    /// A transcription backend can answer HTTP 200 with an empty transcript for
    /// ordinary conversation. Recording that as a finished chunk lost 47% of one
    /// meeting's words and still reported `complete`, so an empty answer for
    /// audible audio fails the stage instead: the stage retries, and a meeting
    /// that keeps coming back empty is left failed and retryable. A muted
    /// microphone transcribes to nothing legitimately and must not fail forever,
    /// so the level of the audio that was sent decides between the two.
    public static func requireTranscribedOrSilent(
        response: TranscriptionOutput, audio: URL, chunkID: String, purpose: RawChunkPurpose,
        level measure: (URL) throws -> AudioLevel = MonoAudioDecoder.level
    ) throws {
        // A speakers chunk is asked for intervals, not words; an empty
        // transcript there is not a loss.
        guard purpose == .words else { return }
        // The level only decides between silence and a lost transcript, so a
        // chunk that came back with words is accepted before any decoding: at
        // the 1400 s chunk limit that read is 22M samples of AVAudioConverter
        // work per successful chunk, and a chunk whose audio has since become
        // unreadable would have failed a meeting whose words were already safe.
        guard response.segments.isEmpty, response.text.isEmpty else { return }
        let level: AudioLevel
        do {
            level = try measure(audio)
        } catch {
            // Empty transcript and unreadable audio together: nothing proves
            // the audio was silent, and treating it as silence restores exactly
            // the bug this guards. Fail as an empty transcript rather than as
            // audioUnreadable so the stage retries, because the usual cause is
            // a scratch file that has not settled rather than a corrupt one.
            Log.processing.error("empty transcript with unreadable audio for chunk \(chunkID, privacy: .public)")
            throw ProcessingError.emptyTranscript(chunk: chunkID)
        }
        let decision = EmptyTranscriptPolicy.decide(
            hasSegments: false, hasText: false, level: level
        )
        guard decision == .fail else { return }
        Log.processing.error(
            "empty transcript for audible audio: peak \(level.peakDBFS, format: .fixed(precision: 1)) dBFS"
        )
        throw ProcessingError.emptyTranscript(chunk: chunkID)
    }

    /// Whether a response covers one window of a track or the whole track.
    public enum LoopScope: Sendable, Equatable {
        /// One window of several. A hole in it costs that window.
        case chunk
        /// The track in one request. There is no other window to fall back on,
        /// so recording it as nothing empties the meeting.
        case wholeTrack
    }

    /// Fails a chunk whose response is one phrase repeated for the length of
    /// the window, and on a window's last attempt records it as nothing.
    ///
    /// A speech model given a window with little speech in it can loop, and the
    /// loop is billed, recorded and assembled like any other answer. Five of
    /// sixteen ES2003a chunks came back with the same fabricated paragraph:
    /// 438 invented words against a 386-word reference, 266 insertions and 193%
    /// DER, with the meeting reporting success. A sampled decoder loops on some
    /// passes and not others, so the count varies from run to run and the guard
    /// does not care what it is. Failing the chunk retries it,
    /// which is worth doing because a sampled decoder often comes back with
    /// speech the second time. A decoder that loops deterministically never
    /// will, so the last attempt drops the chunk instead: a hole in one window
    /// costs that window, and failing the stage would cost the whole meeting
    /// for audio nothing can transcribe.
    ///
    /// That trade holds only where a window is one of several. A whole track
    /// arrives as a single chunk, so dropping it records the meeting as
    /// nothing: enrichment returns early on an empty transcript and the meeting
    /// completes with an empty transcript.md, reported as success. A whole
    /// track therefore fails on every attempt and is left retryable, with its
    /// audio untouched for a later run or a different backend.
    ///
    /// - Returns: true when the chunk is to be recorded as nothing.
    public static func dropIfLooping(
        response: TranscriptionOutput, chunkID: String, purpose: RawChunkPurpose,
        isLastAttempt: Bool, scope: LoopScope
    ) throws -> Bool {
        guard purpose == .words else { return false }
        let text = response.text.isEmpty
            ? response.segments.map(\.text).joined(separator: " ")
            : response.text
        let share = DegenerateTranscriptPolicy.repeatedShare(of: text)
        guard DegenerateTranscriptPolicy.decide(text: text) == .fail else { return false }
        Log.processing.error(
            "looping transcript for chunk \(chunkID, privacy: .public), repeated phrase share \(share, format: .fixed(precision: 2))"
        )
        guard isLastAttempt, scope == .chunk else {
            throw ProcessingError.degenerateTranscript(chunk: chunkID)
        }
        return true
    }

    /// The recorded format string for a local backend's chunk, by what timing
    /// its output carried.
    static func localResponseFormat(for timing: TranscriptTiming) -> String {
        switch timing {
        case .words: return "local_words"
        case .segments: return "local_segments"
        case .text: return "local_text"
        }
    }

    /// Whether the transcription backend supplies the diarized track's words.
    ///
    /// When it does, a cloud diarizer's own words are a byproduct of asking who
    /// spoke and must not be assembled as a second copy of the transcript. The
    /// same condition decides, in `runTranscription`, whether that track is
    /// transcribed here at all, so the two cannot disagree.
    private func transcriberOwnsWords(_ settings: AppSettings) -> Bool {
        backends.transcription(settings, settings.models.transcription).isLocal
    }

    /// Works out who spoke when on the track that holds unknown people.
    private func runDiarization(
        store: MeetingStore, metadata: inout MeetingMetadata, settings: AppSettings
    ) async throws {
        let diarizer = backends.diarization(settings, settings.models.diarization)
        let track = diarizedTrack(metadata)
        let timeline = try store.readTimeline()
        let location = store.trackAudioLocation(track: track, metadata: metadata, timeline: timeline)
        guard !location.isEmpty else { return }

        if diarizer.isLocal { try await prepareLocalModels(metadata: metadata) }

        if diarizer.limits.requiresChunking {
            try await runChunkedDiarization(
                store: store, metadata: &metadata, track: track,
                location: location, backend: diarizer, settings: settings
            )
        } else {
            try await runWholeTrackDiarization(
                store: store, metadata: &metadata, track: track, location: location,
                timeline: timeline, backend: diarizer
            )
        }
    }

    /// The cloud path: chunked requests that return words and speakers
    /// together, exactly as before local processing existed.
    ///
    /// The intervals are also recorded as a diarization run, with no vectors,
    /// so speaker memory has something to embed and resolve against whichever
    /// backend produced the labels.
    private func runChunkedDiarization(
        store: MeetingStore,
        metadata: inout MeetingMetadata,
        track: CaptureTrack,
        location: TrackAudioLocation,
        backend: any DiarizationBackend,
        settings: AppSettings
    ) async throws {
        // Decided from which backend owns the words, not from what is on disk.
        // Reading disk state made the answer change mid-stage: a cloud
        // diarization interrupted after some chunks had landed came back, saw
        // its own earlier chunks, and wrote the rest as labels only, so the
        // assembler dropped the whole far end of the meeting after the
        // interruption and never recovered.
        // Whatever this diarizer already wrote for this track, so a run resumed
        // or retried after the transcription setting changed cannot leave half
        // the chunks holding words and half holding labels: the assembler takes
        // one kind, so the other half of the far end would vanish permanently.
        // Only the first pass decides.
        let raw = try store.readRawTranscript()
        let existing = raw.chunks(track: track).first { $0.model == backend.identifier }
        // Another backend's words are already on this track, so it owns them
        // whatever the transcription setting says now, and this pass asks for
        // labels alone. Without it, switching to cloud transcription after a
        // local engine had already chunked the track made this pass claim the
        // same purpose and the same chunk names, so every plan was skipped as
        // done, nothing was diarized, and the far end came back unattributed.
        // The mirror of the `foreign` guard `runTranscription` applies from
        // the other side.
        let foreignWords = raw.chunks(track: track, purpose: .words)
            .contains { $0.model != backend.identifier }
        let purpose = existing?.purpose
            ?? (transcriberOwnsWords(settings) || foreignWords ? .speakers : .words)

        try await runChunks(
            store: store, metadata: &metadata, track: track, location: location,
            model: backend.identifier, purpose: purpose
        ) { url, _ in
            let output = try await backend.diarize(audio: url, progress: { _ in })
            return TranscriptionOutput(
                segments: output.segments, text: "", rawBody: output.rawBody
            )
        }

        // Re-read: the chunks this pass just wrote are not in the snapshot the
        // purpose was decided from.
        let written = try store.readRawTranscript()
        var intervals: [DiarizationInterval] = []
        var speech: [String: Double] = [:]
        for chunk in written.chunks(track: track, purpose: purpose) {
            for segment in chunk.segments {
                guard let speaker = segment.speaker else { continue }
                // Namespaced the same way the transcript's own keys are, so the
                // occurrence rows and the speaker map join without a lookup
                // table.
                let cluster = SpeakerLabel.namespaced(chunkID: chunk.id, rawLabel: speaker)
                intervals.append(DiarizationInterval(
                    start: chunk.timelineOffset + segment.start,
                    end: chunk.timelineOffset + segment.end,
                    clusterID: cluster
                ))
                speech[cluster, default: 0] += max(0, segment.end - segment.start)
            }
        }
        guard !intervals.isEmpty else { return }

        var diarization = try store.readRawDiarization()
        let run = DiarizationRun(
            id: diarization.nextRunID(track: track),
            track: track,
            backend: backend.identifier,
            producedAt: clock.now,
            timelineOffset: 0,
            configuration: ["backend": backend.identifier],
            clusters: speech.keys.sorted().map {
                DiarizationCluster(id: $0, speechSeconds: speech[$0] ?? 0)
            },
            intervals: intervals.sorted { $0.start < $1.start }
        )
        diarization.setActive(run)
        try store.writeRawDiarization(diarization)
    }

    /// The local path: one pass over the whole track, producing intervals and
    /// the vectors speaker memory needs.
    ///
    /// No empty-transcript guard here, unlike the transcription paths: this
    /// writes a diarization run and no `.words` chunk, and the backend returns
    /// intervals rather than words. A run with no intervals is written as an
    /// empty run, which the assembler reads as nobody having been separated.
    private func runWholeTrackDiarization(
        store: MeetingStore,
        metadata: inout MeetingMetadata,
        track: CaptureTrack,
        location: TrackAudioLocation,
        timeline: RecordingTimeline,
        backend: any DiarizationBackend
    ) async throws {
        var diarization = try store.readRawDiarization()
        guard diarization.activeRun(track: track) == nil else { return }
        guard let audio = try scratch.trackAudio(
            meetingID: metadata.id, track: track, segments: location.segments,
            segmentsDirectory: location.directory
        ) else { return }

        let meetingID = metadata.id
        let title = metadata.displayTitle
        let state = metadata.processing.state
        let progress = onProgress
        let output = try await backend.diarize(audio: audio) { fraction in
            progress(Progress(
                meetingID: meetingID, state: state, completedChunks: 0, totalChunks: 0,
                title: title, fraction: fraction, detail: nil
            ))
        }

        let leadIn = timeline.leadIn(track: track)
        let runID = diarization.nextRunID(track: track)
        let run = DiarizationRun(
            id: runID,
            track: track,
            backend: backend.identifier,
            producedAt: clock.now,
            timelineOffset: leadIn,
            configuration: output.configuration,
            clusters: output.clusters,
            intervals: output.intervals.map {
                DiarizationInterval(
                    start: $0.start + leadIn, end: $0.end + leadIn,
                    clusterID: $0.clusterID, quality: $0.quality
                )
            }
        )
        diarization.setActive(run)
        try store.writeRawDiarization(diarization)

        try await recordOccurrences(
            meetingID: metadata.id, run: run, chunkEmbeddings: output.chunkEmbeddings
        )
        await recordSensorOccurrences(
            store: store, meetingID: metadata.id, track: track,
            audio: audio, leadIn: leadIn, run: run
        )
    }

    /// Embeds each participant's sensor-owned speech and records the vector
    /// under their sensor key.
    ///
    /// The stretches come from `SensorAttribution.enrollmentIntervals`: the
    /// participant's turns cut to the solo speech of the clusters those turns
    /// dominate. The client attributed that audio to one person while it was
    /// recorded, so the vector is a known voice rather than a cluster's guess.
    ///
    /// Stored, not resolved. Nothing matches this vector against the profiles
    /// on its own, because a sensor key covers the same seconds as the cluster
    /// beside it and two claims on one voice is what mints an anonymous twin.
    /// It waits here so that confirming a name has a vector to enrol, and so
    /// that a handle bound to this account can carry a person's profile
    /// forward without re-deriving it from audio.
    ///
    /// Never throws into the caller. A voice that cannot be embedded is a voice
    /// learned later through a confirmation, exactly as before this existed.
    private func recordSensorOccurrences(
        store: MeetingStore, meetingID: String, track: CaptureTrack,
        audio: URL, leadIn: Double, run: DiarizationRun
    ) async {
        guard let service = backends.speakers, let extractor = backends.embeddings else { return }
        guard let sensors = store.readRawSensors() else { return }
        let marked = sensors.markingSelf(named: settingsProvider().localUserName)
        // The extractor reads the submitted audio, whose zero is the track's
        // own first frame rather than the meeting timeline's.
        let intervals = SensorAttribution.enrollmentIntervals(
            sensors: marked, diarized: run.intervals
        ).map {
            DiarizationInterval(
                start: max(0, $0.start - leadIn), end: max(0, $0.end - leadIn),
                clusterID: $0.clusterID, quality: $0.quality
            )
        }
        guard !intervals.isEmpty else { return }
        do {
            let embeddings = try await extractor.embed(audio: audio, intervals: intervals)
            var vectors: [String: [[Float]]] = [:]
            for embedding in embeddings {
                vectors[embedding.clusterID, default: []].append(embedding.vector)
            }
            var seconds: [String: Double] = [:]
            for interval in intervals {
                seconds[interval.clusterID, default: 0] += interval.duration
            }
            let speakerStore = await service.speakerStore
            for (key, collected) in vectors {
                try await speakerStore.recordOccurrence(
                    meetingID: meetingID,
                    clusterID: key,
                    track: track,
                    speechSeconds: seconds[key] ?? 0,
                    embedding: VoiceVector.centroid(collected),
                    model: extractor.model,
                    resolution: nil,
                    identityID: nil,
                    source: .sensor,
                    humanVerified: false,
                    wasExpectedParticipant: false,
                    now: clock.now
                )
            }
            Log.processing.info(
                "sensor voices embedded people=\(vectors.count, privacy: .public)"
            )
        } catch {
            Log.processing.notice(
                "sensor voice embedding skipped: \(logSafeDescription(error), privacy: .public)"
            )
        }
    }

    /// Writes one row per cluster into the local identity store, with the vector
    /// it was decided from.
    ///
    /// The vector goes here and not into the meeting folder. A speaker embedding
    /// matches the same person across devices, rooms and years, and the meeting
    /// folder is what a user copies, syncs and shares.
    private func recordOccurrences(
        meetingID: String, run: DiarizationRun, chunkEmbeddings: [DiarizationChunkEmbedding]
    ) async throws {
        guard let speakers = backends.speakers else { return }
        var vectors: [String: [[Float]]] = [:]
        for chunk in chunkEmbeddings {
            let cluster = SpeakerLabel.namespaced(chunkID: run.id, rawLabel: chunk.clusterID)
            vectors[cluster, default: []].append(chunk.vector)
        }
        let store = await speakers.speakerStore
        for cluster in run.clusters {
            let key = SpeakerLabel.namespaced(chunkID: run.id, rawLabel: cluster.id)
            let centroid = vectors[key].map { VoiceVector.centroid($0) }
            try await store.recordOccurrence(
                meetingID: meetingID,
                clusterID: key,
                track: run.track,
                speechSeconds: cluster.speechSeconds,
                embedding: centroid,
                model: centroid == nil ? nil : .fluidAudioOffline,
                resolution: nil,
                identityID: nil,
                source: .ai,
                humanVerified: false,
                wasExpectedParticipant: false,
                now: clock.now
            )
        }
    }


    /// The sensor record with the local user marked, where a meeting has one.
    ///
    /// Only remote meetings: the record describes the far-end track, and an
    /// in-person or imported recording has none by construction.
    private func sensorRecord(store: MeetingStore, metadata: MeetingMetadata) -> RawSensors? {
        guard metadata.source.micTrackIsLocalUser else { return nil }
        guard let sensors = store.readRawSensors() else { return nil }
        return sensors.markingSelf(named: settingsProvider().localUserName)
    }

    /// Names speakers from what the meeting client said, where it said enough.
    ///
    /// Two kinds of key. The sensor keys word attribution wrote get one entry
    /// per participant who held the floor, carrying the name the client
    /// rendered. Cluster keys cover the fallback stretches: a cluster one
    /// person's turns dominate names that person's uncovered words too.
    ///
    /// The decisions live in `SensorAttribution`, which is pure and tested on
    /// its own. Writing through `applySuggestion` is what keeps a person's own
    /// correction and the microphone track's deterministic name above this, and
    /// stops a later voice match from overwriting it.
    private func applySensorNames(
        store: MeetingStore, metadata: MeetingMetadata,
        diarization: RawDiarization, into speakers: inout SpeakerMap
    ) {
        guard let marked = sensorRecord(store: store, metadata: metadata) else { return }
        let people = SensorAttribution.speakerEntries(sensors: marked)
        for entry in people {
            speakers.applySuggestion(entry.assignment, for: entry.key)
        }
        let clusters = SensorAttribution.assignments(
            diarization: diarization, sensors: marked
        )
        for entry in clusters {
            speakers.applySuggestion(entry.assignment, for: entry.key)
        }
        Log.processing.info(
            """
            sensor naming source=\(marked.source, privacy: .public) \
            people=\(people.count, privacy: .public) \
            clusters=\(clusters.count, privacy: .public)
            """
        )
    }

    /// Names sensor speakers from the handles earlier confirmations bound.
    ///
    /// The strongest naming there is: the platform identifier survived from a
    /// meeting where a person confirmed who it belongs to, so the name and the
    /// identity arrive before a second of audio is scored. Written at the same
    /// `.sensor` origin as the roster name and applied after it, so the name
    /// the person chose beats the platform's rendering of it, and a human
    /// correction in this meeting still beats both.
    private func applySensorHandles(
        store: MeetingStore, metadata: MeetingMetadata, into speakers: inout SpeakerMap
    ) async {
        guard let service = backends.speakers else { return }
        guard let sensors = sensorRecord(store: store, metadata: metadata),
              let provider = SensorAttribution.handleProvider(source: sensors.source)
        else { return }
        let selfIDs = Set(sensors.participants.filter(\.isSelf).map(\.id))
        let held = Set(sensors.turns.map(\.participantID)).subtracting(selfIDs)
        guard !held.isEmpty else { return }
        let speakerStore = await service.speakerStore
        var named = 0
        for participantID in held.sorted() {
            guard let identity = await speakerStore.identity(
                handle: participantID, provider: provider
            ), identity.isNamed else { continue }
            speakers.applySuggestion(
                SpeakerAssignment(
                    displayName: identity.resolvedName,
                    origin: .sensor,
                    participantID: participantID,
                    identityID: identity.id,
                    provenance: SpeakerProvenance(
                        source: .sensor, identityID: identity.id, humanVerified: true
                    )
                ),
                for: SpeakerLabel.sensor(participantID: participantID)
            )
            named += 1
        }
        if named > 0 {
            Log.processing.info("sensor handles named=\(named, privacy: .public)")
        }
    }

    /// Measures what the recorded audio holds, once, before the first assembly.
    ///
    /// Only here. Every later assembly reads the file, so a rebuild is free and
    /// gives the same answer: re-measuring would decode both tracks again on
    /// every re-analysis, and on a machine whose detector has since been
    /// deleted it would put the fabricated lines back.
    ///
    /// Only for a meeting whose microphone track is the local user, which is
    /// the only track the gate judges. Imported audio would otherwise pay a
    /// full decode and a detector pass to write a file nothing reads.
    ///
    /// Never throws. The words are already safe on disk as raw chunks, and a
    /// meeting that cannot be measured assembles the way it did before this
    /// existed: every segment kept. Failing the stage instead would turn an
    /// unmeasurable meeting into an unreadable one.
    private func measureSpeech(store: MeetingStore, metadata: MeetingMetadata) async {
        guard metadata.source.micTrackIsLocalUser else { return }
        guard store.readSpeechEvidence() == nil else { return }
        // The detector by name, and 1.1 MB of it. The rule that voice memory
        // may wait for an install but never start one is about not pulling
        // gigabytes onto a machine that chose the cloud. This is a correctness
        // guard on the transcript the user asked for, every configuration
        // already requires it, and the catch-up exists for machines installed
        // before the unit did.
        if let prepare = backends.prepareVoiceActivity {
            do {
                try await prepare()
            } catch {
                Log.processing.notice(
                    "voice detector unavailable: \(logSafeDescription(error), privacy: .public)"
                )
            }
        }
        do {
            let evidence = try await SpeechEvidenceBuilder.build(
                store: store, metadata: metadata, timeline: try store.readTimeline(),
                detector: backends.voiceActivity
            )
            try store.writeSpeechEvidence(evidence)
        } catch {
            Log.processing.notice(
                "speech evidence skipped: \(logSafeDescription(error), privacy: .public)"
            )
        }
    }

    /// Waits for the on-device models, downloading them if this is the first
    /// local job. Recording is never blocked on this; a meeting queues instead.
    private func prepareLocalModels(metadata: MeetingMetadata) async throws {
        guard let prepare = backends.prepareLocalModels else { return }
        report(metadata, chunks: nil, detail: "Preparing on-device models")
        try await prepare()
    }

    /// For work voice memory wants rather than work the user chose. Returns
    /// false when the models are not installed, so the caller skips instead of
    /// starting a download nobody asked for.
    private func localModelsAvailable() async -> Bool {
        guard let require = backends.requireLocalModels else {
            return backends.prepareLocalModels == nil
        }
        do {
            try await require()
            return true
        } catch {
            Log.processing.notice("voice memory skipped: on-device models are not installed")
            return false
        }
    }

    /// Names one chunk, uniquely per producer rather than per track.
    ///
    /// Transcription and diarization can both chunk the same track: a local
    /// engine with a request limit transcribes the far end while a cloud
    /// diarizer labels it. Sharing an identifier made the diarizer's plans
    /// match the transcriber's chunks, so every one was skipped as already
    /// done, no diarization was requested, no run was written, and the whole
    /// far end rendered as a single unattributed speaker with the meeting
    /// reporting success. Words keep the original form, because every meeting
    /// on disk uses it; speaker chunks take a distinct one.
    static func chunkIdentifier(
        track: CaptureTrack, purpose: RawChunkPurpose, plan: ChunkPlan
    ) -> String {
        switch purpose {
        case .words: "\(track.rawValue)_\(plan.chunkID)"
        case .speakers: "\(track.rawValue)_spk_\(plan.chunkID)"
        }
    }

    /// Chunks a track, sends each chunk, and records results as they arrive so an
    /// interrupted run resumes at the chunk it stopped on.
    private func runChunks(
        store: MeetingStore,
        metadata: inout MeetingMetadata,
        track: CaptureTrack,
        location: TrackAudioLocation,
        model: String,
        purpose: RawChunkPurpose = .words,
        configuration: ChunkPlanner.Configuration? = nil,
        concurrency: Int? = nil,
        send: @Sendable @escaping (URL, String) async throws -> TranscriptionOutput
    ) async throws {
        let exporter = ChunkExporter()
        let stream = TrackAudioStream(
            segments: location.segments,
            segmentsDirectory: location.directory,
            format: exporter.readFormat
        )
        let duration = stream.durationSeconds
        guard duration > 0.5 else { return }

        // A pause-aware boundary needs an energy profile; skip the pass entirely
        // for recordings short enough to send in one request.
        let planner = ChunkPlanner(configuration: configuration ?? chunking)
        let energy: EnergyProfile = duration > planner.configuration.maxChunkSeconds
            ? ((try? EnergyProfile.compute(stream: stream)) ?? .empty)
            : .empty
        let plans = planner.plan(durationSeconds: duration, energy: energy)

        // A chunk's start is a position inside this track's own audio. The tracks
        // do not begin at the same instant, so the track's lead-in is added to put
        // the chunk on the meeting timeline the same way the mixdown does.
        let leadIn = (try? store.readTimeline())?.leadIn(track: track) ?? 0

        var raw = try store.readRawTranscript()
        // A unique directory, not a predictable one: a same-user process could
        // otherwise pre-create the path and have meeting audio written through a
        // symlink it controls.
        let workingDirectory = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: store.layout.root,
            create: true
        )
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        // Export locally first; the exports are quick next to the requests.
        struct PreparedChunk: Sendable {
            let plan: ChunkPlan
            let chunkID: String
            let audioURL: URL
        }
        var pending: [PreparedChunk] = []
        for plan in plans {
            let chunkID = Self.chunkIdentifier(track: track, purpose: purpose, plan: plan)
            // The identifier an earlier build wrote for this plan, so an
            // interrupted cloud diarization resumes instead of paying for
            // every chunk again and counting its intervals twice.
            let legacyID = "\(track.rawValue)_\(plan.chunkID)"
            if raw.chunks.contains(
                where: { $0.id == chunkID || ($0.id == legacyID && $0.purpose == purpose) }
            ) { continue }

            let audioURL = workingDirectory.appendingPathComponent("\(chunkID).m4a")
            let frames = try exporter.export(
                plan: plan, segments: location.segments, segmentsDirectory: location.directory,
                to: audioURL
            )
            guard frames > 0 else { continue }
            pending.append(PreparedChunk(plan: plan, chunkID: chunkID, audioURL: audioURL))
        }

        // Chunks are independent requests and the endpoint processes long audio
        // near real time, so sending them one after another made a 25-minute
        // import take over ten minutes. Three at a time stays inside the API's
        // concurrency limits. Each result is committed to disk as it arrives, in
        // completion order; the assembler orders utterances by timeline offset,
        // and an interrupted run still resumes at the chunks that never landed.
        // A local engine overrides it to one: an actor releases itself at every
        // await, so three concurrent calls really do run three decodes against
        // one Neural Engine.
        let maxConcurrentUploads = concurrency ?? 3
        // Read before the group, because the attempt count belongs to the stage
        // and the group must not reach into the metadata being written here.
        let lastAttempt = metadata.processing.attemptCount(for: .transcribing)
            >= Self.maxAttemptsPerStage
        try await withThrowingTaskGroup(of: (PreparedChunk, TranscriptionOutput).self) { group in
            var nextIndex = 0
            while nextIndex < min(maxConcurrentUploads, pending.count) {
                let chunk = pending[nextIndex]
                nextIndex += 1
                group.addTask { (chunk, try await send(chunk.audioURL, model)) }
            }
            while let (chunk, response) = try await group.next() {
                if let body = response.rawBody {
                    try? store.writeAPIResponse(body, named: "\(chunk.chunkID).json")
                }
                let textOnly = response.segments.isEmpty && !response.text.isEmpty
                try Self.requireTranscribedOrSilent(
                    response: response, audio: chunk.audioURL,
                    chunkID: chunk.chunkID, purpose: purpose
                )
                let looping = try Self.dropIfLooping(
                    response: response, chunkID: chunk.chunkID, purpose: purpose,
                    isLastAttempt: lastAttempt, scope: .chunk
                )
                raw.chunks.append(RawTranscriptChunk(
                    id: chunk.chunkID,
                    track: track,
                    timelineOffset: chunk.plan.start + leadIn,
                    durationSeconds: chunk.plan.duration,
                    model: model,
                    responseFormat: response.segments.contains { $0.speaker != nil }
                        ? "diarized_json" : (textOnly ? "json" : "verbose_json"),
                    segments: looping ? [] : response.segments,
                    text: looping || !textOnly ? nil : response.text,
                    rawResponseFile: response.rawBody == nil ? nil : "api/\(chunk.chunkID).json",
                    purpose: purpose
                ))
                try store.writeRawTranscript(raw)
                report(metadata, chunks: (raw.chunks(track: track, purpose: purpose).count, plans.count))
                try? FileManager.default.removeItem(at: chunk.audioURL)
                if nextIndex < pending.count {
                    let next = pending[nextIndex]
                    nextIndex += 1
                    group.addTask { (next, try await send(next.audioURL, model)) }
                }
            }
        }
    }

    private func runSpeakerResolution(
        store: MeetingStore, metadata: inout MeetingMetadata, settings: AppSettings
    ) async throws {
        let raw = try store.readRawTranscriptForAssembly()
        guard !raw.chunks.isEmpty else { return }
        let diarization = try store.readRawDiarization()
        await measureSpeech(store: store, metadata: metadata)

        let assembler = TranscriptAssembler()
        let transcript = assembler.assemble(
            raw: raw, diarization: diarization,
            speech: store.readSpeechEvidence(),
            sensors: sensorRecord(store: store, metadata: metadata),
            micTrackIsLocalUser: metadata.source.micTrackIsLocalUser, generatedAt: clock.now
        )
        try store.writeCanonicalTranscript(transcript)

        var speakers = try store.readSpeakerMap()
        applySensorNames(store: store, metadata: metadata, diarization: diarization, into: &speakers)
        await applySensorHandles(store: store, metadata: metadata, into: &speakers)
        // Not where the user cleared it. The microphone track is the local user
        // by construction, but "Leave unnamed" is offered on that chip like any
        // other, and writing the name back on the next pass made the control do
        // nothing there.
        if metadata.source.micTrackIsLocalUser, speakers.entries[SpeakerLabel.localUser] == nil,
           !speakers.clearedKeys.contains(SpeakerLabel.localUser) {
            speakers.entries[SpeakerLabel.localUser] = SpeakerAssignment(
                displayName: settings.localUserName,
                origin: .deterministic,
                identityID: settings.processing.localUserIdentityID,
                provenance: SpeakerProvenance(
                    source: .deterministic,
                    identityID: settings.processing.localUserIdentityID,
                    humanVerified: true
                )
            )
        }
        try store.writeSpeakerMap(speakers)

        // Voice memory is a side effect of the meeting, not part of it. A
        // deleted model folder or an unreadable track must not take the whole
        // stage down and retry it three times, and must not stop the meeting
        // reaching the stage that writes the markdown and the mixdown.
        do {
            try await recognizeVoices(store: store, metadata: &metadata, settings: settings)
        } catch {
            Log.processing.notice(
                "voice recognition skipped: \(logSafeDescription(error), privacy: .public)"
            )
        }
        do {
            try await learnLocalUserVoice(store: store, metadata: metadata, settings: settings)
        } catch {
            Log.processing.notice(
                "local voice profile skipped: \(logSafeDescription(error), privacy: .public)"
            )
        }
        try await suggestSpeakerNames(store: store, metadata: &metadata, settings: settings)
    }

    /// The audio one cluster covers, on the meeting timeline.
    ///
    /// Read straight off the diarization run, which is immutable once written,
    /// so this answer is the same every time it is asked for as long as that run
    /// exists. It is what a vector derived from the cluster records, and what
    /// stays true after a re-analysis renumbers everything.
    private func clusterSpans(_ clusterID: String, in run: DiarizationRun) -> [AudioSpan] {
        AudioSpan.union(
            run.intervals
                .filter { $0.clusterID == clusterID }
                .map { AudioSpan(start: $0.start, end: $0.end) }
        )
    }

    /// The run and spans behind a namespaced cluster key.
    ///
    /// Every run is searched, not only the active one: a person can confirm a
    /// name against a cluster the previous analysis produced, and the audio it
    /// covered is still the audio it covered.
    private func clusterAudio(
        _ key: String, in diarization: RawDiarization
    ) -> (run: DiarizationRun, spans: [AudioSpan])? {
        for run in diarization.runs {
            for cluster in run.clusters
            where SpeakerLabel.namespaced(chunkID: run.id, rawLabel: cluster.id) == key {
                return (run, clusterSpans(cluster.id, in: run))
            }
        }
        return nil
    }

    /// The audio behind any speaker key: a cluster's intervals, or for a sensor
    /// key the participant's turns cut to the solo speech heard inside them.
    ///
    /// What a confirmation enrols and a retraction takes back, so both kinds of
    /// key move through those paths on the same terms.
    private func audioBehind(
        _ key: String, store: MeetingStore, metadata: MeetingMetadata
    ) throws -> (run: DiarizationRun, spans: [AudioSpan])? {
        let diarization = try store.readRawDiarization()
        return clusterAudio(key, in: diarization)
            ?? sensorAudio(key, store: store, metadata: metadata, diarization: diarization)
    }

    private func sensorAudio(
        _ key: String, store: MeetingStore, metadata: MeetingMetadata,
        diarization: RawDiarization
    ) -> (run: DiarizationRun, spans: [AudioSpan])? {
        guard SpeakerLabel.sensorParticipantID(from: key) != nil,
              let sensors = sensorRecord(store: store, metadata: metadata)
        else { return nil }
        for run in diarization.activeRuns where run.track == .remote {
            let spans = SensorAttribution.enrollmentIntervals(
                sensors: sensors, diarized: run.intervals
            )
            .filter { $0.clusterID == key }
            .map { AudioSpan(start: $0.start, end: $0.end) }
            if !spans.isEmpty { return (run, AudioSpan.union(spans)) }
        }
        return nil
    }

    /// Matches every cluster against the local voice memory.
    ///
    /// A read, in every case. Nothing here writes a vector into a profile at any
    /// confidence: an automatic match that widens the profile it matched against
    /// is what turns one wrong answer into a permanent one.
    private func recognizeVoices(
        store: MeetingStore, metadata: inout MeetingMetadata, settings: AppSettings
    ) async throws {
        guard let service = backends.speakers else { return }
        let recognition = settings.processing.speakers
        guard recognition.recognizeKnownVoices || recognition.rememberRecurringVoices else { return }

        let diarization = try store.readRawDiarization()
        guard !diarization.activeRuns.isEmpty else { return }
        try await ensureOccurrenceVectors(
            store: store, metadata: metadata, diarization: diarization, settings: settings
        )

        let speakerStore = await service.speakerStore
        var clusters: [SpeakerClusterInput] = []
        for run in diarization.activeRuns {
            for cluster in run.clusters {
                let key = SpeakerLabel.namespaced(chunkID: run.id, rawLabel: cluster.id)
                guard let vector = try await speakerStore.occurrenceEmbedding(
                    meetingID: metadata.id, clusterID: key
                ) else { continue }
                clusters.append(SpeakerClusterInput(
                    clusterID: key, track: run.track,
                    speechSeconds: cluster.speechSeconds, centroid: vector,
                    quality: cluster.quality,
                    spans: clusterSpans(cluster.id, in: run), analysisID: run.id
                ))
            }
        }
        // Sensor keys are deliberately not submitted. Their spans are a subset
        // of some cluster's spans, so resolution would see one voice claiming
        // the same seconds twice: the concurrency rule then refuses the second
        // claim its own identity and mints an anonymous twin of a known voice,
        // and the twin splits every future margin. Sensor keys get their
        // identities from handles and from a person confirming a name; their
        // occurrence rows exist so that confirmation has a vector to enrol.
        guard !clusters.isEmpty else { return }

        // Expected participants are a soft prior, and only a person or a
        // calendar may state one. A name the recognizer itself wrote back would
        // otherwise relax the margin on the next pass for the very identity it
        // guessed, which is the recognizer voting for itself.
        let expected = Set(
            metadata.participants
                .filter { $0.origin == .human || $0.origin == .calendar }
                .compactMap(\.identityID)
        )
        let resolved = try await service.resolve(
            meetingID: metadata.id, clusters: clusters, expectedParticipants: expected,
            settings: recognition, now: clock.now
        )

        var speakers = try store.readSpeakerMap()
        for result in resolved {
            guard let identity = result.identity, result.resolution.outcome.isAutomatic else { continue }
            let provenance = SpeakerProvenance(
                source: result.source,
                identityID: identity.id,
                score: result.resolution.best?.score,
                runnerUpScore: result.resolution.runnerUp?.score,
                margin: result.resolution.margin,
                speechSeconds: result.resolution.speechSeconds,
                band: result.resolution.band,
                embeddingModel: EmbeddingModelIdentifier.fluidAudioOffline.rawValue,
                wasExpectedParticipant: expected.contains(identity.id),
                humanVerified: false
            )
            speakers.applySuggestion(
                SpeakerAssignment(
                    displayName: identity.resolvedName,
                    origin: result.source,
                    confidence: result.resolution.best?.score,
                    identityID: identity.id,
                    provenance: provenance
                ),
                for: result.clusterID
            )
            // The name may have been declined because something outranks this,
            // which the meeting client's own account of the call does. The
            // identity is not a name and is linked either way, so a cluster
            // named from the roster still has a person behind it.
            speakers.linkIdentity(
                identity.id, to: result.clusterID,
                named: identity.isNamed ? identity.resolvedName : nil
            )
            if identity.isNamed,
               !metadata.participants.contains(where: { $0.displayName == identity.resolvedName }) {
                metadata.participants.append(Participant(
                    displayName: identity.resolvedName, origin: .ai
                ))
            }
        }
        try store.writeSpeakerMap(speakers)
        Log.processing.info(
            "resolved \(resolved.count, privacy: .public) clusters, \(resolved.filter { $0.resolution.outcome.isAutomatic }.count, privacy: .public) named"
        )
    }

    /// Makes sure every cluster has a vector to be matched against.
    ///
    /// The local diarizer produces them as it runs. A cloud diarizer returns
    /// labels and no vectors, so the intervals it reported are embedded here,
    /// on this Mac. That is what keeps voice memory working when diarization is
    /// not local.
    private func ensureOccurrenceVectors(
        store: MeetingStore, metadata: MeetingMetadata, diarization: RawDiarization,
        settings: AppSettings
    ) async throws {
        guard let service = backends.speakers, let extractor = backends.embeddings else { return }
        let speakerStore = await service.speakerStore
        let timeline = try store.readTimeline()

        for run in diarization.activeRuns {
            var missing: [DiarizationCluster] = []
            for cluster in run.clusters {
                let key = SpeakerLabel.namespaced(chunkID: run.id, rawLabel: cluster.id)
                if try await speakerStore.occurrenceEmbedding(
                    meetingID: metadata.id, clusterID: key
                ) == nil {
                    missing.append(cluster)
                }
            }
            guard !missing.isEmpty else { continue }

            let location = store.trackAudioLocation(
                track: run.track, metadata: metadata, timeline: timeline
            )
            guard !location.isEmpty else { continue }
            guard await localModelsAvailable() else { return }
            guard let audio = try scratch.trackAudio(
                meetingID: metadata.id, track: run.track, segments: location.segments,
                segmentsDirectory: location.directory
            ) else { continue }

            let leadIn = timeline.leadIn(track: run.track)
            let wanted = Set(missing.map(\.id))
            // Solo speech only, computed over the whole run before narrowing
            // to the missing clusters: the voice talking across a cluster is
            // usually one that already has its vector.
            let intervals = DiarizationInterval.soloSpeech(run.intervals)
                .filter { wanted.contains($0.clusterID) }
                .map {
                    DiarizationInterval(
                        start: max(0, $0.start - leadIn), end: max(0, $0.end - leadIn),
                        clusterID: $0.clusterID, quality: $0.quality
                    )
                }
            let embeddings = try await extractor.embed(audio: audio, intervals: intervals)
            var vectors: [String: [[Float]]] = [:]
            for embedding in embeddings { vectors[embedding.clusterID, default: []].append(embedding.vector) }

            for cluster in missing {
                guard let collected = vectors[cluster.id], !collected.isEmpty else { continue }
                let key = SpeakerLabel.namespaced(chunkID: run.id, rawLabel: cluster.id)
                try await speakerStore.recordOccurrence(
                    meetingID: metadata.id, clusterID: key, track: run.track,
                    speechSeconds: cluster.speechSeconds,
                    embedding: VoiceVector.centroid(collected),
                    model: extractor.model, resolution: nil, identityID: nil,
                    source: .ai, humanVerified: false, wasExpectedParticipant: false,
                    now: clock.now
                )
            }
        }
    }

    /// Adds this meeting's microphone audio to the local user's own profile.
    ///
    /// The one enrolment that needs no confirmation, because on a remote call
    /// the microphone track is the local user by construction. That profile is
    /// what makes an in-person or imported recording recognizable: enrolling on
    /// call audio and testing on room audio cost 0.01 to 0.03 of similarity,
    /// with every cross-domain minimum far above the highest impostor score.
    private func learnLocalUserVoice(
        store: MeetingStore, metadata: MeetingMetadata, settings: AppSettings
    ) async throws {
        guard settings.processing.speakers.learnMyVoice,
              metadata.source.micTrackIsLocalUser,
              let service = backends.speakers,
              let embed = backends.singleSpeakerEmbedding,
              let identityID = settings.processing.localUserIdentityID
        else { return }
        guard try await service.wantsLocalUserSample(identityID: identityID) else { return }

        let timeline = try store.readTimeline()
        let location = store.trackAudioLocation(track: .mic, metadata: metadata, timeline: timeline)
        guard !location.isEmpty else { return }
        // The far end has to be on its own track for "the microphone track is
        // the local user" to mean anything. Without one there is nothing to
        // check bleed against, and a call taken on a phone on speaker and
        // recorded manually would enrol whoever spoke most.
        guard !store.trackAudioLocation(
            track: diarizedTrack(metadata), metadata: metadata, timeline: timeline
        ).isEmpty else { return }
        guard await localModelsAvailable() else { return }
        guard let audio = try scratch.trackAudio(
            meetingID: metadata.id, track: .mic, segments: location.segments,
            segmentsDirectory: location.directory
        ) else { return }

        guard let sample = try await embed(audio) else { return }
        // The sample's spans are relative to the audio submitted, which starts at
        // the track's lead-in. Everything stored is on the meeting timeline, so
        // that a span means the same thing whichever track recorded it.
        let leadIn = timeline.leadIn(track: .mic)
        let spans = sample.spans.map {
            AudioSpan(start: $0.start + leadIn, end: $0.end + leadIn)
        }
        // Declined when the microphone track's dominant voice is somebody else
        // on this call. Not a failure: the meeting is fine, the profile simply
        // learns nothing from it.
        guard let status = try await service.learnLocalUserVoice(
            meetingID: metadata.id, identityID: identityID, vector: sample.vector,
            speechSeconds: sample.speechSeconds, quality: sample.quality,
            spans: spans, now: clock.now
        ) else { return }
        Log.processing.info(
            "local voice profile: \(status.recordingCount, privacy: .public) recordings, \(status.sampleCount, privacy: .public) samples"
        )
    }

    /// Asks the cloud model to put names to the speakers it can from the words
    /// alone. Lowest-ranked evidence there is, so it never overwrites a voice
    /// match, a deterministic identity or anything a person set.
    private func suggestSpeakerNames(
        store: MeetingStore, metadata: inout MeetingMetadata, settings: AppSettings
    ) async throws {
        guard settings.enrichment.suggestSpeakers else { return }
        // An empty identifier means the user is mid-edit in Settings.
        guard !settings.models.metadata.isEmpty else { return }
        // This setting defaults on, and both speech backends default to local,
        // so on a fresh install with no key this stage would throw a failure
        // that is not retryable and stop the meeting before the markdown and
        // the mixdown are written. Nothing here was asked for by a user who
        // never configured the cloud.
        guard await backend.isConfigured() else { return }
        guard let transcript = try store.readCanonicalTranscript() else { return }
        let speakers = try store.readSpeakerMap()
        let labels = transcript.speakerKeys.filter {
            $0 != SpeakerLabel.localUser
                && !$0.hasSuffix(SpeakerLabel.unattributed)
                && speakers.entries[$0] == nil
        }
        guard !labels.isEmpty else { return }

        let renderer = TranscriptRenderer()
        let anonymous = transcript.utterances
            .filter { $0.speakerKey != SpeakerLabel.localUser }
            .map { "[\(renderer.timecode($0.start))] \($0.speakerKey): \($0.text)" }
            .joined(separator: "\n")

        let suggestions = try await backend.resolveSpeakers(
            SpeakerResolutionRequest(
                transcript: String(anonymous.prefix(60_000)),
                labels: labels,
                humanContext: store.readNotes(),
                calendarAttendees: metadata.calendar?.attendees ?? [],
                browserParticipants: metadata.participants.map(\.displayName),
                localUserName: metadata.source.micTrackIsLocalUser ? settings.localUserName : nil
            ),
            model: settings.models.metadata
        )

        // Suggestions never overwrite a name the user set, nor a voice match.
        var updated = try store.readSpeakerMap()
        for suggestion in suggestions where labels.contains(suggestion.label) {
            guard suggestion.confidence >= 0.35, !suggestion.name.isEmpty else { continue }
            updated.applySuggestion(
                SpeakerAssignment(
                    displayName: suggestion.name,
                    origin: .ai,
                    confidence: suggestion.confidence,
                    evidence: suggestion.evidence,
                    provenance: SpeakerProvenance(
                        source: .ai, score: suggestion.confidence, band: .medium
                    )
                ),
                for: suggestion.label
            )
        }
        try store.writeSpeakerMap(updated)

        // The same gate the speaker map applies. Without it a name the pipeline
        // had just rejected as too weak was still recorded as a participant, and
        // then fed back as context on the next suggestion request.
        var participants = metadata.participants
        for suggestion in suggestions
        where suggestion.confidence >= 0.35 && !suggestion.name.isEmpty
            && !participants.contains(where: { $0.displayName == suggestion.name }) {
            participants.append(Participant(displayName: suggestion.name, origin: .ai))
        }
        metadata.participants = participants
    }

    private func runEnrichment(
        store: MeetingStore, metadata: inout MeetingMetadata, settings: AppSettings
    ) async throws {
        guard settings.enrichment.wantsAnything else { return }
        guard !settings.models.metadata.isEmpty else { return }
        // Same reason as the speaker suggestion above: titles and summaries are
        // the one part of Pipit that needs the cloud, and wanting them by
        // default must not fail a meeting for someone who runs everything here.
        guard await backend.isConfigured() else { return }
        guard let transcript = try store.readCanonicalTranscript(), !transcript.utterances.isEmpty else {
            return
        }
        let speakers = try store.readSpeakerMap()
        let renderer = TranscriptRenderer()
        let text = renderer.plainText(transcript: transcript, speakers: speakers)

        let enrichment = try await backend.enrich(
            EnrichmentRequest(
                transcript: String(text.prefix(120_000)),
                humanNotes: store.readNotes(),
                participants: speakers.entries.values.map(\.displayName),
                provider: metadata.provider,
                durationSeconds: metadata.durationSeconds,
                wantsTitle: settings.enrichment.generateTitle,
                wantsDescription: settings.enrichment.generateDescription,
                wantsSummary: settings.enrichment.generateSummary,
                wantsNotes: settings.enrichment.generateNotes
            ),
            model: settings.models.metadata
        )

        // A human title always wins; the AI title only fills an empty slot.
        if let title = enrichment.title, !title.isEmpty { metadata.titles.ai = title }
        if let description = enrichment.description, metadata.descriptionText == nil {
            metadata.descriptionText = description
        }

        var summaryParts: [String] = []
        if let summary = enrichment.summary, !summary.isEmpty {
            summaryParts.append("## Summary\n\n\(summary)")
        }
        if let notes = enrichment.notes, !notes.isEmpty {
            summaryParts.append("## Notes\n\n\(notes)")
        }
        if !summaryParts.isEmpty {
            // Written to summary.md, never to notes.md: the user's notes are theirs.
            try store.writeSummary(summaryParts.joined(separator: "\n\n"))
        }
    }

    /// Renders the derived files and links the calendar event.
    private func finish(
        store: MeetingStore, metadata: inout MeetingMetadata, settings: AppSettings
    ) async throws {
        let timeline = try store.readTimeline()
        metadata.durationSeconds = timeline.duration

        if let transcript = try store.readCanonicalTranscript() {
            let speakers = try store.readSpeakerMap()
            let renderer = TranscriptRenderer()
            try store.writeTranscriptMarkdown(renderer.markdown(
                transcript: transcript,
                speakers: speakers,
                title: metadata.displayTitle,
                startedAt: metadata.startedAt,
                durationSeconds: metadata.durationSeconds,
                participants: await participants(in: speakers)
            ))
        }

        if metadata.calendar == nil, let calendar {
            if let match = await calendar.bestMatch(
                startedAt: metadata.startedAt,
                endedAt: metadata.endedAt,
                meetingURL: metadata.meetingURL,
                providerMeetingID: metadata.providerMeetingID
            ) {
                metadata.calendar = match.link
                metadata.titles.calendar = match.link.title
                for attendee in match.link.attendees
                where !metadata.participants.contains(where: { $0.displayName == attendee }) {
                    metadata.participants.append(Participant(displayName: attendee, origin: .calendar))
                }
            }
        }

        // recording.m4a is derivable and entirely optional; a failure here must
        // not fail the meeting.
        if !FileManager.default.fileExists(atPath: store.layout.recordingAudio.path) {
            do {
                try AudioMixer().mix(
                    mic: store.trackAudioLocation(track: .mic, metadata: metadata, timeline: timeline),
                    remote: store.trackAudioLocation(track: .remote, metadata: metadata, timeline: timeline),
                    to: store.layout.recordingAudio
                )
            } catch {
                Log.processing.notice("mixdown skipped: \(logSafeDescription(error), privacy: .public)")
            }
        }
    }

    private func report(
        _ metadata: MeetingMetadata, chunks: (Int, Int)?,
        fraction: Double? = nil, detail: String? = nil
    ) {
        onProgress(Progress(
            meetingID: metadata.id,
            state: metadata.processing.state,
            completedChunks: chunks?.0 ?? 0,
            totalChunks: chunks?.1 ?? 0,
            title: metadata.displayTitle,
            fraction: fraction,
            detail: detail
        ))
    }

    /// Re-assembles the canonical transcript from the raw chunks on disk and
    /// re-renders the Markdown. Makes no API call. Used after an assembly
    /// improvement, so a meeting processed under the old rules picks them up.
    public func rebuildTranscript(meetingID: String) async throws {
        guard let found = repository.findMeeting(id: meetingID, includingMerged: true) else {
            throw StorageError.meetingNotFound(id: meetingID)
        }
        let raw = try found.store.readRawTranscriptForAssembly()
        guard !raw.chunks.isEmpty else { return }
        // The diarization has to come with the words. Without it a locally
        // processed meeting re-assembles with every speaker collapsed into one
        // cluster, and every name in the speaker map stops matching.
        let diarization = try found.store.readRawDiarization()
        let assembler = TranscriptAssembler()
        let transcript = assembler.assemble(
            raw: raw,
            diarization: diarization,
            speech: found.store.readSpeechEvidence(),
            sensors: sensorRecord(store: found.store, metadata: found.metadata),
            micTrackIsLocalUser: found.metadata.source.micTrackIsLocalUser,
            generatedAt: clock.now
        )
        try found.store.writeCanonicalTranscript(transcript)
        // Read back rather than rendered from what was just assembled, so the
        // boundaries a person put in the transcript are in the markdown too.
        try await rerenderMarkdown(store: found.store, metadata: found.metadata)
    }

    /// Re-renders the transcript after a human speaker correction.
    ///
    /// Changing a name is a side-file edit: raw diarization is untouched and no
    /// API call happens. Isolated to the actor so it cannot race the speaker map
    /// written by a resolution stage in flight.
    ///
    /// A confirmation is also identity truth, so when it names an identity with
    /// enough clean speech behind it, the cluster's own vector joins that
    /// person's profile. This and the microphone track are the only two things
    /// that ever write one.
    @discardableResult
    public func applySpeakerName(
        _ name: String, to key: String, meetingID: String, identityID: IdentityID? = nil
    ) async throws -> IdentityID? {
        guard let found = repository.findMeeting(id: meetingID, includingMerged: true) else {
            throw StorageError.meetingNotFound(id: meetingID)
        }
        let settings = settingsProvider()
        // A cluster with no identity passed in may still have made or matched an
        // unnamed one on an earlier pass. Promoting that identity is what keeps
        // the person's history: creating a fresh one instead left two profiles
        // holding the same voice, and because their centroids are then
        // identical, every future meeting scored them equally and the margin
        // gate meant that person was never recognised again.
        // Only an unnamed voice. A cluster the automatic pass already named
        // carries that person's identifier, and typing a different name is the
        // user correcting it: reusing it would return the wrong person, enrol
        // this cluster's audio into their profile, and then rewrite the typed
        // name back to theirs.
        var existing = identityID
        if existing == nil {
            existing = try await anonymousOccurrenceIdentity(
                meetingID: meetingID, clusterID: key
            )
        }
        let resolved = try await identity(named: name, existing: existing)

        var speakers = try found.store.readSpeakerMap()
        speakers.assign(name, to: key, identityID: resolved)
        try found.store.writeSpeakerMap(speakers)
        try await rerenderMarkdown(store: found.store, metadata: found.metadata)

        // The microphone track has no diarization cluster, because its speaker is
        // true by construction. Saying it is somebody else withdraws that
        // construction for this meeting, and the vector it produced claims to be
        // the local user's own voice: the one profile no person ever reviews.
        if key == SpeakerLabel.localUser, resolved != settings.processing.localUserIdentityID {
            try await retractMicrophoneTrack(meetingID: meetingID)
        }
        if let resolved {
            try await confirmCluster(
                meetingID: meetingID, clusterID: key, identityID: resolved, settings: settings
            )
            // A person just said who this platform account belongs to. Where
            // the platform's identifier outlives the meeting, that binding is
            // the strongest re-identification there is: every later meeting
            // names this account's speech from it before any audio is scored.
            // Only a human statement writes one; an automatic voice match at
            // any confidence never does.
            if let participantID = SpeakerLabel.sensorParticipantID(from: key),
               let source = found.store.readRawSensors()?.source,
               let provider = SensorAttribution.handleProvider(source: source),
               let service = backends.speakers {
                try await service.speakerStore.setHandle(
                    IdentityHandle(provider: provider, handle: participantID),
                    to: resolved, now: clock.now
                )
            }
            try await refreshCachedNames(for: resolved)
        } else {
            // Leave unknown. Clearing the name used to leave the vector behind,
            // so the person it had been given to kept somebody else's voice, and
            // because their profile then matched this very cluster at close to
            // 1.0, the next resolution pass wrote the cleared name straight back
            // at High confidence.
            try await retractCluster(meetingID: meetingID, clusterID: key)
            // The handle binding is the same shape of leftover: naming this
            // speaker bound their platform account, so clearing the name has to
            // withdraw the binding too, or the next meeting with this account,
            // and a re-analysis of this one, writes the cleared name back.
            if let participantID = SpeakerLabel.sensorParticipantID(from: key),
               let source = found.store.readRawSensors()?.source,
               let provider = SensorAttribution.handleProvider(source: source),
               let service = backends.speakers {
                try await service.speakerStore.removeHandle(
                    IdentityHandle(provider: provider, handle: participantID)
                )
            }
        }
        return resolved
    }

    /// Takes back everything the microphone track taught, for one meeting.
    ///
    /// The whole track, because that is the unit the deterministic enrolment
    /// covers: it is stored on the claim that this track is the local user, and
    /// the user has just said it is not.
    private func retractMicrophoneTrack(meetingID: String) async throws {
        guard let service = backends.speakers else { return }
        let store = await service.speakerStore
        _ = try await store.retractTrack(meetingID: meetingID, track: .mic, now: clock.now)
    }

    /// Undoes a confirmation: the vector it produced, and the link it wrote.
    private func retractCluster(meetingID: String, clusterID: String) async throws {
        guard let service = backends.speakers else { return }
        let store = await service.speakerStore
        if let found = repository.findMeeting(id: meetingID, includingMerged: true),
           let audio = try audioBehind(
               clusterID, store: found.store, metadata: found.metadata
           ) {
            // Nobody is claiming the audio, so nothing is exempt: every vector
            // that stood on it loses it. Leaving it behind used to mean the
            // person the name was taken away from kept the voice, and because
            // their profile then matched this very cluster at close to 1.0, the
            // next resolution pass wrote the cleared name straight back at High
            // confidence.
            _ = try await store.retractEvidence(
                VoiceEvidenceRetraction(
                    meetingID: meetingID, track: audio.run.track, spans: audio.spans
                ),
                keepingClaimant: false, now: clock.now
            )
        }
        try await store.clearOccurrenceIdentity(meetingID: meetingID, clusterID: clusterID)
    }

    /// Changes the speaker on transcript lines, without touching the cluster
    /// they belong to.
    ///
    /// Writes one override per line. The cluster keeps its name, every other
    /// line assigned to it keeps its name, the raw diarization is untouched,
    /// and nothing is transcribed again. What a turn's header writes, and what
    /// a division writes once it knows which pieces changed hands.
    public func applyUtteranceSpeaker(
        _ name: String, utteranceIDs: [String], meetingID: String, identityID: IdentityID? = nil
    ) async throws {
        _ = try await correctUtterances(
            name, utteranceIDs: utteranceIDs, meetingID: meetingID, identityID: identityID
        )
    }

    /// Divides the transcript where a person put a boundary, and gives the
    /// stretch between the boundaries to one speaker.
    ///
    /// This is what a split and a pull-out both are. A split names everything
    /// from a word to the end of the turn, so its range ends where the turn
    /// does; a pull-out names a phrase inside a turn and the words on either
    /// side stay where they were. Nothing is transcribed again and the raw
    /// diarization is untouched: the boundaries go in `speakers.map.json`
    /// beside the corrections and the transcript is divided when it is read.
    ///
    /// The boundaries are written first and the names second. A failure between
    /// them leaves the line divided and both halves reading as the cluster,
    /// which is a state the panel can show and the user can finish. Writing the
    /// names first would leave a correction covering words that were never
    /// separated from the ones around them.
    /// - Parameter parts: one window per line the reader was pointing at, in
    ///   that line's own coordinates. Per line rather than one range over the
    ///   track, because a turn's lines are not in time order: chunks overlap by
    ///   eight seconds and a near-duplicate is only dropped above a similarity
    ///   bar, so a line printed second can begin before the line printed first.
    ///   One range over both put a boundary in the wrong line, renamed a
    ///   stretch the reader had not selected, and left a selection dragged
    ///   backwards across a seam matching nothing at all.
    @discardableResult
    public func applySpeakerRange(
        _ name: String, meetingID: String, track: CaptureTrack, parts: [SpeakerRangePart],
        identityID: IdentityID? = nil
    ) async throws -> IdentityID? {
        guard let found = repository.findMeeting(id: meetingID, includingMerged: true) else {
            throw StorageError.meetingNotFound(id: meetingID)
        }
        let first = parts.first?.utteranceID ?? ""
        guard let before = try found.store.readCanonicalTranscript() else {
            throw ProcessingError.utteranceNotFound(id: first)
        }
        var windows: [(line: Utterance, part: SpeakerRangePart)] = []
        for part in parts {
            guard let line = before.utterances.first(where: {
                $0.id == part.utteranceID && $0.track == track
            }) else { continue }
            windows.append((line, part))
        }
        guard !windows.isEmpty else { throw ProcessingError.utteranceNotFound(id: first) }
        try divide(store: found.store, windows: windows)

        guard let after = try found.store.readCanonicalTranscript() else {
            throw ProcessingError.utteranceNotFound(id: first)
        }
        // A piece of a line the reader named, by the middle of what is spoken
        // in it: a boundary landing a hair inside the neighbouring piece cannot
        // hand that piece over. Each piece is judged against the window of the
        // line it came from, so two lines sharing a second cannot claim each
        // other's words.
        //
        // Measured across its words rather than its span. A line begins before
        // its first word and ends after its last, and the outermost piece keeps
        // those outer edges so no audio ends up belonging to nobody. The window
        // comes from the words the reader pointed at, so comparing it against
        // the padded span made pulling out the first or last phrase of a turn
        // match no piece at all: the boundary was written and the name was not.
        var selected: [String] = []
        for (line, part) in windows {
            for piece in after.utterances where piece.chunkID == line.chunkID
                && piece.track == track && piece.start >= line.start && piece.end <= line.end {
                let spokenStart = piece.words?.first?.start ?? piece.start
                let spokenEnd = piece.words?.last?.end ?? piece.end
                let middle = (spokenStart + spokenEnd) / 2
                guard middle >= part.startSeconds, middle <= part.endSeconds else { continue }
                if !selected.contains(piece.id) { selected.append(piece.id) }
            }
        }
        guard !selected.isEmpty else { throw ProcessingError.utteranceNotFound(id: first) }
        return try await correctUtterances(
            name, utteranceIDs: selected, meetingID: meetingID, identityID: identityID
        )
    }

    /// Records boundaries and carries any correction on a divided line onto its
    /// pieces.
    ///
    /// Both pieces of a corrected line sit inside the correction's span, so a
    /// later correction on one of them would take the wide override off both.
    /// Dividing the correction with the line keeps the piece nobody touched
    /// reading as the person it was corrected to.
    ///
    /// Divided rather than re-anchored: a correction keeps the seconds it was
    /// made on, clipped to the piece it now belongs to. Re-anchoring it to the
    /// whole piece would widen it, and a correction's width is what says how
    /// much of a line a person actually vouched for. A name set on a
    /// three-second interjection displays across the turn it was merged into
    /// and confirms none of it; stretched to the piece, it would confirm all of
    /// it and put the other speaker's audio in that person's voice profile.
    private func divide(
        store: MeetingStore, windows: [(line: Utterance, part: SpeakerRangePart)]
    ) throws {
        var speakers = try store.readSpeakerMap()
        var changed = false
        for window in windows {
            // This line's own pieces, so a second boundary is placed against
            // what the first one left rather than against the line it replaced.
            var pieces = [window.line]
            for moment in [window.part.startSeconds, window.part.endSeconds] {
                guard let piece = pieces.first(where: { moment > $0.start && moment < $0.end }),
                      let boundary = LineDivision.boundary(in: piece, near: moment)
                else { continue }
                let cut = LineCut(
                    track: piece.track, atSeconds: boundary, chunkID: piece.chunkID,
                    createdAt: clock.now
                )
                let count = speakers.lineCuts.count
                speakers.cut(cut)
                guard speakers.lineCuts.count != count else { continue }
                changed = true
                let divided = LineDivision.divide(piece, at: [cut])
                if divided.count > 1, let override = speakers.override(for: piece) {
                    speakers.utteranceOverrides.removeAll { $0 == override }
                    let start = override.startSeconds ?? piece.start
                    let end = override.endSeconds ?? piece.end
                    for part in divided {
                        let clippedStart = max(start, part.start)
                        let clippedEnd = min(end, part.end)
                        guard clippedEnd > clippedStart else { continue }
                        speakers.utteranceOverrides.append(UtteranceOverride(
                            track: part.track,
                            anchorSeconds: (clippedStart + clippedEnd) / 2,
                            startSeconds: clippedStart,
                            endSeconds: clippedEnd,
                            assignment: override.assignment,
                            createdAt: override.createdAt,
                            utteranceID: part.id,
                            chunkID: part.chunkID
                        ))
                    }
                }
                if let at = pieces.firstIndex(where: { $0.id == piece.id }) {
                    pieces.replaceSubrange(at...at, with: divided)
                }
            }
        }
        guard changed else { return }
        try store.writeSpeakerMap(speakers)
    }

    /// Moves a set of lines to one speaker, all of them or none.
    ///
    /// The selection is one decision, so it is resolved, applied in memory and
    /// written once. Applying line by line meant a failure part way through left
    /// the map half rewritten with no error shown: seventeen of thirty lines
    /// renamed, the person who lost them still holding a vector built from their
    /// audio, and nothing left to say a rebuild was owed.
    @discardableResult
    private func correctUtterances(
        _ name: String, utteranceIDs: [String], meetingID: String, identityID: IdentityID?
    ) async throws -> IdentityID? {
        guard let found = repository.findMeeting(id: meetingID, includingMerged: true) else {
            throw StorageError.meetingNotFound(id: meetingID)
        }
        guard let transcript = try found.store.readCanonicalTranscript() else {
            throw ProcessingError.utteranceNotFound(id: utteranceIDs.first ?? "")
        }
        // Every line is looked up before anything is written. The transcript
        // moves under a correction when a re-analysis lands between the click and
        // this call, and saying so is the point: returning nil silently left the
        // user watching a name appear and then vanish.
        var lines: [Utterance] = []
        for id in utteranceIDs {
            guard let utterance = transcript.utterances.first(where: { $0.id == id }) else {
                throw ProcessingError.utteranceNotFound(id: id)
            }
            lines.append(utterance)
        }
        guard !lines.isEmpty else { return nil }

        let settings = settingsProvider()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Resolved before the map is read, and once for the whole selection. This
        // actor is re-entrant at that suspension, so a map read before it is a
        // snapshot another correction can write over: two lines named in quick
        // succession both read an empty map, and the second write dropped the
        // first line's name. It also reverted the cluster names recognition wrote
        // while the user was typing.
        let resolved = trimmed.isEmpty
            ? nil
            : try await identity(named: trimmed, existing: identityID)

        var speakers = try found.store.readSpeakerMap()
        // The audio that actually changes hands, and who it changes hands to.
        //
        // A line already reading as the person being named moves nothing, and
        // the menu offers this on every line: treating those as moves cost the
        // cluster's owner a voice profile for a click that changed nothing on
        // screen. Grouped by the new owner rather than by the correction,
        // because clearing a line hands it back to whoever the cluster says, and
        // claiming it for nobody took those seconds off that person too.
        var moved: [Claim: [AudioSpan]] = [:]
        // Read before any of them is written. Two selected lines can overlap,
        // and writing the first changes what the second reads as: the second
        // would then look like it was already the person being named, and the
        // audio moving away from its previous owner would go unrecorded.
        let owners = lines.map { utterance -> SpeakerAssignment? in
            let override = speakers.override(for: utterance)?.assignment
            return (override?.origin == .human ? override : nil)
                ?? speakers.entries[utterance.speakerKey]
        }
        for (utterance, before) in zip(lines, owners) {
            let after: IdentityID?
            if trimmed.isEmpty {
                speakers.clearOverride(for: utterance)
                // Clearing hands the line back to whatever the cluster says.
                after = speakers.entries[utterance.speakerKey]?.identityID
            } else {
                speakers.overrideUtterance(
                    utterance,
                    with: SpeakerAssignment(
                        displayName: trimmed, origin: .human, identityID: resolved,
                        provenance: .human()
                    ),
                    at: clock.now
                )
                after = resolved
            }
            guard before?.identityID != after else { continue }
            moved[Claim(track: utterance.track, owner: after), default: []]
                .append(AudioSpan(start: utterance.start, end: utterance.end))
        }
        try found.store.writeSpeakerMap(speakers)
        try await rerenderMarkdown(store: found.store, metadata: found.metadata)

        try await settleVoiceMemory(
            found: found, moved: moved, claimant: resolved, speakers: speakers, settings: settings
        )
        return resolved
    }

    /// One track's audio and whoever it now belongs to.
    private struct Claim: Hashable {
        var track: CaptureTrack
        /// Nil only when the line ends up belonging to a cluster nobody has
        /// named, in which case no vector may keep it.
        var owner: IdentityID?

        var sortKey: String { "\(track.rawValue)/\(owner?.rawValue ?? -1)" }
    }

    /// Brings voice memory back in line with a correction that has landed.
    ///
    /// Whoever held a vector built on the audio that just changed hands is found
    /// by asking which stored vectors cover those spans, rather than by reasoning
    /// about who used to own which cluster. That is the whole reason spans are
    /// recorded: the question has one answer, and it does not change when a
    /// re-analysis renumbers the clustering underneath it.
    private func settleVoiceMemory(
        found: (metadata: MeetingMetadata, store: MeetingStore),
        moved: [Claim: [AudioSpan]],
        claimant: IdentityID?, speakers: SpeakerMap, settings: AppSettings
    ) async throws {
        guard !moved.isEmpty, let service = backends.speakers else { return }
        let store = await service.speakerStore
        var displaced: [IdentityID] = []
        for (claim, spans) in moved.sorted(by: { $0.key.sortKey < $1.key.sortKey }) {
            let track = claim.track
            // Ungated by the learning setting, like the cluster path. The user
            // has said this audio is not theirs, and refusing to remove it
            // because learning is switched off leaves them auto-named from
            // somebody else's voice forever. The rebuild below carries the gate,
            // so with the setting off the vector goes and nothing replaces it,
            // which is what the setting asks for.
            for stale in try await store.retractEvidence(
                VoiceEvidenceRetraction(
                    meetingID: found.metadata.id, track: track, spans: spans,
                    claimedBy: claim.owner
                ),
                keepingClaimant: true, now: clock.now
            ) where !displaced.contains(stale) {
                displaced.append(stale)
            }
        }
        // Each of them derives a replacement from the lines that are still
        // theirs. If too little of their speech remains they correctly end with
        // none.
        for identity in displaced where identity != claimant {
            try await accumulateConfirmedSpeech(
                store: found.store, metadata: found.metadata, speakers: speakers,
                identityID: identity, settings: settings
            )
        }
        guard let claimant else { return }
        try await accumulateConfirmedSpeech(
            store: found.store, metadata: found.metadata, speakers: speakers,
            identityID: claimant, settings: settings
        )
        try await refreshCachedNames(for: claimant)
    }

    /// Re-clusters a meeting, optionally at a speaker count the user chose.
    ///
    /// Words are not touched: this re-runs clustering only. Where the prepared
    /// state from the first pass is still in memory it costs about a second on a
    /// 60-minute meeting instead of about fifteen. The previous result stays on
    /// disk, marked inactive, so the change can be undone.
    public func reanalyzeSpeakers(meetingID: String, speakerCount: Int?) async throws {
        guard let found = repository.findMeeting(id: meetingID, includingMerged: true) else {
            throw StorageError.meetingNotFound(id: meetingID)
        }
        guard let reanalyze = backends.reanalyzeDiarization else { return }
        await waitForSlot()
        defer { jobLock.release() }
        defer { scratch.discard(meetingID: meetingID) }

        // Re-read after the wait: the pre-wait snapshot predates whatever job
        // held the slot, and compaction in particular flips audioArchive and
        // deletes the segment files a stale location would name.
        let store = found.store
        let metadata = (try? store.readMetadata()) ?? found.metadata
        let settings = settingsProvider()
        let track = diarizedTrack(metadata)
        let timeline = try store.readTimeline()
        let location = store.trackAudioLocation(track: track, metadata: metadata, timeline: timeline)
        guard !location.isEmpty else { return }

        // The diarizer alone: re-analysis re-clusters, it never re-transcribes,
        // so pulling the configured transcription engine and its aligner would
        // download gigabytes this button will not use.
        if let prepare = backends.prepareDiarizer {
            report(metadata, chunks: nil, detail: "Preparing on-device models")
            try await prepare()
        } else {
            try await prepareLocalModels(metadata: metadata)
        }
        guard let audio = try scratch.trackAudio(
            meetingID: metadata.id, track: track, segments: location.segments,
            segmentsDirectory: location.directory
        ) else { return }

        let output = try await reanalyze(metadata.id, audio, speakerCount)
        var diarization = try store.readRawDiarization()
        let leadIn = timeline.leadIn(track: track)
        let run = DiarizationRun(
            id: diarization.nextRunID(track: track),
            track: track,
            backend: LocalSpeechStack.diarizerBackendIdentifier,
            producedAt: clock.now,
            timelineOffset: leadIn,
            configuration: output.configuration,
            clusters: output.clusters,
            intervals: output.intervals.map {
                DiarizationInterval(
                    start: $0.start + leadIn, end: $0.end + leadIn,
                    clusterID: $0.clusterID, quality: $0.quality
                )
            }
        )
        diarization.setActive(run)
        try store.writeRawDiarization(diarization)

        // Re-clustering renumbers, so every name keyed to the old clusters is
        // now keyed to nothing. Sensor keys survive by construction, and the
        // client's account of the call is still on disk and still true, so the
        // cluster-level fallback names are applied again here. Without this,
        // re-analysing a meeting silently threw away its names.
        var reNamed = try store.readSpeakerMap()
        applySensorNames(store: store, metadata: metadata, diarization: diarization, into: &reNamed)
        await applySensorHandles(store: store, metadata: metadata, into: &reNamed)
        try store.writeSpeakerMap(reNamed)

        // Deliberately not deleting this meeting's confirmed enrolments here.
        // The clusters they came from no longer exist under these identifiers,
        // so a wrong name confirmed before a re-analysis cannot be retracted
        // through the panel any more, which is a real gap. Deleting them was
        // worse: it read no settings, so it destroyed human-verified material
        // for a user who had switched learning from corrections off and could
        // not re-confirm it, and it matched on source type alone, so it took the
        // promoted seed that is a named person's only vector and left them with
        // an empty profile that the next pass re-seeded as a stranger.
        //
        // Retracting a cluster's enrolment is exposed where the confirmation was
        // made instead: naming the cluster again, or leaving it unknown.

        try await recordOccurrences(
            meetingID: metadata.id, run: run, chunkEmbeddings: output.chunkEmbeddings
        )

        // The new clusters carry the new run's identifiers, so no name from the
        // previous clustering follows them. Line-level corrections do: they are
        // anchored to a moment rather than to a cluster.
        var metadataCopy = metadata
        let raw = try store.readRawTranscriptForAssembly()
        let transcript = TranscriptAssembler().assemble(
            raw: raw, diarization: diarization,
            speech: store.readSpeechEvidence(),
            sensors: sensorRecord(store: store, metadata: metadata),
            micTrackIsLocalUser: metadata.source.micTrackIsLocalUser, generatedAt: clock.now
        )
        try store.writeCanonicalTranscript(transcript)
        try await recognizeVoices(store: store, metadata: &metadataCopy, settings: settings)
        try await rerenderMarkdown(store: store, metadata: metadataCopy)
    }

    /// Re-runs identity resolution alone, after the expected-participant list
    /// changed. Cheap: no audio is read and nothing is transcribed.
    public func refreshSpeakerIdentities(meetingID: String) async throws {
        guard let found = repository.findMeeting(id: meetingID, includingMerged: true) else {
            throw StorageError.meetingNotFound(id: meetingID)
        }
        // Where a cloud diarizer left no vectors this reads a whole track and
        // runs the embedding model, which is a processing stage in everything
        // but name and waits for the same things.
        await waitForSlot()
        defer { jobLock.release() }
        defer { scratch.discard(meetingID: meetingID) }
        // Re-read after the wait; see reanalyzeSpeakers.
        var metadata = (try? found.store.readMetadata()) ?? found.metadata
        try await recognizeVoices(
            store: found.store, metadata: &metadata, settings: settingsProvider()
        )
        try await rerenderMarkdown(store: found.store, metadata: metadata)
    }

    // MARK: - identity plumbing

    /// The identity a typed name refers to, creating one if it is new.
    /// The unnamed identity a cluster is already linked to.
    ///
    /// Naming that cluster promotes this identity rather than creating a second
    /// one holding the same voice. Nil when the cluster has no identity or when
    /// it has a named one, which is a different situation: a correction.
    private func anonymousOccurrenceIdentity(
        meetingID: String, clusterID: String
    ) async throws -> IdentityID? {
        guard let service = backends.speakers else { return nil }
        let store = await service.speakerStore
        let occurrences = try await store.occurrences(meetingID: meetingID)
        guard let found = occurrences.first(where: { $0.clusterID == clusterID }),
              let identityID = found.resolvedIdentityID,
              let identity = try await store.current(identityID),
              identity.kind == .anonymous
        else { return nil }
        return identity.id
    }

    private func identity(named name: String, existing: IdentityID?) async throws -> IdentityID? {
        guard let service = backends.speakers else { return existing }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let store = await service.speakerStore
        if let existing {
            // Naming a recurring voice promotes it in place. Every historical
            // occurrence already points at this identifier, so nothing else
            // moves.
            if let identity = try await store.current(existing), identity.kind == .anonymous {
                // Someone by that name already exists, so this voice is theirs.
                // Promoting instead would leave two people with one name and
                // near-identical centroids, which splits every future margin
                // and means neither is ever recognised again.
                if let match = try await person(named: trimmed) {
                    try await store.merge(identity.id, into: match)
                    return match
                }
                return try await store.promoteToPerson(identity.id, name: trimmed, now: clock.now)?.id
                    ?? identity.id
            }
            // Resolved, because a caller can hold an identifier that has since
            // been merged away and everything downstream would write to a row
            // no read reaches.
            return try await store.current(existing)?.id ?? existing
        }
        if let match = try await person(named: trimmed) { return match }
        return try await store.createPerson(name: trimmed, now: clock.now).id
    }

    private func person(named name: String) async throws -> IdentityID? {
        guard let service = backends.speakers else { return nil }
        let store = await service.speakerStore
        let people = try await store.identities(kind: .person)
        return people.first {
            $0.resolvedName.compare(name, options: .caseInsensitive) == .orderedSame
        }?.id
    }

    private func confirmCluster(
        meetingID: String, clusterID: String, identityID: IdentityID, settings: AppSettings
    ) async throws {
        guard let service = backends.speakers else { return }
        let store = await service.speakerStore
        let occurrences = try await store.occurrences(meetingID: meetingID)
        guard let occurrence = occurrences.first(where: { $0.clusterID == clusterID }) else { return }
        guard let vector = try await store.occurrenceEmbedding(
            meetingID: meetingID, clusterID: clusterID
        ) else { return }
        // Without the audio the cluster covers there is nothing to record and
        // nothing to retract later, so the confirmation writes the name and
        // learns no voice from it.
        guard let found = repository.findMeeting(id: meetingID, includingMerged: true),
              let audio = try audioBehind(
                  clusterID, store: found.store, metadata: found.metadata
              ), !audio.spans.isEmpty
        else { return }
        // Minus the lines inside it a person has already given to somebody else.
        // A line-level correction outranks the cluster's name on screen, so
        // claiming the whole cluster's audio took the corrected lines' voice
        // away from the person still shown as speaking them: the transcript said
        // one thing and voice memory the other.
        let claimed = AudioSpan.subtracting(
            correctedElsewhere(in: found.store, track: occurrence.track, besides: identityID),
            from: audio.spans
        )
        guard !claimed.isEmpty else { return }
        _ = try await service.confirmCluster(
            meetingID: meetingID,
            cluster: SpeakerClusterInput(
                clusterID: clusterID, track: occurrence.track,
                speechSeconds: min(occurrence.speechSeconds, AudioSpan.totalDuration(claimed)),
                centroid: vector,
                spans: claimed, analysisID: audio.run.id
            ),
            identityID: identityID,
            settings: settings.processing.speakers,
            now: clock.now
        )
    }

    /// Turns confirmed transcript lines into enrolment material.
    ///
    /// One line is identity truth and almost never enough audio: below ten
    /// seconds the 1st percentile of genuine scores is 0.28. Confirmed speech
    /// accumulates and is embedded in one piece once it clears 45 seconds, from
    /// the audio itself rather than from anything stored per line.
    private func accumulateConfirmedSpeech(
        store: MeetingStore, metadata: MeetingMetadata, speakers: SpeakerMap,
        identityID: IdentityID, settings: AppSettings
    ) async throws {
        guard settings.processing.speakers.learnFromCorrections,
              let service = backends.speakers,
              let extractor = backends.embeddings,
              let transcript = try store.readCanonicalTranscript()
        else { return }

        // One meeting contributes one enrolment. Without this, correcting more
        // lines later re-embeds the whole growing set again and stacks several
        // near-identical vectors from one session into a profile that is meant
        // to be diverse.
        let speakerStore = await service.speakerStore
        guard try await !speakerStore.hasEnrolment(
            identityID: identityID, meetingID: metadata.id,
            source: .humanConfirmedUtterances, model: extractor.model
        ) else { return }

        // The lines this person was confirmed on, minus any that another line
        // overlaps: the assembler folds words spoken over a speaker into the
        // surrounding turn, and a vector must never mix two voices.
        var confirmed: [Utterance] = []
        for utterance in transcript.utterances {
            guard let assignment = speakers.assignment(for: utterance),
                  assignment.origin == .human, assignment.identityID == identityID
            else { continue }
            // A line-level correction only counts as this person's speech when
            // it covers most of the line. After a re-analysis merges a short
            // corrected interjection into a long turn, the correction rightly
            // keeps its name on the merged line, but the rest of that turn is
            // somebody else's voice and must not reach a profile.
            if speakers.hasOverride(for: utterance), !speakers.confirms(utterance) { continue }
            let overlapped = transcript.utterances.contains {
                $0.id != utterance.id && $0.track == utterance.track
                    && $0.start < utterance.end && utterance.start < $0.end
            }
            if overlapped { continue }
            confirmed.append(utterance)
        }
        guard !confirmed.isEmpty else { return }

        // Grouped by track, and the enrolment is built from one track only. A
        // remote meeting's microphone track holds a different person, so summing
        // both and then embedding whichever came first would enrol the wrong
        // voice under this name.
        var byTrack: [CaptureTrack: [Utterance]] = [:]
        for utterance in confirmed { byTrack[utterance.track, default: []].append(utterance) }
        let best = byTrack.max { left, right in
            left.value.reduce(0) { $0 + ($1.end - $1.start) }
                < right.value.reduce(0) { $0 + ($1.end - $1.start) }
        }
        guard let (track, lines) = best.map({ ($0.key, $0.value) }) else { return }
        let seconds = lines.reduce(0) { $0 + max(0, $1.end - $1.start) }
        let policy = await service.resolutionPolicy
        guard seconds >= policy.enrolmentSpeechSeconds else { return }

        // Reading a whole meeting off disk and running the embedding model is
        // the same class of work a processing stage does, so it waits for the
        // same things.
        await waitForSlot()
        defer { jobLock.release() }
        defer { scratch.discard(meetingID: metadata.id) }

        // Resolved after the wait, from a fresh read: the job this call queued
        // behind can be compaction, which moves the audio into the archive and
        // deletes the segments a pre-wait location would still point at.
        let currentMetadata = (try? store.readMetadata()) ?? metadata
        let timeline = try store.readTimeline()
        let location = store.trackAudioLocation(
            track: track, metadata: currentMetadata, timeline: timeline
        )
        guard !location.isEmpty else { return }

        guard await localModelsAvailable() else { return }
        guard let audio = try scratch.trackAudio(
            meetingID: metadata.id, track: track, segments: location.segments,
            segmentsDirectory: location.directory
        ) else { return }

        let leadIn = timeline.leadIn(track: track)
        let intervals = lines.map {
            DiarizationInterval(
                start: max(0, $0.start - leadIn), end: max(0, $0.end - leadIn),
                clusterID: "confirmed"
            )
        }
        let vectors = try await extractor.embed(audio: audio, intervals: intervals)
        guard !vectors.isEmpty else { return }
        _ = try await service.confirmUtterances(
            meetingID: metadata.id, identityID: identityID, vectors: vectors,
            track: track,
            // The lines themselves, on the meeting timeline. The intervals above
            // are track-relative because that is what the extractor reads.
            spans: lines.map { AudioSpan(start: $0.start, end: $0.end) },
            settings: settings.processing.speakers, now: clock.now
        )
    }

    /// The audio a person has already assigned to somebody other than
    /// `identityID`, line by line.
    private func correctedElsewhere(
        in store: MeetingStore, track: CaptureTrack, besides identityID: IdentityID
    ) -> [AudioSpan] {
        guard let transcript = (try? store.readCanonicalTranscript()) ?? nil,
              let speakers = try? store.readSpeakerMap()
        else { return [] }
        return AudioSpan.union(
            transcript.utterances.compactMap { utterance in
                guard utterance.track == track,
                      let override = speakers.override(for: utterance)?.assignment,
                      override.origin == .human,
                      override.identityID != identityID
                else { return nil }
                return AudioSpan(start: utterance.start, end: utterance.end)
            }
        )
    }

    /// Rewrites the cached names in every meeting that refers to an identity.
    ///
    /// The name beside an identity in a meeting folder is a cache, so the folder
    /// stays readable on its own. Renaming, promoting or merging updates the
    /// store, and this brings the copies in line without touching a transcript's
    /// words or its raw diarization.
    /// Brings every meeting this person appears in back in line with the
    /// database: the cached name in the speaker map, and the rendered markdown.
    public func refreshCachedNames(for identityID: IdentityID) async throws {
        guard let service = backends.speakers else { return }
        let store = await service.speakerStore
        guard let identity = try await store.current(identityID) else { return }
        // Every identifier that reads as this person, because a meeting keeps
        // the link it was written with. Refreshing only the one passed in left
        // every meeting that saw a merged-away identity showing the old name
        // forever: meetingsReferencing already walks the family, so those
        // meetings were visited and then skipped for not matching.
        let family = try await store.family(of: identityID)
        for meetingID in try await store.meetingsReferencing(identityID) {
                // Including a folded continuation. It is a real recording holding
            // real lines, so a rename that skipped it left the second half of a
            // dropped call showing a name nobody uses any more.
            guard let found = repository.findMeeting(
                id: meetingID, includingMerged: true
            ) else { continue }
            var speakers = try found.store.readSpeakerMap()
            // Only the cached name is rewritten. The identity link stays as it
            // was written, because reads resolve through the merge tombstone
            // and rewriting it would make separating the merge unable to find
            // these entries again: the meeting would stay attributed to the
            // wrong person forever.
            var changed = false
            for member in family
            where speakers.refreshName(of: member, to: identity.resolvedName) {
                changed = true
            }
            // The map is written only when an entry was found to update; the
            // markdown is re-rendered either way, because the participant block
            // carries the organization and the notes as well as the name, and a
            // meeting can reference this person through an occurrence whose
            // speaker map no longer names them.
            if changed { try found.store.writeSpeakerMap(speakers) }
            try await rerenderMarkdown(store: found.store, metadata: found.metadata)
        }
    }

    /// Re-renders named meetings whatever they currently resolve to.
    ///
    /// For a person who has just been deleted: `meetingsReferencing` can no
    /// longer find them, so the caller collects the identifiers first and the
    /// render then drops their line from each participant block.
    public func rerenderMeetings(_ meetingIDs: [String]) async {
        for meetingID in meetingIDs {
            guard let found = repository.findMeeting(id: meetingID, includingMerged: true)
            else { continue }
            try? await rerenderMarkdown(store: found.store, metadata: found.metadata)
        }
    }

    /// Waits until heavy work may start, and holds the slot on return.
    ///
    /// The two waits happen in the wrong order to check once: acquiring the
    /// slot can take the length of another meeting's transcription, and a
    /// recording that starts in that window makes the gate reading stale. The
    /// caller pairs this with a `defer { jobLock.release() }`.
    private func waitForSlot() async {
        while true {
            await gate.waitUntilAllowed()
            await jobLock.acquire()
            if !gate.isBlocked { return }
            jobLock.release()
        }
    }

    /// Categorises a stage failure.
    ///
    /// Anything unrecognised used to become `.transport`, whose message names
    /// OpenAI and whose retryable flag is true. A fully local user with no key
    /// was told Pipit could not reach a service they never configured, and a
    /// deterministic local failure was retried three times with backoff.
    public static func processingError(from error: any Error) -> ProcessingError {
        if let processing = error as? ProcessingError { return processing }
        if error is CancellationError { return .cancelled }
        if let local = error as? any LocalProcessingFailure {
            return .localProcessingFailed(
                reason: local.userMessage, retryable: local.isRetryable
            )
        }
        if error is VoiceEnrollmentRejection {
            return .localProcessingFailed(
                reason: "Voice memory could not use this meeting's audio.", retryable: false
            )
        }
        // Still unknown, and not from the cloud client, which raises
        // ProcessingError for everything it can categorise. The message that
        // reaches the user cannot name a cause, so the one thing that can is
        // written to the log: without it a failed meeting says only that it
        // failed, and there is nothing to work from.
        Log.processing.error(
            "unrecognised processing failure: \(logSafeDescription(error), privacy: .public)"
        )
        return .localProcessingFailed(
            reason: "Processing this meeting on this Mac failed.", retryable: true
        )
    }

    /// Re-renders one meeting's markdown from what is on disk.
    ///
    /// The speaker map is read here rather than passed in. Resolving the
    /// participants suspends on the speaker store, so a map handed over before
    /// that suspension can be stale by the time the file is written: two
    /// corrections in quick succession would leave `transcript.md` showing the
    /// earlier one while `speakers.map.json` held the later.
    private func rerenderMarkdown(
        store: MeetingStore, metadata: MeetingMetadata
    ) async throws {
        guard let transcript = try store.readCanonicalTranscript() else { return }
        // Read twice on purpose: once to learn which identities to look up, and
        // again after the last suspension point so the map the file is rendered
        // from is the one currently on disk.
        let participants = await participants(in: try store.readSpeakerMap())
        let speakers = try store.readSpeakerMap()
        try store.writeTranscriptMarkdown(TranscriptRenderer().markdown(
            transcript: transcript,
            speakers: speakers,
            title: metadata.displayTitle,
            startedAt: metadata.startedAt,
            durationSeconds: metadata.durationSeconds,
            participants: participants
        ))
    }

    /// Who was in the meeting, with whatever the user has written about them.
    ///
    /// Read from the identity links the speaker map already carries, so a line
    /// the user reassigned brings the right person's notes with it. Resolved
    /// through `current`, because a meeting keeps the identifier it was written
    /// with and a merge since then has to land on the survivor.
    private func participants(in speakers: SpeakerMap) async -> [TranscriptParticipant] {
        guard let service = backends.speakers else { return [] }
        let store = await service.speakerStore
        var seen = Set<IdentityID>()
        var out: [TranscriptParticipant] = []
        for identityID in speakers.referencedIdentities {
            guard let identity = try? await store.current(identityID),
                  seen.insert(identity.id).inserted
            else { continue }
            out.append(TranscriptParticipant(
                name: identity.resolvedName,
                organization: identity.organization,
                notes: identity.notes
            ))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
