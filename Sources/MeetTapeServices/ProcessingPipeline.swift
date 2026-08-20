import AVFoundation
import Foundation
import MeetTapeAudio
import MeetTapeCore
import MeetTapeIntegrations
import MeetTapeSpeakers

/// Runs a meeting through transcription, diarization, speaker resolution and
/// enrichment.
///
/// Every stage commits its state to disk before the next begins, and every stage
/// after `audio_safe` is retryable. Nothing here ever deletes or rewrites source
/// audio: a failure leaves the recording exactly where it was and the job waiting.
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

    /// Runs or resumes a meeting. Safe to call repeatedly; a meeting already in
    /// flight is left alone.
    public func process(meetingID: String) async {
        guard !running.contains(meetingID) else { return }
        guard let found = repository.findMeeting(id: meetingID) else { return }
        running.insert(meetingID)
        await jobLock.acquire()
        var holdsSlot = true
        defer {
            running.remove(meetingID)
            if holdsSlot { jobLock.release() }
        }

        var metadata = found.metadata
        let store = found.store
        let settings = settingsProvider()

        while let stage = metadata.processing.resumeStage, stage != .complete {
            do {
                // Capture always wins. A job started before a meeting parks here
                // between stages rather than competing for the microphone, the
                // disk and the Neural Engine with a live recording.
                //
                // The slot is handed back while waiting: one heavy job at a time
                // should mean one job doing work, not one job holding the queue
                // shut for the length of somebody's call.
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
                    try await runEnrichment(store: store, metadata: &metadata, settings: settings)
                    try await finish(store: store, metadata: &metadata, settings: settings)
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
                let failure = (error as? ProcessingError) ?? .transport(reason: "unknown")
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
                // failure message tells the user MeetTape will try again. Attempts
                // are bounded so a persistent outage stops asking.
                let attempts = metadata.processing.attemptCount(for: stage)
                if failure.isRetryable, attempts < Self.maxAttemptsPerStage {
                    await wait(retryDelay(after: failure, attempt: attempts))
                    metadata.processing.advance(to: stage, at: clock.now)
                    continue
                }
                onFailure(metadata.id, failure)
                // Nothing else will read the decoded working copies now.
                scratch.discard(meetingID: metadata.id)
                return
            }
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
        guard let found = repository.findMeeting(id: meetingID) else { return }
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
            try store.writeMetadata(metadata)
            return
        }
        // Through updateMetadata so the read and the write are one operation: a
        // rename landing between them would otherwise be overwritten.
        try store.updateMetadata { current in
            current.processing = metadata.processing
            current.durationSeconds = metadata.durationSeconds
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
        if !diarizer.producesTranscript || transcriber.isLocal {
            let track = diarizedTrack(metadata)
            if !tracks.contains(track) { tracks.append(track) }
        }
        guard !tracks.isEmpty else { return }

        if transcriber.isLocal { try await prepareLocalModels(metadata: metadata) }
        let timeline = try store.readTimeline()
        for track in tracks {
            let segments = timeline.segments(track: track)
            guard !segments.isEmpty else { continue }
            if transcriber.limits.requiresChunking {
                try await runChunks(
                    store: store, metadata: &metadata, track: track, segments: segments,
                    model: transcriber.identifier
                ) { url, _ in
                    let output = try await transcriber.transcribe(audio: url, progress: { _ in })
                    return output
                }
            } else {
                try await runWholeTrack(
                    store: store, metadata: &metadata, track: track,
                    segments: segments, timeline: timeline, backend: transcriber
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
        segments: [RecordedSegment],
        timeline: RecordingTimeline,
        backend: any TranscriptionBackend
    ) async throws {
        var raw = try store.readRawTranscript()
        let chunkID = "\(track.rawValue)_full"
        guard !raw.chunks.contains(where: { $0.id == chunkID }) else { return }
        guard let audio = try scratch.trackAudio(
            meetingID: metadata.id, track: track, segments: segments,
            segmentsDirectory: store.layout.segments
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

        raw.chunks.append(RawTranscriptChunk(
            id: chunkID,
            track: track,
            timelineOffset: timeline.leadIn(track: track),
            durationSeconds: output.durationSeconds ?? segments.reduce(0) { $0 + $1.seconds },
            model: backend.identifier,
            responseFormat: backend.producesWordTimestamps ? "local_words" : "local_segments",
            segments: output.segments,
            rawResponseFile: nil
        ))
        try store.writeRawTranscript(raw)
    }

    /// Works out who spoke when on the track that holds unknown people.
    private func runDiarization(
        store: MeetingStore, metadata: inout MeetingMetadata, settings: AppSettings
    ) async throws {
        let diarizer = backends.diarization(settings, settings.models.diarization)
        let track = diarizedTrack(metadata)
        let timeline = try store.readTimeline()
        let segments = timeline.segments(track: track)
        guard !segments.isEmpty else { return }

        if diarizer.isLocal { try await prepareLocalModels(metadata: metadata) }

        if diarizer.limits.requiresChunking {
            try await runChunkedDiarization(
                store: store, metadata: &metadata, track: track,
                segments: segments, backend: diarizer
            )
        } else {
            try await runWholeTrackDiarization(
                store: store, metadata: &metadata, track: track, segments: segments,
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
        segments: [RecordedSegment],
        backend: any DiarizationBackend
    ) async throws {
        // Words already on this track came from the transcription backend, so
        // these chunks are here for the labels alone and must not be assembled
        // as a second copy of the transcript.
        let existing = try store.readRawTranscript()
        let purpose: RawChunkPurpose =
            existing.chunks(track: track, purpose: .words).isEmpty ? .words : .speakers

        try await runChunks(
            store: store, metadata: &metadata, track: track, segments: segments,
            model: backend.identifier, purpose: purpose
        ) { url, _ in
            let output = try await backend.diarize(audio: url, progress: { _ in })
            return TranscriptionOutput(
                segments: output.segments, text: "", rawBody: output.rawBody
            )
        }

        let raw = try store.readRawTranscript()
        var intervals: [DiarizationInterval] = []
        var speech: [String: Double] = [:]
        for chunk in raw.chunks(track: track, purpose: purpose) {
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
    private func runWholeTrackDiarization(
        store: MeetingStore,
        metadata: inout MeetingMetadata,
        track: CaptureTrack,
        segments: [RecordedSegment],
        timeline: RecordingTimeline,
        backend: any DiarizationBackend
    ) async throws {
        var diarization = try store.readRawDiarization()
        guard diarization.activeRun(track: track) == nil else { return }
        guard let audio = try scratch.trackAudio(
            meetingID: metadata.id, track: track, segments: segments,
            segmentsDirectory: store.layout.segments
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

    /// Chunks a track, sends each chunk, and records results as they arrive so an
    /// interrupted run resumes at the chunk it stopped on.
    private func runChunks(
        store: MeetingStore,
        metadata: inout MeetingMetadata,
        track: CaptureTrack,
        segments: [RecordedSegment],
        model: String,
        purpose: RawChunkPurpose = .words,
        send: @Sendable @escaping (URL, String) async throws -> TranscriptionOutput
    ) async throws {
        let exporter = ChunkExporter()
        let stream = TrackAudioStream(
            segments: segments,
            segmentsDirectory: store.layout.segments,
            format: exporter.readFormat
        )
        let duration = stream.durationSeconds
        guard duration > 0.5 else { return }

        // A pause-aware boundary needs an energy profile; skip the pass entirely
        // for recordings short enough to send in one request.
        let planner = ChunkPlanner(configuration: chunking)
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
            let chunkID = "\(track.rawValue)_\(plan.chunkID)"
            if raw.chunks.contains(where: { $0.id == chunkID }) { continue }

            let audioURL = workingDirectory.appendingPathComponent("\(chunkID).m4a")
            let frames = try exporter.export(
                plan: plan, segments: segments, segmentsDirectory: store.layout.segments, to: audioURL
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
        let maxConcurrentUploads = 3
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
                raw.chunks.append(RawTranscriptChunk(
                    id: chunk.chunkID,
                    track: track,
                    timelineOffset: chunk.plan.start + leadIn,
                    durationSeconds: chunk.plan.duration,
                    model: model,
                    responseFormat: response.segments.contains { $0.speaker != nil }
                        ? "diarized_json" : "verbose_json",
                    segments: response.segments,
                    rawResponseFile: response.rawBody == nil ? nil : "api/\(chunk.chunkID).json",
                    purpose: purpose
                ))
                try store.writeRawTranscript(raw)
                report(metadata, chunks: (raw.chunks(track: track).count, plans.count))
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
        let raw = try store.readRawTranscript()
        guard !raw.chunks.isEmpty else { return }
        let diarization = try store.readRawDiarization()

        let assembler = TranscriptAssembler()
        let transcript = assembler.assemble(
            raw: raw, diarization: diarization,
            micTrackIsLocalUser: metadata.source.micTrackIsLocalUser, generatedAt: clock.now
        )
        try store.writeCanonicalTranscript(transcript)

        var speakers = try store.readSpeakerMap()
        if metadata.source.micTrackIsLocalUser, speakers.entries[SpeakerLabel.localUser] == nil {
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

        try await recognizeVoices(store: store, metadata: &metadata, settings: settings)
        try await learnLocalUserVoice(store: store, metadata: metadata, settings: settings)
        try await suggestSpeakerNames(store: store, metadata: &metadata, settings: settings)
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
                    quality: cluster.quality
                ))
            }
        }
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

            let segments = timeline.segments(track: run.track)
            guard !segments.isEmpty else { continue }
            guard await localModelsAvailable() else { return }
            guard let audio = try scratch.trackAudio(
                meetingID: metadata.id, track: run.track, segments: segments,
                segmentsDirectory: store.layout.segments
            ) else { continue }

            let leadIn = timeline.leadIn(track: run.track)
            let wanted = Set(missing.map(\.id))
            let intervals = run.intervals
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
        let segments = timeline.segments(track: .mic)
        guard !segments.isEmpty else { return }
        guard await localModelsAvailable() else { return }
        guard let audio = try scratch.trackAudio(
            meetingID: metadata.id, track: .mic, segments: segments,
            segmentsDirectory: store.layout.segments
        ) else { return }

        guard let sample = try await embed(audio) else { return }
        // Declined when the microphone track's dominant voice is somebody else
        // on this call. Not a failure: the meeting is fine, the profile simply
        // learns nothing from it.
        guard let status = try await service.learnLocalUserVoice(
            meetingID: metadata.id, identityID: identityID, vector: sample.vector,
            speechSeconds: sample.speechSeconds, quality: sample.quality, now: clock.now
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
            $0 != SpeakerLabel.localUser && speakers.entries[$0] == nil
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
        // the one part of MeetTape that needs the cloud, and wanting them by
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
                durationSeconds: metadata.durationSeconds
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

        // mixed.caf is derivable and entirely optional; a failure here must not
        // fail the meeting.
        if !FileManager.default.fileExists(atPath: store.layout.mixedAudio.path) {
            do {
                try AudioMixer().mix(
                    timeline: timeline,
                    segmentsDirectory: store.layout.segments,
                    to: store.layout.mixedAudio
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
    public func rebuildTranscript(meetingID: String) throws {
        guard let found = repository.findMeeting(id: meetingID) else {
            throw StorageError.meetingNotFound(id: meetingID)
        }
        let raw = try found.store.readRawTranscript()
        guard !raw.chunks.isEmpty else { return }
        // The diarization has to come with the words. Without it a locally
        // processed meeting re-assembles with every speaker collapsed into one
        // cluster, and every name in the speaker map stops matching.
        let diarization = try found.store.readRawDiarization()
        let assembler = TranscriptAssembler()
        let transcript = assembler.assemble(
            raw: raw,
            diarization: diarization,
            micTrackIsLocalUser: found.metadata.source.micTrackIsLocalUser,
            generatedAt: clock.now
        )
        try found.store.writeCanonicalTranscript(transcript)
        let speakers = try found.store.readSpeakerMap()
        let renderer = TranscriptRenderer()
        try found.store.writeTranscriptMarkdown(renderer.markdown(
            transcript: transcript,
            speakers: speakers,
            title: found.metadata.displayTitle,
            startedAt: found.metadata.startedAt,
            durationSeconds: found.metadata.durationSeconds
        ))
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
        guard let found = repository.findMeeting(id: meetingID) else {
            throw StorageError.meetingNotFound(id: meetingID)
        }
        let settings = settingsProvider()
        let resolved = try await identity(named: name, existing: identityID)

        var speakers = try found.store.readSpeakerMap()
        speakers.assign(name, to: key, identityID: resolved)
        try found.store.writeSpeakerMap(speakers)
        try rerenderMarkdown(store: found.store, metadata: found.metadata, speakers: speakers)

        if let resolved {
            try await confirmCluster(
                meetingID: meetingID, clusterID: key, identityID: resolved, settings: settings
            )
            try await refreshCachedNames(for: resolved)
        }
        return resolved
    }

    /// Changes the speaker on one transcript line.
    ///
    /// Writes one override. The cluster keeps its name, every other line
    /// assigned to that cluster keeps its name, the raw diarization is
    /// untouched, and nothing is transcribed again.
    @discardableResult
    public func applyUtteranceSpeaker(
        _ name: String, utteranceID: String, meetingID: String, identityID: IdentityID? = nil
    ) async throws -> IdentityID? {
        try await applyUtteranceSpeaker(
            name, utteranceID: utteranceID, meetingID: meetingID,
            identityID: identityID, learning: true
        )
    }

    @discardableResult
    private func applyUtteranceSpeaker(
        _ name: String, utteranceID: String, meetingID: String,
        identityID: IdentityID?, learning: Bool
    ) async throws -> IdentityID? {
        guard let found = repository.findMeeting(id: meetingID) else {
            throw StorageError.meetingNotFound(id: meetingID)
        }
        guard let transcript = try found.store.readCanonicalTranscript(),
              let utterance = transcript.utterances.first(where: { $0.id == utteranceID })
        else {
            // The transcript moved under the correction, which happens when a
            // re-analysis lands between the click and this call. Saying so is
            // the point: returning nil silently left the user watching a name
            // appear and then vanish.
            throw ProcessingError.utteranceNotFound(id: utteranceID)
        }

        let settings = settingsProvider()
        var speakers = try found.store.readSpeakerMap()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            speakers.clearOverride(for: utterance)
            try found.store.writeSpeakerMap(speakers)
            try rerenderMarkdown(store: found.store, metadata: found.metadata, speakers: speakers)
            return nil
        }

        let resolved = try await identity(named: trimmed, existing: identityID)
        speakers.overrideUtterance(
            utterance,
            with: SpeakerAssignment(
                displayName: trimmed, origin: .human, identityID: resolved,
                provenance: .human()
            ),
            at: clock.now
        )
        try found.store.writeSpeakerMap(speakers)
        try rerenderMarkdown(store: found.store, metadata: found.metadata, speakers: speakers)

        if let resolved {
            if learning {
                try await accumulateConfirmedSpeech(
                    store: found.store, metadata: found.metadata, speakers: speakers,
                    identityID: resolved, settings: settings
                )
            }
            try await refreshCachedNames(for: resolved)
        }
        return resolved
    }

    /// Applies one identity to several lines at once.
    ///
    /// Useful where the diarizer put two people in one cluster: the lines that
    /// belong to the other person move without disturbing the cluster or the
    /// lines that were right.
    public func applyUtteranceSpeaker(
        _ name: String, utteranceIDs: [String], meetingID: String, identityID: IdentityID? = nil
    ) async throws {
        var linked = identityID
        // Every override is written first and the profile is considered once at
        // the end. Learning per line would re-embed the whole growing set on
        // each one, so a single thirty-line correction became thirty full-track
        // passes and thirty near-identical vectors.
        for id in utteranceIDs {
            linked = try await applyUtteranceSpeaker(
                name, utteranceID: id, meetingID: meetingID, identityID: linked, learning: false
            )
        }
        guard let linked, let found = repository.findMeeting(id: meetingID) else { return }
        try await accumulateConfirmedSpeech(
            store: found.store, metadata: found.metadata,
            speakers: try found.store.readSpeakerMap(),
            identityID: linked, settings: settingsProvider()
        )
        try await refreshCachedNames(for: linked)
    }

    /// Re-clusters a meeting, optionally at a speaker count the user chose.
    ///
    /// Words are not touched: this re-runs clustering only. Where the prepared
    /// state from the first pass is still in memory it costs about a second on a
    /// 60-minute meeting instead of about fifteen. The previous result stays on
    /// disk, marked inactive, so the change can be undone.
    public func reanalyzeSpeakers(meetingID: String, speakerCount: Int?) async throws {
        guard let found = repository.findMeeting(id: meetingID) else {
            throw StorageError.meetingNotFound(id: meetingID)
        }
        guard let reanalyze = backends.reanalyzeDiarization else { return }
        await gate.waitUntilAllowed()
        await jobLock.acquire()
        defer { jobLock.release() }
        defer { scratch.discard(meetingID: meetingID) }

        let metadata = found.metadata
        let store = found.store
        let settings = settingsProvider()
        let track = diarizedTrack(metadata)
        let timeline = try store.readTimeline()
        let segments = timeline.segments(track: track)
        guard !segments.isEmpty else { return }

        try await prepareLocalModels(metadata: metadata)
        guard let audio = try scratch.trackAudio(
            meetingID: metadata.id, track: track, segments: segments,
            segmentsDirectory: store.layout.segments
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
        try await recordOccurrences(
            meetingID: metadata.id, run: run, chunkEmbeddings: output.chunkEmbeddings
        )

        // The new clusters carry the new run's identifiers, so no name from the
        // previous clustering follows them. Line-level corrections do: they are
        // anchored to a moment rather than to a cluster.
        var metadataCopy = metadata
        let raw = try store.readRawTranscript()
        let transcript = TranscriptAssembler().assemble(
            raw: raw, diarization: diarization,
            micTrackIsLocalUser: metadata.source.micTrackIsLocalUser, generatedAt: clock.now
        )
        try store.writeCanonicalTranscript(transcript)
        try await recognizeVoices(store: store, metadata: &metadataCopy, settings: settings)
        let speakers = try store.readSpeakerMap()
        try rerenderMarkdown(store: store, metadata: metadataCopy, speakers: speakers)
    }

    /// Re-runs identity resolution alone, after the expected-participant list
    /// changed. Cheap: no audio is read and nothing is transcribed.
    public func refreshSpeakerIdentities(meetingID: String) async throws {
        guard let found = repository.findMeeting(id: meetingID) else {
            throw StorageError.meetingNotFound(id: meetingID)
        }
        // Where a cloud diarizer left no vectors this reads a whole track and
        // runs the embedding model, which is a processing stage in everything
        // but name and waits for the same things.
        await gate.waitUntilAllowed()
        await jobLock.acquire()
        defer { jobLock.release() }
        defer { scratch.discard(meetingID: meetingID) }
        var metadata = found.metadata
        try await recognizeVoices(
            store: found.store, metadata: &metadata, settings: settingsProvider()
        )
        let speakers = try found.store.readSpeakerMap()
        try rerenderMarkdown(store: found.store, metadata: metadata, speakers: speakers)
    }

    // MARK: - identity plumbing

    /// The identity a typed name refers to, creating one if it is new.
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
                return try await store.promoteToPerson(identity.id, name: trimmed, now: clock.now)?.id
                    ?? identity.id
            }
            return existing
        }
        let people = try await store.identities(kind: .person)
        if let match = people.first(where: {
            $0.resolvedName.compare(trimmed, options: .caseInsensitive) == .orderedSame
        }) { return match.id }
        return try await store.createPerson(name: trimmed, now: clock.now).id
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
        _ = try await service.confirmCluster(
            meetingID: meetingID,
            cluster: SpeakerClusterInput(
                clusterID: clusterID, track: occurrence.track,
                speechSeconds: occurrence.speechSeconds, centroid: vector
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

        let timeline = try store.readTimeline()
        let segments = timeline.segments(track: track)
        guard !segments.isEmpty else { return }

        // Reading a whole meeting off disk and running the embedding model is
        // the same class of work a processing stage does, so it waits for the
        // same things.
        await gate.waitUntilAllowed()
        await jobLock.acquire()
        defer { jobLock.release() }
        defer { scratch.discard(meetingID: metadata.id) }

        guard await localModelsAvailable() else { return }
        guard let audio = try scratch.trackAudio(
            meetingID: metadata.id, track: track, segments: segments,
            segmentsDirectory: store.layout.segments
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
            settings: settings.processing.speakers, now: clock.now
        )
    }

    /// Rewrites the cached names in every meeting that refers to an identity.
    ///
    /// The name beside an identity in a meeting folder is a cache, so the folder
    /// stays readable on its own. Renaming, promoting or merging updates the
    /// store, and this brings the copies in line without touching a transcript's
    /// words or its raw diarization.
    public func refreshCachedNames(for identityID: IdentityID) async throws {
        guard let service = backends.speakers else { return }
        let store = await service.speakerStore
        guard let identity = try await store.current(identityID) else { return }
        for meetingID in try await store.meetingsReferencing(identityID) {
            guard let found = repository.findMeeting(id: meetingID) else { continue }
            var speakers = try found.store.readSpeakerMap()
            // Only the cached name is rewritten. The identity link stays as it
            // was written, because reads resolve through the merge tombstone
            // and rewriting it would make separating the merge unable to find
            // these entries again: the meeting would stay attributed to the
            // wrong person forever.
            let changed = speakers.refreshName(of: identityID, to: identity.resolvedName)
            guard changed else { continue }
            try found.store.writeSpeakerMap(speakers)
            try rerenderMarkdown(store: found.store, metadata: found.metadata, speakers: speakers)
        }
    }

    private func rerenderMarkdown(
        store: MeetingStore, metadata: MeetingMetadata, speakers: SpeakerMap
    ) throws {
        guard let transcript = try store.readCanonicalTranscript() else { return }
        try store.writeTranscriptMarkdown(TranscriptRenderer().markdown(
            transcript: transcript,
            speakers: speakers,
            title: metadata.displayTitle,
            startedAt: metadata.startedAt,
            durationSeconds: metadata.durationSeconds
        ))
    }
}
