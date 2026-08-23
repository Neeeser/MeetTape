import Foundation
import MeetTapeAudio
import MeetTapeCore
import MeetTapeLocalAI
import MeetTapeSpeakers

// Developer tooling. Not part of the application bundle and not something a user
// ever runs: this is how the numbers the local stack ships against get checked
// again, on this machine, against audio somebody is allowed to use.
//
//   meettape-eval asr       --audio FILE [--engine whisper|parakeet|cohere]
//   meettape-eval align     --audio FILE --transcript FILE
//   meettape-eval diarize   --audio FILE [--fa 0.07 --fa 0.20] [--speakers N]
//   meettape-eval identity  --audio FILE [--audio FILE ...]
//   meettape-eval voices
//
// The audio never leaves the machine and nothing here writes to a meeting.

struct Arguments {
    var command: String
    var audio: [URL] = []
    var acousticScalings: [Double] = []
    var speakerCount: Int?
    var engine = "whisper"
    var transcript: URL?
    var applicationSupport: URL

    init?(_ raw: [String]) {
        guard let command = raw.first else { return nil }
        self.command = command
        var support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MeetTape", isDirectory: true)
        var index = 1
        while index < raw.count {
            let flag = raw[index]
            index += 1
            guard index < raw.count else { break }
            let value = raw[index]
            index += 1
            switch flag {
            case "--audio": audio.append(URL(fileURLWithPath: value))
            case "--fa": if let scaling = Double(value) { acousticScalings.append(scaling) }
            case "--speakers": speakerCount = Int(value)
            case "--engine": engine = value
            case "--transcript": transcript = URL(fileURLWithPath: value)
            case "--support": support = URL(fileURLWithPath: value)
            default: break
            }
        }
        applicationSupport = support
    }
}

func note(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}

/// Peak resident set size, so a run reports the high-water mark rather than
/// whatever happens to be resident when it finishes.
func peakResidentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
    )
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.resident_size_max : 0
}

func megabytes(_ bytes: UInt64) -> String { String(format: "%.0f MB", Double(bytes) / 1_048_576) }

func usage() -> Never {
    note("""
        usage:
          meettape-eval asr      --audio FILE [--engine whisper|parakeet|cohere]
          meettape-eval align    --audio FILE --transcript FILE
          meettape-eval diarize  --audio FILE [--fa 0.07 --fa 0.20] [--speakers N]
          meettape-eval identity --audio FILE [--audio FILE ...]
          meettape-eval voices
        """)
    exit(2)
}

guard let arguments = Arguments(Array(CommandLine.arguments.dropFirst())) else { usage() }

let manager = LocalModelManager(applicationSupport: arguments.applicationSupport)

switch arguments.command {
case "asr":
    guard let audio = arguments.audio.first else { usage() }
    let backend: any TranscriptionBackend
    switch arguments.engine {
    case "whisper":
        _ = try await manager.install(units: [.whisper])
        backend = WhisperTranscriptionBackend(models: manager)
    case "parakeet":
        _ = try await manager.install(units: [.parakeet])
        backend = ParakeetTranscriptionBackend(models: manager)
    case "cohere":
        _ = try await manager.install(units: [.cohere])
        backend = CohereTranscriptionBackend(models: manager)
    default:
        usage()
    }
    let seconds = MonoAudioDecoder.durationSeconds(audio)
    let started = Date()
    let output = try await backend.transcribe(audio: audio) { _ in }
    let elapsed = Date().timeIntervalSince(started)
    print("engine          \(backend.identifier)")
    print("file            \(audio.lastPathComponent)")
    print("audio           \(String(format: "%.1f", seconds))s")
    print("processing      \(String(format: "%.1f", elapsed))s")
    print("RTFx            \(String(format: "%.1f", seconds / max(elapsed, 0.001)))")
    print("segments        \(output.segments.count)")
    print("words           \(output.wordCount)")
    print("word timings    \(output.hasWordTimings)")
    print("peak resident   \(megabytes(peakResidentBytes()))")
    print("---")
    print(output.text)

case "align":
    guard let audio = arguments.audio.first, let transcriptURL = arguments.transcript else { usage() }
    let text = try String(contentsOf: transcriptURL, encoding: .utf8)
    _ = try await manager.install(units: [.ctcAligner])
    let seconds = MonoAudioDecoder.durationSeconds(audio)
    let started = Date()
    let segments = try await CtcTranscriptAligner(models: manager).align(audio: audio, text: text)
    let elapsed = Date().timeIntervalSince(started)
    let wordCount = segments.reduce(0) { $0 + ($1.words?.count ?? 0) }
    let inputWords = text.split(whereSeparator: \.isWhitespace).count
    print("file            \(audio.lastPathComponent)")
    print("audio           \(String(format: "%.1f", seconds))s")
    print("processing      \(String(format: "%.1f", elapsed))s")
    print("RTFx            \(String(format: "%.1f", seconds / max(elapsed, 0.001)))")
    print("input words     \(inputWords)")
    print("aligned words   \(wordCount)")
    print("segments        \(segments.count)")
    for segment in segments {
        print(String(format: "%8.2f –%8.2f  %@", segment.start, segment.end, segment.text))
        for word in segment.words ?? [] {
            print(String(format: "    %7.2f –%7.2f %@", word.start, word.end, word.text))
        }
    }

case "diarize":
    guard let audio = arguments.audio.first else { usage() }
    _ = try await manager.install()
    let scalings = arguments.acousticScalings.isEmpty
        ? [LocalDiarizationTuning.libraryDefaultWarmStartFa, LocalDiarizationTuning.warmStartFa]
        : arguments.acousticScalings
    let seconds = MonoAudioDecoder.durationSeconds(audio)
    print("file            \(audio.lastPathComponent)  \(String(format: "%.1f", seconds))s")
    print("")
    print("  Fa     speakers   segments   speech      RTFx   longest cluster")
    var byScaling: [Double: DiarizationOutput] = [:]
    for scaling in scalings {
        let started = Date()
        let output = try await manager.evaluateDiarization(
            audio: audio, warmStartFa: scaling, speakerCount: arguments.speakerCount
        )
        let elapsed = Date().timeIntervalSince(started)
        byScaling[scaling] = output
        let speech = output.intervals.reduce(0) { $0 + $1.duration }
        let longest = output.clusters.map(\.speechSeconds).max() ?? 0
        print(String(
            format: "  %-6.2f %8d   %8d   %6.1fs   %5.1f   %5.1fs",
            scaling, output.speakerCount, output.intervals.count, speech,
            seconds / max(elapsed, 0.001), longest
        ))
    }
    // How differently the two configurations attributed the same timeline. A
    // large disagreement is the point of the comparison, not a fault.
    if scalings.count == 2,
       let first = byScaling[scalings[0]], let second = byScaling[scalings[1]] {
        // Frames first, then the mapping that explains most of them. Choosing
        // each cluster's counterpart on first sight credited that frame whatever
        // it was, and never checked the mapping was one-to-one, so two clusters
        // collapsing into one at the higher value counted as complete agreement:
        // the metric was blind to a merge in exactly one direction.
        let step = 0.1
        var frames: [String: [String: Double]] = [:]
        var compared = 0.0
        var position = 0.0
        while position < seconds {
            let left = first.intervals.first { position >= $0.start && position < $0.end }?.clusterID
            let right = second.intervals.first { position >= $0.start && position < $0.end }?.clusterID
            if let left, let right {
                compared += step
                frames[left, default: [:]][right, default: 0] += step
            }
            position += step
        }
        // Each left cluster keeps its majority counterpart, and a right cluster
        // may be claimed only once: whatever is left over is disagreement, which
        // is what a split or a merge should read as.
        var agreed = 0.0
        var taken: Set<String> = []
        let ranked = frames.sorted { ($0.value.values.max() ?? 0) > ($1.value.values.max() ?? 0) }
        for (_, counterparts) in ranked {
            let best = counterparts
                .filter { !taken.contains($0.key) }
                .max { $0.value < $1.value }
            guard let best else { continue }
            taken.insert(best.key)
            agreed += best.value
        }
        print("")
        print(String(
            format: "  frames both labelled: %.0fs, consistent mapping on %.1f%%",
            compared, compared > 0 ? agreed / compared * 100 : 0
        ))
    }
    print("")
    print("  production default is Fa=\(LocalDiarizationTuning.warmStartFa)")

case "identity":
    guard !arguments.audio.isEmpty else { usage() }
    _ = try await manager.install()
    // Each file is treated as one speaker, which is what an enrolment clip is.
    var vectors: [(String, [Float])] = []
    for file in arguments.audio {
        guard let sample = try await manager.embedSingleSpeaker(audio: file) else {
            note("no speech in \(file.lastPathComponent)")
            continue
        }
        vectors.append((file.deletingPathExtension().lastPathComponent, sample.vector))
        print(String(
            format: "%-28s %6.1fs speech", (file.lastPathComponent as NSString).utf8String!,
            sample.speechSeconds
        ))
    }
    guard vectors.count > 1 else { break }
    print("")
    print("pairwise cosine similarity")
    for outer in 0..<vectors.count {
        for inner in (outer + 1)..<vectors.count {
            let score = VoiceVector.cosine(vectors[outer].1, vectors[inner].1)
            let policy = SpeakerResolutionPolicy.shipping
            let verdict = score >= policy.namedHighScore
                ? "would name"
                : (score >= policy.mediumScore ? "would suggest" : "unknown")
            print(String(
                format: "  %-20s %-20s %.3f  %@",
                (vectors[outer].0 as NSString).utf8String!,
                (vectors[inner].0 as NSString).utf8String!, score, verdict
            ))
        }
    }
    print("")
    print("  thresholds: name at >= \(SpeakerResolutionPolicy.shipping.namedHighScore) with margin"
        + " >= \(SpeakerResolutionPolicy.shipping.namedHighMargin) and"
        + " >= \(Int(SpeakerResolutionPolicy.shipping.namedHighSpeechSeconds))s of speech")

case "voices":
    let store = try SpeakerStore(
        url: SpeakerStore.defaultURL(applicationSupport: arguments.applicationSupport)
    )
    let statistics = try await store.statistics()
    print("named people      \(statistics.namedPeople)")
    print("recurring voices  \(statistics.recurringVoices)")
    print("candidates        \(statistics.candidateVoices)")
    print("embeddings        \(statistics.embeddings)")
    print("database          \(megabytes(UInt64(max(0, statistics.storageBytes))))")
    print("")
    let profiles = try await store.searchableProfiles(model: .fluidAudioOffline)
    for profile in profiles.sorted(by: { $0.identity.resolvedName < $1.identity.resolvedName }) {
        print(String(
            format: "  %-24s %@", (profile.identity.resolvedName as NSString).utf8String!,
            profile.status.summary
        ))
    }
    // The measurement that matters at scale: how close the two nearest profiles
    // are, because that is the margin an automatic name has to clear.
    var worst = (score: 0.0, pair: ("", ""))
    for outer in 0..<profiles.count {
        for inner in (outer + 1)..<profiles.count {
            let score = VoiceVector.cosine(profiles[outer].centroid, profiles[inner].centroid)
            if score > worst.score {
                worst = (score, (profiles[outer].identity.resolvedName, profiles[inner].identity.resolvedName))
            }
        }
    }
    if worst.score > 0 {
        print("")
        print(String(
            format: "closest pair      %@ and %@ at %.3f",
            worst.pair.0, worst.pair.1, worst.score
        ))
    }

default:
    usage()
}
