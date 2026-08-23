import CoreML
import Foundation
import FluidAudio
import MeetTapeAudio
import MeetTapeCore
import WhisperKit

/// Owns the on-disk speech models: what is installed, how to install it, and
/// the loaded handles the backends run against.
///
/// Models install as independent units — one per engine plus the diarizer and
/// the aligner — each with its own directory, receipt and size. Which units a
/// configuration needs is decided in MeetTapeCore; this actor fetches, loads
/// and reports them.
///
/// Recording never waits on this. A meeting that finishes while the models are
/// still downloading queues, and processing starts when they arrive.
public actor LocalModelManager {
    /// Immutable and Sendable, so the settings panel can show the path
    /// without hopping to this actor.
    public nonisolated let locations: LocalModelLocations
    private let receiptStore: LocalModelReceiptStore
    private var receipts: [LocalModelUnit: LocalUnitReceipt]
    /// The units the current configuration needs; what the aggregate state
    /// and `ensureInstalled` are judged against.
    private var required: Set<LocalModelUnit>
    private var state: LocalModelState
    private var whisper: LoadedWhisper?
    private var diarizerModels: OfflineDiarizerModels?
    private var parakeetManager: AsrManager?
    private var cohereModels: CoherePipeline.LoadedModels?
    private var alignerModels: (models: CtcModels, tokenizer: CtcTokenizer)?
    private var installTask: Task<LocalModelSnapshot, Error>?
    /// Segmentation and embeddings for the meeting most recently diarized, so
    /// "re-analyze speakers" re-clusters instead of starting again.
    ///
    /// One entry, and in memory only. `PreparedDiarization` holds decoded audio
    /// and has no public initializer, so it cannot be written to disk; after a
    /// relaunch a re-analysis pays the full pass, which is about 15 seconds for
    /// a 60-minute meeting.
    private var prepared: (key: String, value: PreparedDiarization, source: DiskBackedAudioSampleSource)?
    private let onStateChange: @Sendable (LocalModelState) -> Void

    public init(
        applicationSupport: URL,
        required: Set<LocalModelUnit> = [.whisper, .diarizer],
        onStateChange: @escaping @Sendable (LocalModelState) -> Void = { _ in }
    ) {
        let locations = LocalModelLocations(applicationSupport: applicationSupport)
        self.locations = locations
        self.receiptStore = LocalModelReceiptStore(locations: locations)
        self.onStateChange = onStateChange
        self.required = required
        self.receipts = receiptStore.read()
        self.state = Self.computeState(
            receipts: receipts, required: required, locations: locations
        )
    }

    public var currentState: LocalModelState { state }

    public var isInstalled: Bool { state.isUsable }

    /// The configuration changed which units it needs; re-judge the state.
    public func setRequired(_ units: Set<LocalModelUnit>) {
        required = units
        if installTask == nil { refreshState() }
    }

    private func refreshState() {
        publish(Self.computeState(receipts: receipts, required: required, locations: locations))
    }

    /// The aggregate over the required set: everything present and current is
    /// installed, anything pinned by another build is outdated, anything
    /// missing means the set as a whole is not installed. Checked on disk
    /// rather than trusted from the receipts, so a user who deleted a folder
    /// sees "not installed" instead of a failure halfway through a meeting.
    private static func computeState(
        receipts: [LocalModelUnit: LocalUnitReceipt],
        required: Set<LocalModelUnit>,
        locations: LocalModelLocations
    ) -> LocalModelState {
        let present = receipts.filter { unit, receipt in
            filesPresent(unit, locations: locations, receipt: receipt)
        }
        let snapshot = LocalModelSnapshot(receipts: present)
        guard required.allSatisfy({ present[$0] != nil }) else {
            return required.isEmpty && !present.isEmpty ? .installed(snapshot) : .notInstalled
        }
        let outdated = required.contains { present[$0]?.matchesCurrentBuild(for: $0) == false }
        return outdated ? .outdated(snapshot) : .installed(snapshot)
    }

    private static func filesPresent(
        _ unit: LocalModelUnit, locations: LocalModelLocations, receipt: LocalUnitReceipt?
    ) -> Bool {
        let manager = FileManager.default
        let directory = locations.directory(for: unit)
        switch unit {
        case .whisper:
            let folder = URL(fileURLWithPath: receipt?.detail ?? locations.whisperModelFolder.path)
            for name in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
                let compiled = folder.appendingPathComponent("\(name).mlmodelc")
                let package = folder.appendingPathComponent("\(name).mlpackage")
                guard manager.fileExists(atPath: compiled.path) || manager.fileExists(atPath: package.path)
                else { return false }
            }
            // The tokenizer lives beside the weights and is fetched
            // separately. Without it, `download: false` still reaches the
            // network on the first transcription, which is the one thing an
            // installed machine must not do.
            let tokenizers = locations.whisperBase
                .appendingPathComponent("models", isDirectory: true)
                .appendingPathComponent("openai", isDirectory: true)
            guard let contents = try? manager.contentsOfDirectory(atPath: tokenizers.path),
                  !contents.isEmpty
            else { return false }
            return true
        case .diarizer:
            return manager.fileExists(atPath: directory.path)
        case .parakeet:
            return AsrModels.modelsExist(at: directory, version: .v3, encoderPrecision: .int8)
        case .cohere:
            return ModelNames.CohereTranscribe.requiredModels.allSatisfy {
                manager.fileExists(atPath: directory.appendingPathComponent($0).path)
            }
        case .ctcAligner:
            return CtcModels.modelsExist(at: directory)
                && manager.fileExists(atPath: directory.appendingPathComponent("tokenizer.json").path)
        }
    }

    private func publish(_ newState: LocalModelState) {
        // Progress arrives on its own tasks with no ordering against the
        // install's own transitions. A progress tick that lands after the
        // install settled must not put the manager back into `downloading`:
        // landing after a failure or a delete replaced the Try Again button,
        // or the Download button, with a progress bar that never moves again.
        if newState.isBusy, !state.isBusy, installTask == nil { return }
        state = newState
        onStateChange(newState)
    }

    // MARK: - install

    /// Downloads and loads the given units, or the required set. Safe to call
    /// again while an install runs: the second caller waits, then fetches
    /// whatever its own set still misses.
    @discardableResult
    public func install(
        units requestedUnits: Set<LocalModelUnit>? = nil, force: Bool = false
    ) async throws -> LocalModelSnapshot {
        let wanted = requestedUnits ?? required
        if let installTask {
            _ = try? await installTask.value
        }

        let missing = wanted.filter { unit in
            force || !Self.filesPresent(unit, locations: locations, receipt: receipts[unit])
        }
        if missing.isEmpty {
            refreshState()
            if case .failed(let message) = state { throw LocalModelError.installFailed(message) }
            return LocalModelSnapshot(receipts: receipts)
        }

        // What is on disk right now, so a re-download that fails can fall back
        // to it instead of discarding a working install.
        let fallback = receipts

        // `self` is captured strongly on purpose: the install must finish and
        // write its receipts even if nothing else is holding the manager.
        let task = Task<LocalModelSnapshot, Error> { [self] in
            let ordered = LocalModelUnit.allCases.filter { missing.contains($0) }
            let totalBytes = max(1, ordered.reduce(Int64(0)) { $0 + $1.approximateBytes })
            var completedBytes: Int64 = 0
            for unit in ordered {
                let base = Double(completedBytes) / Double(totalBytes)
                let share = Double(unit.approximateBytes) / Double(totalBytes)
                try Task.checkCancellation()
                try await installUnit(unit, force: force) { fraction, detail in
                    Task { await self.publish(.downloading(
                        fraction: base + share * min(max(fraction, 0), 1), detail: detail
                    )) }
                }
                completedBytes += unit.approximateBytes
            }
            try Task.checkCancellation()
            try receiptStore.write(receipts)
            let snapshot = LocalModelSnapshot(receipts: receipts)
            Log.processing.info(
                "local models installed: \(missing.map(\.rawValue).sorted().joined(separator: ","), privacy: .public), total \(snapshot.totalBytes / 1_048_576, privacy: .public)MB"
            )
            return snapshot
        }
        installTask = task
        publish(.downloading(fraction: 0, detail: "Preparing"))
        defer {
            installTask = nil
            refreshState()
        }
        do {
            return try await task.value
        } catch {
            // Keep whatever survived: a failure on the third unit must not
            // discard the two that installed, and the reason the install
            // failed may be that a folder went away underneath it.
            receipts = fallback.merging(receipts) { _, new in new }
            try? receiptStore.write(receipts)
            let message = Self.message(for: error)
            let usable = Self.computeState(receipts: receipts, required: required, locations: locations)
            installTask = nil
            publish(usable.isUsable ? usable : .failed(message))
            throw error
        }
    }

    /// One unit: fetch, load once so the first meeting pays neither the
    /// download nor the CoreML compile, and record the receipt.
    private func installUnit(
        _ unit: LocalModelUnit, force: Bool,
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws {
        let directory = locations.directory(for: unit)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var detail: String?

        switch unit {
        case .whisper:
            let folder = try await WhisperKit.download(
                variant: LocalSpeechStack.whisperModel,
                downloadBase: locations.whisperBase,
                progressCallback: { update in
                    progress(update.fractionCompleted * 0.9, "Downloading Whisper")
                }
            )
            progress(0.9, "Preparing Whisper")
            whisper = try await LoadedWhisper.load(
                model: LocalSpeechStack.whisperModel,
                downloadBase: locations.whisperBase,
                modelFolder: folder.path
            )
            detail = folder.path

        case .parakeet:
            _ = try await AsrModels.download(
                to: directory, force: force, version: .v3, encoderPrecision: .int8,
                progressHandler: { update in
                    progress(update.fractionCompleted * 0.9, "Downloading Parakeet")
                }
            )
            progress(0.9, "Preparing Parakeet")
            let models = try await AsrModels.load(from: directory, version: .v3, encoderPrecision: .int8)
            parakeetManager = AsrManager(models: models)

        case .cohere:
            try await ModelHub.download(
                .cohereTranscribeCoreml, to: directory,
                progressHandler: { update in
                    progress(update.fractionCompleted * 0.8, "Downloading Cohere Transcribe")
                }
            )
            // The first load compiles for the Neural Engine and takes minutes
            // on some machines; saying so is what stops it reading as a hang.
            progress(0.8, "Preparing Cohere Transcribe — the first time takes a few minutes")
            cohereModels = try await CoherePipeline.loadModels(
                encoderDir: directory, decoderDir: directory, vocabDir: directory
            )

        case .ctcAligner:
            _ = try await CtcModels.download(to: directory, variant: .ctc110m, force: force)
            // The tokenizer is a root file outside the model bundles; fetch it
            // explicitly so alignment never reaches the network mid-meeting.
            if !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("tokenizer.json").path
            ) {
                try await ModelHub.download(
                    .parakeetCtc110m, subdirectory: "tokenizer.json", to: directory
                )
            }
            progress(0.9, "Preparing the aligner")
            let models = try await CtcModels.load(from: directory, variant: .ctc110m)
            let tokenizer = try await CtcTokenizer.load(from: directory)
            alignerModels = (models, tokenizer)

        case .diarizer:
            progress(0, "Downloading speaker models")
            diarizerModels = try await OfflineDiarizerModels.load(from: directory)
        }

        receipts[unit] = LocalUnitReceipt(
            revision: LocalSpeechStack.revision(for: unit),
            bytes: DirectorySize.bytes(of: directory),
            installedAt: Date(),
            detail: detail
        )
    }

    /// Removes every installed unit. Everything here is re-downloadable, and
    /// nothing a user recorded lives in these directories.
    public func removeInstalledModels() throws {
        // Cancel first. An install left running would finish writing the files
        // the user just asked to delete, rewrite the receipts and flip the
        // panel back to installed.
        installTask?.cancel()
        installTask = nil
        unloadAll()
        for unit in LocalModelUnit.allCases {
            try? FileManager.default.removeItem(at: locations.directory(for: unit))
        }
        receipts = [:]
        receiptStore.clear()
        publish(.notInstalled)
    }

    /// Removes one unit's files and receipt.
    public func remove(unit: LocalModelUnit) throws {
        installTask?.cancel()
        installTask = nil
        unload(unit)
        try? FileManager.default.removeItem(at: locations.directory(for: unit))
        receipts[unit] = nil
        try? receiptStore.write(receipts)
        refreshState()
    }

    private func unloadAll() {
        for unit in LocalModelUnit.allCases { unload(unit) }
    }

    private func unload(_ unit: LocalModelUnit) {
        switch unit {
        case .whisper: whisper = nil
        case .parakeet: parakeetManager = nil
        case .cohere: cohereModels = nil
        case .ctcAligner: alignerModels = nil
        case .diarizer: diarizerModels = nil
        }
    }

    /// Waits for an install already running, and refuses rather than starting
    /// one.
    ///
    /// For the work that happens because voice memory is on rather than because
    /// the user chose a local backend. A cloud-only configuration must not
    /// discover, mid-meeting, that it is fetching gigabytes nobody asked for.
    public func ensureInstalled() async throws {
        if let installTask {
            _ = try await installTask.value
        }
        let missing = required.filter { unit in
            !Self.filesPresent(unit, locations: locations, receipt: receipts[unit])
        }
        guard missing.isEmpty else { throw LocalModelError.notInstalled }
    }

    /// Fetches the required units again whatever the current state.
    ///
    /// What the Re-download button calls. Plain `install()` skips files that
    /// are present, which is right for a processing stage and wrong for a user
    /// asking for the versions this build was measured against.
    public func reinstall() async throws {
        _ = try await install(force: true)
    }

    // MARK: - loading

    /// The loaded Whisper transcriber.
    ///
    /// Reached only through this actor, which is what serialises it: every
    /// heavy local job runs one at a time, so transcription, alignment and
    /// diarization cannot contend for the Neural Engine.
    internal func loadedWhisper() async throws -> LoadedWhisper {
        if let whisper { return whisper }
        guard let receipt = receipts[.whisper],
            Self.filesPresent(.whisper, locations: locations, receipt: receipt)
        else { throw LocalModelError.notInstalled }
        let pipeline = try await LoadedWhisper.load(
            model: LocalSpeechStack.whisperModel,
            downloadBase: locations.whisperBase,
            modelFolder: receipt.detail ?? locations.whisperModelFolder.path
        )
        whisper = pipeline
        return pipeline
    }

    /// The loaded diarizer models, shared across every manager instance so a
    /// re-analysis does not reload 21 MB of CoreML.
    func loadedDiarizerModels() async throws -> OfflineDiarizerModels {
        if let diarizerModels { return diarizerModels }
        guard Self.filesPresent(.diarizer, locations: locations, receipt: receipts[.diarizer])
        else { throw LocalModelError.notInstalled }
        // Nothing is downloaded from here. Anything missing at this point is a
        // deleted or damaged install, and it should say so rather than quietly
        // pulling files in the middle of processing a meeting.
        ModelHub.offlineMode = true
        defer { ModelHub.offlineMode = false }
        let models = try await OfflineDiarizerModels.load(from: locations.diarizerDirectory)
        diarizerModels = models
        return models
    }

    private func loadedParakeet() async throws -> AsrManager {
        if let parakeetManager { return parakeetManager }
        guard Self.filesPresent(.parakeet, locations: locations, receipt: receipts[.parakeet])
        else { throw LocalModelError.notInstalled }
        ModelHub.offlineMode = true
        defer { ModelHub.offlineMode = false }
        let models = try await AsrModels.load(
            from: locations.parakeetDirectory, version: .v3, encoderPrecision: .int8
        )
        let manager = AsrManager(models: models)
        parakeetManager = manager
        return manager
    }

    private func loadedCohere() async throws -> CoherePipeline.LoadedModels {
        if let cohereModels { return cohereModels }
        guard Self.filesPresent(.cohere, locations: locations, receipt: receipts[.cohere])
        else { throw LocalModelError.notInstalled }
        let models = try await CoherePipeline.loadModels(
            encoderDir: locations.cohereDirectory,
            decoderDir: locations.cohereDirectory,
            vocabDir: locations.cohereDirectory
        )
        cohereModels = models
        return models
    }

    private func loadedAligner() async throws -> (models: CtcModels, tokenizer: CtcTokenizer) {
        if let alignerModels { return alignerModels }
        guard Self.filesPresent(.ctcAligner, locations: locations, receipt: receipts[.ctcAligner])
        else { throw LocalModelError.notInstalled }
        let models = try await CtcModels.loadDirect(from: locations.alignerDirectory, variant: .ctc110m)
        let tokenizer = try await CtcTokenizer.load(from: locations.alignerDirectory)
        alignerModels = (models, tokenizer)
        return alignerModels!
    }

    // MARK: - transcription and alignment

    /// Parakeet over a whole track, on the actor so it queues behind every
    /// other heavy job.
    func transcribeParakeet(audio: URL) async throws -> (
        text: String, words: [CtcForcedAlignment.AlignedWord], durationSeconds: Double
    ) {
        let manager = try await loadedParakeet()
        var decoderState = TdtDecoderState.make()
        let result = try await manager.transcribe(audio, decoderState: &decoderState)
        let words = buildWordTimings(from: result.tokenTimings ?? []).map {
            CtcForcedAlignment.AlignedWord(
                text: $0.word, start: $0.startTime, end: $0.endTime
            )
        }
        return (result.text, words, result.duration)
    }

    /// Cohere over one chunk, on the actor for the same reason. Text only;
    /// the aligner supplies the timings afterwards.
    func transcribeCohere(audio: URL) async throws -> String {
        let models = try await loadedCohere()
        let samples = try MonoAudioDecoder.loadMono16k(audio)
        guard !samples.isEmpty else { return "" }
        let pipeline = CoherePipeline()
        let result = try await pipeline.transcribeLong(audio: samples, models: models)
        return result.text
    }

    /// Forces the given text against the audio and returns timed segments.
    ///
    /// Words the tokenizer cannot represent keep their place by inheriting the
    /// gap between their timed neighbours, so the output always carries every
    /// word of the input text in order.
    func alignTranscript(audio: URL, text: String) async throws -> [RawTranscriptSegment] {
        let rawWords = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !rawWords.isEmpty else { return [] }
        let loaded = try await loadedAligner()
        let samples = try MonoAudioDecoder.loadMono16k(audio)
        guard !samples.isEmpty else { throw LocalModelError.audioUnreadable(audio.lastPathComponent) }

        let spotter = CtcKeywordSpotter(models: loaded.models)
        let result = try await spotter.spotKeywordsWithLogProbs(
            audioSamples: samples,
            customVocabulary: CustomVocabularyContext(terms: [])
        )
        guard !result.logProbs.isEmpty, result.frameDuration > 0 else {
            throw TranscriptAlignmentRefused(reason: "the aligner produced no frames")
        }

        // The CTC vocabulary has no punctuation or case, so tokenization works
        // on a normalised copy while the output keeps the words as written.
        var tokenized: [CtcForcedAlignment.TokenizedWord] = []
        var alignableIndex: [Int] = []
        for (index, word) in rawWords.enumerated() {
            let bare = word.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" }
            let tokens = bare.isEmpty ? [] : loaded.tokenizer.encode(bare)
            if !tokens.isEmpty {
                tokenized.append(CtcForcedAlignment.TokenizedWord(text: word, tokens: tokens))
                alignableIndex.append(index)
            }
        }
        guard !tokenized.isEmpty,
            let alignedSubset = CtcForcedAlignment.align(
                logProbs: result.logProbs,
                frameDuration: result.frameDuration,
                blankId: spotter.blankId,
                words: tokenized
            )
        else {
            throw TranscriptAlignmentRefused(reason: "no monotonic path through \(rawWords.count) words")
        }

        // Put untokenizable words back, spanning the gap they sit in.
        var timed = [CtcForcedAlignment.AlignedWord?](repeating: nil, count: rawWords.count)
        for (position, word) in alignedSubset.enumerated() {
            timed[alignableIndex[position]] = word
        }
        var full: [CtcForcedAlignment.AlignedWord] = []
        for (index, word) in rawWords.enumerated() {
            if let placed = timed[index] {
                full.append(placed)
            } else {
                let start = full.last?.end ?? 0
                let end = timed[(index + 1)...].compactMap { $0 }.first?.start ?? start
                full.append(CtcForcedAlignment.AlignedWord(
                    text: word, start: start, end: max(start, end)
                ))
            }
        }

        return CtcForcedAlignment.segments(
            from: full,
            pauseSeconds: LocalAlignmentTuning.segmentPauseSeconds,
            maximumSeconds: LocalAlignmentTuning.segmentMaximumSeconds
        )
    }

    // MARK: - prepared diarization cache

    func preparedDiarization(for key: String) -> PreparedDiarization? {
        prepared?.key == key ? prepared?.value : nil
    }

    func cachePreparedDiarization(
        _ value: PreparedDiarization, source: DiskBackedAudioSampleSource, for key: String
    ) {
        if let existing = prepared, existing.key != key { existing.source.cleanup() }
        prepared = (key, value, source)
    }

    public func clearPreparedDiarization() {
        prepared?.source.cleanup()
        prepared = nil
    }

    private static func message(for error: Error) -> String {
        if error is CancellationError { return "Download cancelled." }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return "Could not reach the model server. Check the network and try again."
        }
        return "The speech models could not be installed."
    }
}

public enum LocalModelError: LocalProcessingFailure, CustomStringConvertible, Sendable {
    case notInstalled
    case audioUnreadable(String)
    case installFailed(String)

    public var description: String {
        switch self {
        case .notInstalled: "the local speech models are not installed"
        case .audioUnreadable(let reason): "audio could not be read: \(reason)"
        case .installFailed(let reason): "the models could not be installed: \(reason)"
        }
    }

    public var userMessage: String {
        switch self {
        case .notInstalled:
            "MeetTape needs to download its speech models before it can process this meeting."
        case .audioUnreadable:
            "The recording could not be read for processing."
        case .installFailed:
            "The speech models could not be installed."
        }
    }

    /// None clear by waiting: a download, a readable recording or a different
    /// transcript is what changes the outcome. Retrying the stage would only
    /// repeat the failure.
    public var isRetryable: Bool { false }
}
