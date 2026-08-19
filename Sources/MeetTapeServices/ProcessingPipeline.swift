import AVFoundation
import Foundation
import MeetTapeAudio
import MeetTapeCore
import MeetTapeIntegrations

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
    }

    private let repository: MeetingRepository
    private let backend: any AIBackend
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

    /// How many times one stage is attempted before the meeting is left for the
    /// user, and the delays between those attempts.
    static let maxAttemptsPerStage = 3
    static let retryDelaysSeconds: [TimeInterval] = [20, 90]
    static let maxRetryDelaySeconds: TimeInterval = 300

    public init(
        repository: MeetingRepository,
        backend: any AIBackend,
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
        defer { running.remove(meetingID) }

        var metadata = found.metadata
        let store = found.store
        let settings = settingsProvider()

        while let stage = metadata.processing.resumeStage, stage != .complete {
            do {
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

    /// Transcribes the track that belongs to the local user.
    ///
    /// On a remote call this is the microphone, and it is never diarized: the
    /// person holding the microphone is known by construction, and removing them
    /// from the diarization problem measured 97% attribution against 84% for
    /// diarizing the mixed meeting.
    private func runTranscription(
        store: MeetingStore, metadata: inout MeetingMetadata, settings: AppSettings
    ) async throws {
        guard metadata.source.micTrackIsLocalUser else { return }
        let timeline = try store.readTimeline()
        let segments = timeline.segments(track: .mic)
        guard !segments.isEmpty else { return }

        try await runChunks(
            store: store,
            metadata: &metadata,
            track: .mic,
            segments: segments,
            model: settings.models.transcription
        ) { url, model in
            try await self.backend.transcribe(TranscriptionRequest(audio: url, model: model))
        }
    }

    /// Diarizes the track that holds people whose identity is unknown: the remote
    /// track on a call, or the single track of an in-person or imported recording.
    private func runDiarization(
        store: MeetingStore, metadata: inout MeetingMetadata, settings: AppSettings
    ) async throws {
        let timeline = try store.readTimeline()
        let track: CaptureTrack = metadata.source.micTrackIsLocalUser ? .remote : .mic
        let segments = timeline.segments(track: track)
        guard !segments.isEmpty else { return }

        try await runChunks(
            store: store,
            metadata: &metadata,
            track: track,
            segments: segments,
            model: settings.models.diarization
        ) { url, model in
            try await self.backend.diarize(DiarizationRequest(audio: url, model: model))
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
        send: @Sendable @escaping (URL, String) async throws -> TranscriptionResponse
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
        try await withThrowingTaskGroup(of: (PreparedChunk, TranscriptionResponse).self) { group in
            var nextIndex = 0
            while nextIndex < min(maxConcurrentUploads, pending.count) {
                let chunk = pending[nextIndex]
                nextIndex += 1
                group.addTask { (chunk, try await send(chunk.audioURL, model)) }
            }
            while let (chunk, response) = try await group.next() {
                try? store.writeAPIResponse(response.rawBody, named: "\(chunk.chunkID).json")
                raw.chunks.append(RawTranscriptChunk(
                    id: chunk.chunkID,
                    track: track,
                    timelineOffset: chunk.plan.start + leadIn,
                    durationSeconds: chunk.plan.duration,
                    model: model,
                    responseFormat: response.segments.contains { $0.speaker != nil }
                        ? "diarized_json" : "verbose_json",
                    segments: response.segments,
                    rawResponseFile: "api/\(chunk.chunkID).json"
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

        let assembler = TranscriptAssembler()
        let transcript = assembler.assemble(
            raw: raw, micTrackIsLocalUser: metadata.source.micTrackIsLocalUser, generatedAt: clock.now
        )
        try store.writeCanonicalTranscript(transcript)

        var speakers = try store.readSpeakerMap()
        if metadata.source.micTrackIsLocalUser, speakers.entries[SpeakerLabel.localUser] == nil {
            speakers.entries[SpeakerLabel.localUser] = SpeakerAssignment(
                displayName: settings.localUserName, origin: .deterministic
            )
        }
        try store.writeSpeakerMap(speakers)

        guard settings.enrichment.suggestSpeakers else { return }
        // An empty identifier means the user is mid-edit in Settings.
        guard !settings.models.metadata.isEmpty else { return }
        let labels = transcript.speakerKeys.filter { $0 != SpeakerLabel.localUser }
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

        // Suggestions never overwrite a name the user set.
        var updated = try store.readSpeakerMap()
        for suggestion in suggestions where labels.contains(suggestion.label) {
            guard suggestion.confidence >= 0.35, !suggestion.name.isEmpty else { continue }
            updated.applySuggestion(
                SpeakerAssignment(
                    displayName: suggestion.name,
                    origin: .ai,
                    confidence: suggestion.confidence,
                    evidence: suggestion.evidence
                ),
                for: suggestion.label
            )
        }
        try store.writeSpeakerMap(updated)

        var participants = metadata.participants
        for suggestion in suggestions where !participants.contains(where: { $0.displayName == suggestion.name }) {
            participants.append(Participant(displayName: suggestion.name, origin: .ai))
        }
        metadata.participants = participants
    }

    private func runEnrichment(
        store: MeetingStore, metadata: inout MeetingMetadata, settings: AppSettings
    ) async throws {
        guard settings.enrichment.wantsAnything else { return }
        guard !settings.models.metadata.isEmpty else { return }
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

    private func report(_ metadata: MeetingMetadata, chunks: (Int, Int)?) {
        onProgress(Progress(
            meetingID: metadata.id,
            state: metadata.processing.state,
            completedChunks: chunks?.0 ?? 0,
            totalChunks: chunks?.1 ?? 0,
            title: metadata.displayTitle
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
        let assembler = TranscriptAssembler()
        let transcript = assembler.assemble(
            raw: raw,
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
    public func applySpeakerName(
        _ name: String, to key: String, meetingID: String
    ) throws {
        guard let found = repository.findMeeting(id: meetingID) else {
            throw StorageError.meetingNotFound(id: meetingID)
        }
        var speakers = try found.store.readSpeakerMap()
        speakers.assign(name, to: key)
        try found.store.writeSpeakerMap(speakers)

        guard let transcript = try found.store.readCanonicalTranscript() else { return }
        let renderer = TranscriptRenderer()
        try found.store.writeTranscriptMarkdown(renderer.markdown(
            transcript: transcript,
            speakers: speakers,
            title: found.metadata.displayTitle,
            startedAt: found.metadata.startedAt,
            durationSeconds: found.metadata.durationSeconds
        ))
    }
}
