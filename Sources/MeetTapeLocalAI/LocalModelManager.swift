import Foundation
import FluidAudio
import MeetTapeCore
import WhisperKit

/// Owns the on-disk speech models: what is installed, how to install it, and
/// the loaded handles the backends run against.
///
/// Recording never waits on this. A meeting that finishes while the models are
/// still downloading queues, and processing starts when they arrive.
public actor LocalModelManager {
    /// Immutable and Sendable, so the settings panel can show the path
    /// without hopping to this actor.
    public nonisolated let locations: LocalModelLocations
    private let receipts: LocalModelReceiptStore
    private var state: LocalModelState
    private var whisper: WhisperKit?
    private var diarizerModels: OfflineDiarizerModels?
    private var installTask: Task<LocalModelReceipt, Error>?
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
        onStateChange: @escaping @Sendable (LocalModelState) -> Void = { _ in }
    ) {
        let locations = LocalModelLocations(applicationSupport: applicationSupport)
        self.locations = locations
        self.receipts = LocalModelReceiptStore(locations: locations)
        self.onStateChange = onStateChange
        if let receipt = receipts.read(), Self.filesPresent(locations, receipt) {
            state = receipt.matchesCurrentBuild ? .installed(receipt) : .outdated(receipt)
        } else {
            state = .notInstalled
        }
    }

    public var currentState: LocalModelState { state }

    public var isInstalled: Bool { state.isUsable }

    /// The three CoreML directories the transcriber needs, plus the diarizer's
    /// own directory. Checked on disk rather than trusted from the receipt, so a
    /// user who deleted the folder sees "not installed" instead of a failure
    /// halfway through a meeting.
    private static func filesPresent(_ locations: LocalModelLocations, _ receipt: LocalModelReceipt) -> Bool {
        let manager = FileManager.default
        let folder = URL(fileURLWithPath: receipt.whisperFolderPath)
        for name in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            let compiled = folder.appendingPathComponent("\(name).mlmodelc")
            let package = folder.appendingPathComponent("\(name).mlpackage")
            guard manager.fileExists(atPath: compiled.path) || manager.fileExists(atPath: package.path)
            else { return false }
        }
        guard manager.fileExists(atPath: locations.diarizerDirectory.path) else { return false }
        // The tokenizer lives beside the weights and is fetched separately.
        // Without it, `download: false` still reaches the network on the first
        // transcription, which is the one thing an installed machine must not
        // do. Its absence means the install is incomplete, not usable.
        let tokenizers = locations.whisperBase
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("openai", isDirectory: true)
        guard let contents = try? manager.contentsOfDirectory(atPath: tokenizers.path),
              !contents.isEmpty
        else { return false }
        return true
    }

    private func publish(_ newState: LocalModelState) {
        // Progress arrives on its own tasks with no ordering against the
        // install's own transitions. One landing after the install completed
        // would put the manager back into `downloading`, where every load
        // throws "not installed" and the next call re-downloads everything.
        if newState.isBusy, !state.isBusy, state.isUsable { return }
        state = newState
        onStateChange(newState)
    }

    // MARK: - install

    /// Downloads and loads both model sets once. Safe to call again while it is
    /// running: the second caller joins the first.
    @discardableResult
    public func install() async throws -> LocalModelReceipt {
        if case .installed(let receipt) = state { return receipt }
        // Files pinned by an older build still work. Re-fetching 650 MB from
        // inside a processing stage is the Re-download button's decision, not
        // this one's.
        if case .outdated(let receipt) = state, Self.filesPresent(locations, receipt) {
            return receipt
        }
        if let installTask { return try await installTask.value }

        // `self` is captured strongly on purpose: the install must finish and
        // write its receipt even if nothing else is holding the manager.
        let task = Task<LocalModelReceipt, Error> { [locations, self] in
            publish(.downloading(fraction: 0, detail: "Preparing"))
            try FileManager.default.createDirectory(at: locations.whisperBase, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: locations.diarizerDirectory, withIntermediateDirectories: true)

            // Whisper is about 97% of the bytes, so it drives the progress bar
            // and the diarizer is the last slice.
            let whisperFolder = try await WhisperKit.download(
                variant: LocalSpeechStack.whisperModel,
                downloadBase: locations.whisperBase,
                progressCallback: { progress in
                    let fraction = min(max(progress.fractionCompleted, 0), 1) * 0.9
                    Task {
                        await self.publish(
                            .downloading(fraction: fraction, detail: "Downloading speech model")
                        )
                    }
                }
            )

            // Loading once here pulls the tokenizer into the same directory and
            // compiles the CoreML models, so the first real meeting does not pay
            // either cost and neither needs the network.
            publish(.downloading(fraction: 0.9, detail: "Preparing speech model"))
            let pipeline = try await WhisperKit(WhisperKitConfig(
                model: LocalSpeechStack.whisperModel,
                downloadBase: locations.whisperBase,
                modelFolder: whisperFolder.path,
                verbose: false,
                logLevel: .error,
                prewarm: false,
                load: true,
                download: false
            ))
            whisper = pipeline

            publish(.downloading(fraction: 0.94, detail: "Downloading speaker models"))
            let models = try await OfflineDiarizerModels.load(from: locations.diarizerDirectory)
            diarizerModels = models

            let receipt = LocalModelReceipt(
                whisperVariant: LocalSpeechStack.whisperModel,
                whisperFolderPath: whisperFolder.path,
                whisperBytes: DirectorySize.bytes(of: locations.whisperBase),
                diarizerBytes: DirectorySize.bytes(of: locations.diarizerDirectory),
                installedAt: Date(),
                whisperPackage: LocalSpeechStack.whisperPackage,
                diarizerPackage: LocalSpeechStack.diarizerPackage
            )
            try Task.checkCancellation()
            try receipts.write(receipt)
            publish(.installed(receipt))
            Log.processing.info(
                "local models installed: whisper \(receipt.whisperBytes / 1_048_576, privacy: .public)MB, diarizer \(receipt.diarizerBytes / 1_048_576, privacy: .public)MB"
            )
            return receipt
        }
        installTask = task
        defer { installTask = nil }
        do {
            return try await task.value
        } catch {
            publish(.failed(Self.message(for: error)))
            throw error
        }
    }

    /// Removes both model sets. Everything here is re-downloadable, and nothing
    /// a user recorded lives in these directories.
    public func removeInstalledModels() throws {
        // Cancel first. An install left running would finish writing the files
        // the user just asked to delete, rewrite the receipt and flip the panel
        // back to installed.
        installTask?.cancel()
        installTask = nil
        whisper = nil
        diarizerModels = nil
        try? FileManager.default.removeItem(at: locations.whisperBase)
        try? FileManager.default.removeItem(at: locations.diarizerDirectory)
        receipts.clear()
        publish(.notInstalled)
    }

    /// Waits for an install already running, and refuses rather than starting
    /// one.
    ///
    /// For the work that happens because voice memory is on rather than because
    /// the user chose a local backend. A cloud-only configuration must not
    /// discover, mid-meeting, that it is fetching 650 MB nobody asked for.
    public func ensureInstalled() async throws {
        if state.isUsable { return }
        if let installTask {
            _ = try await installTask.value
            return
        }
        throw LocalModelError.notInstalled
    }

    public func retry() async throws {
        publish(.notInstalled)
        _ = try await install()
    }

    // MARK: - loading

    /// The loaded transcriber.
    ///
    /// `modelFolder` is passed explicitly on every load. WhisperKit with
    /// `download: false` does not resolve its own download cache and fails with
    /// "Model folder is not set", so leaving it out turns an offline machine
    /// into a broken one.
    ///
    /// Kept inside the actor because `WhisperKit` is not `Sendable`, which has a
    /// useful consequence: every heavy local job runs one at a time, so
    /// transcription and diarization cannot contend for the Neural Engine.
    internal func loadedWhisper() async throws -> WhisperKit {
        if let whisper { return whisper }
        guard let receipt = installedReceipt() else { throw LocalModelError.notInstalled }
        let pipeline = try await WhisperKit(WhisperKitConfig(
            model: receipt.whisperVariant,
            downloadBase: locations.whisperBase,
            modelFolder: receipt.whisperFolderPath,
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: false
        ))
        whisper = pipeline
        return pipeline
    }

    /// The loaded diarizer models, shared across every manager instance so a
    /// re-analysis does not reload 21 MB of CoreML.
    func loadedDiarizerModels() async throws -> OfflineDiarizerModels {
        if let diarizerModels { return diarizerModels }
        guard installedReceipt() != nil else { throw LocalModelError.notInstalled }
        // Nothing is downloaded from here. Anything missing at this point is a
        // deleted or damaged install, and it should say so rather than quietly
        // pulling 21 MB in the middle of processing a meeting.
        ModelHub.offlineMode = true
        defer { ModelHub.offlineMode = false }
        let models = try await OfflineDiarizerModels.load(from: locations.diarizerDirectory)
        diarizerModels = models
        return models
    }

    /// Frees the loaded models. Called when local processing is switched off, so
    /// a cloud-only user does not carry 600 MB of resident CoreML.
    public func unload() {
        whisper = nil
        diarizerModels = nil
        clearPreparedDiarization()
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

    private func installedReceipt() -> LocalModelReceipt? {
        switch state {
        case .installed(let receipt), .outdated(let receipt): receipt
        default: nil
        }
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

public enum LocalModelError: Error, CustomStringConvertible, Sendable {
    case notInstalled
    case audioUnreadable(String)

    public var description: String {
        switch self {
        case .notInstalled: "the local speech models are not installed"
        case .audioUnreadable(let reason): "audio could not be read: \(reason)"
        }
    }

    public var userMessage: String {
        switch self {
        case .notInstalled:
            "MeetTape needs to download its speech models before it can process this meeting."
        case .audioUnreadable:
            "The recording could not be read for processing."
        }
    }
}
