import CryptoKit
import Foundation
import MeetTapeAudio
import MeetTapeBench
import MeetTapeCore
import MeetTapeIntegrations
import MeetTapeLocalAI
import MeetTapeServices

/// The benchmark harness.
///
/// Each case imports a window of a published recording through the real
/// `AudioImporter`, runs the real `ProcessingPipeline` over it with the
/// configured backends, and scores the meeting folder that comes out. Nothing
/// here reimplements a pipeline stage, which is the point: a number from the
/// harness is a number from the application.
enum BenchCommand {
    struct Options {
        var suite = "ami-core"
        var meetings: [String] = []
        var truthFiles: [URL] = []
        var engines: [String] = []
        var diarizer = "local"
        var benchmarks = URL(fileURLWithPath: "Benchmarks", isDirectory: true)
        var audioDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/meettape-bench", isDirectory: true)
        var out: URL?
        var baseline: URL?
        var applicationSupport: URL
        /// How many times each case runs. A local decode varies run to run, by
        /// 6.6 points on one observed case, because an alignment refusal
        /// happens or does not; one sample cannot tell that apart from a
        /// change in the code.
        var repeats = 1
        /// Keep each run's meeting folder instead of deleting it. A failed case
        /// is unreadable without the transcript, the manifest and the raw
        /// output it produced.
        var keepScratch = false
    }

    /// Where a kept scratch directory goes: beside `--out` when there is one,
    /// otherwise `bench-scratch` in the working directory, which is the
    /// repository root under `scripts/eval.sh` and is gitignored under that
    /// name.
    static func keepDirectory(_ options: Options) -> URL {
        if let out = options.out { return out.deletingLastPathComponent() }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("bench-scratch", isDirectory: true)
    }

    /// One case, one configuration.
    struct Case {
        var truth: BenchTruth
        var truthPath: URL
        var audio: URL
    }

    struct Row: Codable {
        var engine: String
        var diarizer: String
        var score: BenchScore
        var processingSeconds: Double
        var audioSeconds: Double
        var state: String
        var transcriptionModels: [String]
        var diarizationBackends: [String]
        /// Which run of `--repeats` this row is, from 1. Every run is written
        /// to `--out`, so the spread in the table can be checked against the
        /// rows it came from.
        var run: Int = 1
        /// The meeting folder this row was scored from, when `--keep-scratch`
        /// preserved it.
        var scratch: String?
    }

    /// Which backend an --engine value names.
    ///
    /// A value is a local engine, one of the cloud transcription models, or a
    /// custom cloud identifier written with the `cloud:` prefix. Anything else
    /// is a typo and stops the run: silently routing "parkeet" to the cloud
    /// produced a row labelled with a model nothing ran.
    enum Engine: Equatable {
        case local(LocalTranscriptionModel)
        case cloud(String)

        /// What the row, the baseline key and the table call it.
        var name: String {
            switch self {
            case .local(let model): model.rawValue
            case .cloud(let model): model
            }
        }

        var isCloud: Bool {
            if case .cloud = self { return true }
            return false
        }

        static func parse(_ value: String) -> Engine? {
            if let model = LocalTranscriptionModel(rawValue: value) { return .local(model) }
            if value.hasPrefix("cloud:") {
                let model = String(value.dropFirst("cloud:".count))
                return model.isEmpty ? nil : .cloud(model)
            }
            if AIModelSettings.transcriptionChoices.contains(value) { return .cloud(value) }
            return nil
        }

        static var valid: String {
            (LocalTranscriptionModel.allCases.map(\.rawValue)
                + AIModelSettings.transcriptionChoices
                + ["cloud:<model>"]).joined(separator: ", ")
        }
    }

    static func settings(engine: Engine, diarizer: String) -> AppSettings {
        var settings = AppSettings()
        // The transcript is the measurement. Everything else costs money and
        // changes nothing the scorer reads.
        settings.enrichment = EnrichmentSettings(
            generateTitle: false, generateDescription: false, generateNotes: false,
            generateSummary: false, suggestSpeakers: false
        )
        // A benchmark must not write into the person's voice memory, and a
        // profile learned from AMI audio would follow them into real meetings.
        settings.processing.speakers = SpeakerRecognitionSettings(
            recognizeKnownVoices: false, rememberRecurringVoices: false,
            learnMyVoice: false, learnFromCorrections: false
        )
        switch engine {
        case .cloud(let model):
            settings.processing.transcription = .openAI
            settings.models.transcription = model
        case .local(let model):
            settings.processing.transcription = .local
            settings.processing.localTranscriptionModel = model
        }
        settings.processing.diarization = diarizer == "cloud" ? .openAI : .local
        return settings
    }

    /// One digest per file per invocation. The same recording backs several
    /// cases and several engines, and hashing a 300 MB WAV once per row is
    /// minutes of the run spent re-reading a file that cannot have changed.
    static func sha256(of url: URL, cache: inout [String: String]) throws -> String {
        if let known = cache[url.path] { return known }
        let digest = try sha256(of: url)
        cache[url.path] = digest
        return digest
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            digest.update(data: chunk)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func loadCases(_ options: Options, manifest: BenchManifest?) throws -> [Case] {
        let layout = BenchLayout(root: options.benchmarks)
        var cases: [Case] = []
        for path in options.truthFiles {
            let truth = try BenchTruth.read(from: path)
            let beside = path.deletingLastPathComponent().appendingPathComponent(truth.source)
            let cached = options.audioDirectory.appendingPathComponent(truth.source)
            let audio = FileManager.default.fileExists(atPath: beside.path) ? beside : cached
            cases.append(Case(truth: truth, truthPath: path, audio: audio))
        }
        guard cases.isEmpty else { return cases }

        var names = options.meetings
        if names.isEmpty {
            guard let manifest, let roster = manifest.suites[options.suite] else {
                throw BenchFailure("no suite named \(options.suite) in the manifest")
            }
            names = roster
        }
        for meeting in names {
            let path = layout.truth(meeting: meeting)
            let truth = try BenchTruth.read(from: path)
            cases.append(Case(
                truth: truth, truthPath: path,
                audio: options.audioDirectory.appendingPathComponent(truth.source)
            ))
        }
        return cases
    }

    struct BenchFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static func makeBackends(
        models: LocalModelManager, cloud: OpenAIClient
    ) -> ProcessingBackends {
        // The same wiring MeetTapeRuntime builds, minus the speaker store: the
        // harness must not touch the voice memory of whoever runs it.
        ProcessingBackends(
            transcription: { settings, model in
                ProcessingBackends.transcriptionBackend(
                    settings: settings, model: model,
                    local: { choice in
                        switch choice {
                        case .cohere: CohereTranscriptionBackend(models: models)
                        case .parakeet: ParakeetTranscriptionBackend(models: models)
                        case .whisper: WhisperTranscriptionBackend(models: models)
                        }
                    },
                    cloud: { OpenAITranscriptionBackend(backend: cloud, model: $0) }
                )
            },
            diarization: { settings, model in
                ProcessingBackends.diarizationBackend(
                    settings: settings, model: model,
                    local: { FluidAudioDiarizationBackend(models: models) },
                    cloud: { OpenAIDiarizationBackend(backend: cloud, model: $0) }
                )
            },
            embeddings: FluidAudioEmbeddingExtractor(models: models),
            prepareLocalModels: { [models] in
                _ = try await models.install(units: LocalModelUnit.required(for: AppSettings()))
            },
            aligner: CtcTranscriptAligner(models: models),
            prepareAligner: { [models] in _ = try await models.install(units: [.ctcAligner]) },
            prepareDiarizer: { [models] in _ = try await models.install(units: [.diarizer]) }
        )
    }

    static func run(_ options: Options) async -> Int32 {
        let layout = BenchLayout(root: options.benchmarks)
        let manifest = try? BenchManifest.read(from: layout.manifest)
        let cases: [Case]
        do {
            cases = try loadCases(options, manifest: manifest)
        } catch {
            note("bench: \(error)")
            return 2
        }
        var engines: [Engine] = []
        for value in options.engines {
            guard let engine = Engine.parse(value) else {
                note("bench: unknown --engine \(value). Valid: \(Engine.valid)")
                return 2
            }
            engines.append(engine)
        }
        if engines.isEmpty { engines = [.local(.parakeet)] }

        let hasKey = !(ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? "").isEmpty
        let cloudEngines = engines.filter(\.isCloud)
        if !cloudEngines.isEmpty && !hasKey {
            note("skipping \(cloudEngines.map(\.name).joined(separator: ", ")): OPENAI_API_KEY is not set")
            engines = engines.filter { !$0.isCloud }
        }
        if options.diarizer == "cloud" && !hasKey {
            note("cloud diarization needs OPENAI_API_KEY")
            return 2
        }
        guard !engines.isEmpty else {
            note("nothing to run")
            return 0
        }

        let models = LocalModelManager(applicationSupport: options.applicationSupport)
        let cloud = OpenAIClient(keyProvider: EnvironmentAPIKeyStore())
        let backends = makeBackends(models: models, cloud: cloud)
        let baselines = options.baseline.flatMap { try? BenchBaselines.read(from: $0) }
        if options.baseline != nil && baselines == nil {
            note("bench: no readable baseline at \(options.baseline?.path ?? "")")
            return 2
        }

        var rows: [Row] = []
        var failures: [String] = []
        var digests: [String: String] = [:]
        for engine in engines {
            for benchCase in cases {
                guard FileManager.default.fileExists(atPath: benchCase.audio.path) else {
                    note("missing audio for \(benchCase.truth.meeting): run scripts/fetch-bench-audio.sh")
                    failures.append("\(benchCase.truth.meeting): no audio")
                    continue
                }
                if let expected = manifest?.audio[benchCase.truth.meeting] {
                    let actual = (try? sha256(of: benchCase.audio, cache: &digests)) ?? ""
                    guard actual == expected else {
                        note("\(benchCase.truth.meeting): audio hashes \(actual), manifest says \(expected)")
                        failures.append("\(benchCase.truth.meeting): checksum")
                        continue
                    }
                }
                var runs: [Row] = []
                for run in 1...max(1, options.repeats) {
                    do {
                        var row = try await runOne(
                            benchCase, engine: engine, options: options,
                            backends: backends, run: run
                        )
                        row.run = run
                        runs.append(row)
                        rows.append(row)
                        report(row, of: max(1, options.repeats))
                    } catch {
                        note("\(benchCase.truth.meeting) on \(engine.name) failed: \(error)")
                        failures.append("\(benchCase.truth.meeting) on \(engine.name)")
                    }
                }
                guard let deciding = mean(of: runs) else { continue }
                if runs.count > 1 { reportSpread(runs) }
                if let baselines {
                    let key = BenchBaselines.key(
                        engine: engine.name, diarizer: options.diarizer,
                        meeting: benchCase.truth.meeting
                    )
                    // The mean decides, so one unlucky alignment refusal in
                    // three runs neither fails the gate on its own nor hides
                    // behind a lucky one.
                    let broken = baselines.regressions(key: key, score: deciding)
                    for entry in broken { note("regression \(key): \(entry)") }
                    failures.append(contentsOf: broken.map { "\(key): \($0)" })
                }
            }
        }

        if let out = options.out {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(rows) { try? data.write(to: out) }
            note("wrote \(rows.count) results to \(out.path)")
        }
        summarise(rows, repeats: max(1, options.repeats))
        if !failures.isEmpty {
            note("")
            note("\(failures.count) case(s) failed: \(failures.joined(separator: "; "))")
            return 1
        }
        return 0
    }

    static func runOne(
        _ benchCase: Case, engine: Engine, options: Options, backends: ProcessingBackends,
        run: Int = 1
    ) async throws -> Row {
        // Kept scratch is written where it is wanted from the start rather than
        // copied at the end: a case that throws is exactly the one worth
        // reading, and it never reaches the end.
        var kept: URL?
        let scratchRoot: URL
        if options.keepScratch {
            var name = "\(benchCase.truth.meeting)-\(engine.name)-\(options.diarizer)"
            if options.repeats > 1 { name += "-run\(run)" }
            let destination = keepDirectory(options).appendingPathComponent(name, isDirectory: true)
            try? FileManager.default.removeItem(at: destination)
            scratchRoot = destination
            kept = destination
        } else {
            scratchRoot = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("meettape-bench-\(UUID().uuidString)", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        defer {
            if kept == nil { try? FileManager.default.removeItem(at: scratchRoot) }
        }

        // The truth names a window on the recording, so the harness cuts it.
        // A case with no window scores the whole file, which is what puts the
        // chunk seams under measurement.
        let source: URL
        if let start = benchCase.truth.windowStart {
            let excerpt = scratchRoot.appendingPathComponent("\(benchCase.truth.meeting)-excerpt.wav")
            let seconds = try AudioExcerptCutter().cut(
                source: benchCase.audio, startSeconds: start,
                seconds: benchCase.truth.windowSeconds, to: excerpt
            )
            guard seconds > benchCase.truth.windowSeconds - 1 else {
                throw BenchFailure("the window runs past the end of \(benchCase.audio.lastPathComponent)")
            }
            source = excerpt
        } else {
            source = benchCase.audio
        }

        let archive = scratchRoot.appendingPathComponent("archive", isDirectory: true)
        let repository = MeetingRepository(root: archive)
        let started = Date(timeIntervalSince1970: 1_787_070_000)
        let created = try repository.createMeeting(
            source: .imported, provider: .unknown, startedAt: started,
            titles: TitleCandidates(human: benchCase.truth.meeting, timestampFallback: benchCase.truth.meeting),
            now: started
        )
        let imported = try AudioImporter(segmentSeconds: 30).import(
            source: source, into: created.store, meetingID: created.metadata.id
        )
        var metadata = created.metadata
        metadata.durationSeconds = imported.durationSeconds
        metadata.endedAt = started.addingTimeInterval(imported.durationSeconds)
        metadata.importedOriginalFilename = imported.originalFilename
        metadata.processing.advance(to: .finalizing, at: started)
        metadata.processing.advance(to: .audioSafe, at: started)
        try created.store.writeMetadata(metadata)

        let configuration = settings(engine: engine, diarizer: options.diarizer)
        let pipeline = ProcessingPipeline(
            repository: repository,
            backend: OpenAIClient(keyProvider: EnvironmentAPIKeyStore()),
            backends: backends,
            scratch: ProcessingScratch(root: scratchRoot.appendingPathComponent("scratch")),
            settingsProvider: { configuration }
        )
        let clock = Date()
        await pipeline.process(meetingID: created.metadata.id)
        let elapsed = Date().timeIntervalSince(clock)

        let final = try created.store.readMetadata()
        guard let transcript = try created.store.readCanonicalTranscript() else {
            throw BenchFailure(
                "no transcript: stopped at \(final.processing.state)"
                + " \(final.processing.lastFailure?.message ?? "")"
            )
        }
        let utterances = transcript.utterances.map {
            BenchUtterance(start: $0.start, end: $0.end, text: $0.text, speakerKey: $0.speakerKey)
        }
        let raw = try? created.store.readRawTranscript()
        let runs = (try? created.store.readRawDiarization())?.runs ?? []
        return Row(
            engine: engine.name,
            diarizer: options.diarizer,
            score: BenchScorer.score(truth: benchCase.truth, utterances: utterances),
            processingSeconds: elapsed,
            audioSeconds: imported.durationSeconds,
            state: final.processing.state.rawValue,
            transcriptionModels: Array(Set((raw?.chunks ?? []).map(\.model))).sorted(),
            diarizationBackends: Array(Set(runs.map(\.backend))).sorted(),
            run: run,
            scratch: kept?.path
        )
    }

    static func report(_ row: Row, of repeats: Int = 1) {
        let score = row.score
        print("")
        let label = repeats > 1 ? "  run \(row.run)/\(repeats)" : ""
        print("\(score.meeting)  \(row.engine) + \(row.diarizer) diarization  [\(row.state)]\(label)")
        print(String(format: "  WER                 %5.1f%%   (no filler %.1f%%, conversational %.1f%%)",
                     score.wer * 100, score.werNoFiller * 100, score.werConversational * 100))
        print(String(format: "  ordering floor      %5.1f%%   (at least %.1f%% of WER is not ordering)",
                     score.orderingFloorWer * 100, score.netOfFloorWer * 100))
        print(String(format: "  words               %5d ref / %d hyp   (%.0f/min, %.0f%% of the window is speech)",
                     score.referenceWords, score.hypothesisWords,
                     score.wordsPerMinute, score.speechCoverage * 100))
        print(String(format: "  attribution         %5.1f%%   (of labelled %.1f%%, merged %.1f%%)",
                     score.attribution * 100, score.attributionOfLabelled * 100,
                     score.attributionMerged * 100))
        print(String(format: "  coverage            %5.1f%%   (%d of %d words asked about)",
                     score.attributionCoverage * 100, score.attributionScored,
                     score.attributionScored + score.overlapExcluded))
        print("  speakers            \(score.hypothesisSpeakers) found / \(score.referenceSpeakers) true")
        if let der = score.der {
            print(String(format: "  DER                 %5.1f%%   (miss %.1f  FA %.1f  conf %.1f)",
                         der * 100, (score.derMissed ?? 0) * 100,
                         (score.derFalseAlarm ?? 0) * 100, (score.derConfusion ?? 0) * 100))
            if let strict = score.derStrict {
                print(String(format: "  DER strict          %5.1f%%   (injective mapping, no cluster merging)",
                             strict * 100))
            }
        }
        print(String(format: "  repeated 8-grams    %5d     (%.2f%% of the stream)",
                     score.repeatedNgrams, score.repeatedShare * 100))
        print(String(format: "  overlapping lines   %5d     worst %.1fs",
                     score.overlappingPairs, score.worstOverlapSeconds))
        print(String(format: "  RTFx                %5.1f     (%.0fs audio in %.0fs)",
                     row.audioSeconds / max(row.processingSeconds, 0.001),
                     row.audioSeconds, row.processingSeconds))
        if let scratch = row.scratch { print("  scratch             \(scratch)") }
        // Redirected output is block-buffered, so a run of fourteen cases shows
        // nothing for half an hour and reads as hung.
        fflush(stdout)
    }

    /// What repeated runs of one case did and did not agree on.
    static func reportSpread(_ runs: [Row]) {
        print(String(format: "  over %d runs        WER %.1f%% (%.1f to %.1f)  attribution %.1f%% (%.1f to %.1f)",
                     runs.count,
                     mean(runs.map(\.score.wer)) * 100,
                     (runs.map(\.score.wer).min() ?? 0) * 100,
                     (runs.map(\.score.wer).max() ?? 0) * 100,
                     mean(runs.map(\.score.attribution)) * 100,
                     (runs.map(\.score.attribution).min() ?? 0) * 100,
                     (runs.map(\.score.attribution).max() ?? 0) * 100))
        let ders = runs.compactMap(\.score.der)
        if !ders.isEmpty {
            print(String(format: "                      DER %.1f%% (%.1f to %.1f)",
                         mean(ders) * 100, (ders.min() ?? 0) * 100, (ders.max() ?? 0) * 100))
        }
        fflush(stdout)
    }

    /// The score the baseline check reads when a case ran more than once. The
    /// rule itself is `BenchAggregate.deciding`, where a test can reach it.
    static func mean(of runs: [Row]) -> BenchScore? {
        BenchAggregate.deciding(over: runs.map(\.score))
    }

    static func summarise(_ rows: [Row], repeats: Int = 1) {
        guard rows.count > 1 else { return }
        print("")
        print("  Net is WER with the case's ordering floor taken off, which is a lower bound on")
        print("  the share of WER that is not ordering, not a split of one from the other: the")
        print("  floor is what an oracle transcript pays for reading turns in one stream, and")
        print("  an engine's own errors fall on the same words. Coverage is the share")
        print("  of reference words attribution asked about; the rest overlap another speaker.")
        print("  DER is on the merged mapping, strict on the injective one, and above 100% is")
        print("  arithmetic rather than a defect: false alarm has no upper bound.")
        print("")
        // The count is rows, which is cases times repeats, so it is named for
        // what it counts rather than left saying "cases" over a number three
        // times the roster.
        var header = "  engine       \(repeats > 1 ? "runs" : "case")   WER   floor     net   no filler   conv"
        header += "   attribution   coverage   merged     DER   strict   repeats"
        if repeats > 1 { header += "   WER spread" }
        print(header)
        for engine in Array(Set(rows.map(\.engine))).sorted() {
            let group = rows.filter { $0.engine == engine }
            let ders = group.compactMap(\.score.der)
            let strict = group.compactMap(\.score.derStrict)
            let padded = engine.padding(
                toLength: max(engine.count, 10), withPad: " ", startingAt: 0
            )
            var line = padded.prefix(10) + String(
                format: " %5d  %5.1f%%  %5.1f%%  %5.1f%%     %5.1f%%  %5.1f%%        %5.1f%%     %5.1f%%   %5.1f%%  %5.1f%%   %5.1f%%   %d",
                group.count,
                median(group.map(\.score.wer)) * 100,
                median(group.map(\.score.orderingFloorWer)) * 100,
                median(group.map(\.score.netOfFloorWer)) * 100,
                median(group.map(\.score.werNoFiller)) * 100,
                median(group.map(\.score.werConversational)) * 100,
                median(group.map(\.score.attribution)) * 100,
                median(group.map(\.score.attributionCoverage)) * 100,
                median(group.map(\.score.attributionMerged)) * 100,
                ders.isEmpty ? 0 : median(ders) * 100,
                strict.isEmpty ? 0 : median(strict) * 100,
                group.reduce(0) { $0 + $1.score.repeatedNgrams }
            )
            if repeats > 1 {
                // The widest a single case moved between its own runs, which
                // is the number a tolerance has to clear.
                var widest = 0.0
                for meeting in Set(group.map(\.score.meeting)) {
                    let wers = group.filter { $0.score.meeting == meeting }.map(\.score.wer)
                    widest = max(widest, (wers.max() ?? 0) - (wers.min() ?? 0))
                }
                line += String(format: "   %5.1f points worst case", widest * 100)
            }
            print(line)
        }
        fflush(stdout)
    }

    static func mean(_ values: [Double]) -> Double { BenchAggregate.mean(values) }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }
}
