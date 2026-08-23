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
    }

    /// Which engines need a key, and which local unit each local engine is.
    static func isCloud(_ engine: String) -> Bool {
        !["parakeet", "cohere", "whisper"].contains(engine)
    }

    static func settings(engine: String, diarizer: String) -> AppSettings {
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
        if isCloud(engine) {
            settings.processing.transcription = .openAI
            settings.models.transcription = engine
        } else {
            settings.processing.transcription = .local
            settings.processing.localTranscriptionModel =
                LocalTranscriptionModel(rawValue: engine) ?? .parakeet
        }
        settings.processing.diarization = diarizer == "cloud" ? .openAI : .local
        return settings
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
        var engines = options.engines
        if engines.isEmpty { engines = ["parakeet"] }

        let hasKey = !(ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? "").isEmpty
        let cloudEngines = engines.filter(isCloud)
        if !cloudEngines.isEmpty && !hasKey {
            note("skipping \(cloudEngines.joined(separator: ", ")): OPENAI_API_KEY is not set")
            engines = engines.filter { !isCloud($0) }
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
        for engine in engines {
            for benchCase in cases {
                guard FileManager.default.fileExists(atPath: benchCase.audio.path) else {
                    note("missing audio for \(benchCase.truth.meeting): run scripts/fetch-bench-audio.sh")
                    failures.append("\(benchCase.truth.meeting): no audio")
                    continue
                }
                if let expected = manifest?.audio[benchCase.truth.meeting] {
                    let actual = (try? sha256(of: benchCase.audio)) ?? ""
                    guard actual == expected else {
                        note("\(benchCase.truth.meeting): audio hashes \(actual), manifest says \(expected)")
                        failures.append("\(benchCase.truth.meeting): checksum")
                        continue
                    }
                }
                do {
                    let row = try await runOne(
                        benchCase, engine: engine, options: options, backends: backends
                    )
                    rows.append(row)
                    report(row)
                    if let baselines {
                        let key = BenchBaselines.key(
                            engine: engine, diarizer: options.diarizer,
                            meeting: benchCase.truth.meeting
                        )
                        let broken = baselines.regressions(key: key, score: row.score)
                        for entry in broken { note("regression \(key): \(entry)") }
                        failures.append(contentsOf: broken.map { "\(key): \($0)" })
                    }
                } catch {
                    note("\(benchCase.truth.meeting) on \(engine) failed: \(error)")
                    failures.append("\(benchCase.truth.meeting) on \(engine)")
                }
            }
        }

        if let out = options.out {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(rows) { try? data.write(to: out) }
            note("wrote \(rows.count) results to \(out.path)")
        }
        summarise(rows)
        if !failures.isEmpty {
            note("")
            note("\(failures.count) case(s) failed: \(failures.joined(separator: "; "))")
            return 1
        }
        return 0
    }

    static func runOne(
        _ benchCase: Case, engine: String, options: Options, backends: ProcessingBackends
    ) async throws -> Row {
        let scratchRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("meettape-bench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchRoot) }

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
            engine: engine,
            diarizer: options.diarizer,
            score: BenchScorer.score(truth: benchCase.truth, utterances: utterances),
            processingSeconds: elapsed,
            audioSeconds: imported.durationSeconds,
            state: final.processing.state.rawValue,
            transcriptionModels: Array(Set((raw?.chunks ?? []).map(\.model))).sorted(),
            diarizationBackends: Array(Set(runs.map(\.backend))).sorted()
        )
    }

    static func report(_ row: Row) {
        let score = row.score
        print("")
        print("\(score.meeting)  \(row.engine) + \(row.diarizer) diarization  [\(row.state)]")
        print(String(format: "  WER                 %5.1f%%   (no filler %.1f%%)",
                     score.wer * 100, score.werNoFiller * 100))
        print(String(format: "  words               %5d ref / %d hyp",
                     score.referenceWords, score.hypothesisWords))
        print(String(format: "  attribution         %5.1f%%   (of labelled %.1f%%)",
                     score.attribution * 100, score.attributionOfLabelled * 100))
        print("  speakers            \(score.hypothesisSpeakers) found / \(score.referenceSpeakers) true")
        if let der = score.der {
            print(String(format: "  DER                 %5.1f%%   (miss %.1f  FA %.1f  conf %.1f)",
                         der * 100, (score.derMissed ?? 0) * 100,
                         (score.derFalseAlarm ?? 0) * 100, (score.derConfusion ?? 0) * 100))
        }
        print(String(format: "  repeated 8-grams    %5d     (%.2f%% of the stream)",
                     score.repeatedNgrams, score.repeatedShare * 100))
        print(String(format: "  overlapping lines   %5d     worst %.1fs",
                     score.overlappingPairs, score.worstOverlapSeconds))
        print(String(format: "  RTFx                %5.1f     (%.0fs audio in %.0fs)",
                     row.audioSeconds / max(row.processingSeconds, 0.001),
                     row.audioSeconds, row.processingSeconds))
    }

    static func summarise(_ rows: [Row]) {
        guard rows.count > 1 else { return }
        print("")
        print("  engine      cases   WER   no filler   attribution   DER   repeats")
        for engine in Array(Set(rows.map(\.engine))).sorted() {
            let group = rows.filter { $0.engine == engine }
            let ders = group.compactMap(\.score.der)
            print(String(
                format: "  %-10s %5d  %5.1f%%     %5.1f%%        %5.1f%%  %5.1f%%   %d",
                (engine as NSString).utf8String!, group.count,
                median(group.map(\.score.wer)) * 100,
                median(group.map(\.score.werNoFiller)) * 100,
                median(group.map(\.score.attribution)) * 100,
                ders.isEmpty ? 0 : median(ders) * 100,
                group.reduce(0) { $0 + $1.score.repeatedNgrams }
            ))
        }
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }
}
