import Foundation
import PipitCore
import PipitServices

/// Runs the echo canceller over one recorded meeting and prints what it did.
///
/// The developer tool that turns the canceller's tone measurements into
/// measurements of a real call. It reads the microphone and the far end as
/// they were recorded, runs the same pass `MicrophoneCleaner` runs, and
/// reports the levels either side of it. The meeting need never have been
/// cleaned, which is what lets it measure the recordings made before the
/// cleaner existed.
///
/// Writes nothing into the meeting. `--json` writes a file wherever it is
/// pointed, and that file carries counts, durations, decibels and labels.
enum EchoCommand {
    /// What `--json` writes.
    private struct Document: Encodable {
        let meeting: String
        let status: String
        let noReferenceReason: EchoMeasurement.MissingReference?
        let report: EchoMeasurement.Report?
    }

    static func run(
        meeting: URL, json: URL?, referenceOffset: Double?, fullIdentifier: Bool
    ) -> Int32 {
        let store = MeetingStore(layout: MeetingLayout(root: meeting))
        let metadata: MeetingMetadata
        let timeline: RecordingTimeline
        do {
            metadata = try store.readMetadata()
            timeline = try store.readTimeline()
        } catch {
            note("cannot read \(meeting.path): \(error)")
            return 1
        }
        let name = identifier(metadata, full: fullIdentifier)

        let measurement: EchoMeasurement
        do {
            measurement = try EchoMeasurement.measure(
                store: store, metadata: metadata, timeline: timeline,
                referenceOffset: referenceOffset
            )
        } catch {
            note("cannot measure \(name): \(error)")
            return 1
        }

        print("meeting         \(name)")
        print("source          \(metadata.source.rawValue)")
        switch measurement {
        case .noReference(let reason):
            printNoReference(reason)
        case .measured(let report):
            printReport(report)
        }

        if let json {
            let document: Document
            switch measurement {
            case .measured(let report):
                document = Document(
                    meeting: name, status: "measured", noReferenceReason: nil, report: report
                )
            case .noReference(let reason):
                document = Document(
                    meeting: name, status: "no-reference", noReferenceReason: reason, report: nil
                )
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            do {
                try encoder.encode(document).write(to: json)
                print("")
                print("wrote           \(json.path)")
            } catch {
                note("cannot write \(json.path): \(error)")
                return 1
            }
        }
        return 0
    }

    /// A name for this meeting that carries no meeting content.
    ///
    /// `metadata.id` ends in a slug of the meeting's title, up to 48
    /// characters of it. What this command prints goes into a pull request
    /// body and into files under `Benchmarks/`, both of them committed, and a
    /// title is meeting content. What is left is the start time, the source,
    /// and a digest of the full identifier, which tells two meetings of the
    /// same minute apart and is the same digest on a later run.
    ///
    /// `--full-id` prints `metadata.id` instead, for a run whose output stays
    /// on this Mac.
    private static func identifier(_ metadata: MeetingMetadata, full: Bool) -> String {
        guard !full else { return metadata.id }
        let stamp = MeetingArchiveLayout.timestampSlug(metadata.startedAt)
        return "\(stamp)-\(metadata.source.rawValue)-\(digest(metadata.id))"
    }

    /// FNV-1a. Swift's own `Hasher` is seeded per process, so it would name
    /// the same meeting differently on every run and the identifiers in one
    /// checked-in table would not match the next one's.
    private static func digest(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    /// A meeting with nothing to subtract. Said in words, with no table and no
    /// decibel figure, because a removal of zero decibels is a different
    /// finding from having had nothing to remove.
    private static func printNoReference(_ reason: EchoMeasurement.MissingReference) {
        let explanation = switch reason {
        case .oneTrack: "one track holds everyone, so there is no separate far end"
        case .notRecorded: "no far-end track was recorded"
        case .recordedSilence: "the far-end track was recorded and holds silence"
        }
        print("no reference    \(explanation)")
        print("")
        print("  Nothing was measured. There was no far end to subtract, and this")
        print("  meeting is read on the microphone it recorded.")
    }

    private static func printReport(_ report: EchoMeasurement.Report) {
        let offset = String(format: "%+.2f", report.referenceOffsetSeconds)
        let source = report.referenceOffsetIsOverride ? "given by hand" : "from the manifest"
        print(String(
            format: "duration        %.1fs in %d windows of %.2fs",
            report.seconds, report.windowCount, report.windowSeconds
        ))
        print("reference       far end moved \(offset)s onto the microphone's clock, \(source)")
        print(String(
            format: "far end         above %.1f dBFS in %d windows, %.1f%% of the meeting",
            report.farEndFloorDBFS, report.farEndActiveWindows, report.farEndDutyCycle * 100
        ))
        printMicrophoneFloor(report)
        print("")
        print("  " + left("window class", 13) + right("windows", 8) + right("seconds", 9)
            + right("mic before", 12) + right("mic after", 12) + right("change", 12))
        for summary in report.classes {
            print(levelRow(summary))
        }
        print("")
        print("per-window change, dB")
        print("  " + left("window class", 13) + right("median", 9) + right("p95", 9)
            + right("worst", 9) + right("gain", 9)
            + right("windows over \(fixed(report.notableLossDB)) dB", 24))
        for summary in report.classes {
            print(distributionRow(summary))
        }
        print("")
        let median = report.reportedEnhancementMedianDB.map { "\(fixed($0)) dB" }
            ?? "no far-end-active window"
        print("reported        \(median) median enhancement")
        print(String(
            format: "threshold       %.1f dB over at least %d far-end-active windows",
            report.bypassThresholdDB, report.minimumActiveWindows
        ))
        print("decision        \(report.decision.rawValue)")
        print("                \(report.decisionReason)")
        print("")
        print("  change is before minus after, which is what the microphone level did")
        print("  rather than what was removed. The class figure is a power ratio, so the")
        print("  loudest windows decide it. The per-window columns are where a passage")
        print("  gated to silence shows up. A window is classed from the two recorded")
        print("  levels alone, and those levels cannot tell the user from the far end's")
        print("  own echo in the microphone. The user only row is the one that says what")
        print("  the user kept.")
    }

    /// Which of the two floors decided the microphone's, and the level the
    /// recording's own quiet windows sit at. An operator reading a table where
    /// every window landed in `userOnly` or `both` needs to see whether the
    /// room tone was what put them there.
    private static func printMicrophoneFloor(_ report: EchoMeasurement.Report) {
        let floor = fixed(report.microphoneFloorDBFS)
        guard let quiet = report.microphoneQuietWindowDBFS else {
            print("microphone      above \(floor) dBFS, with no window to derive one from")
            return
        }
        if report.microphoneFloorDBFS > report.farEndFloorDBFS {
            print("microphone      above \(floor) dBFS, from a quietest twentieth of "
                + "\(fixed(quiet)) dBFS")
        } else {
            print("microphone      above \(floor) dBFS, the far end's floor. The quietest")
            print("                twentieth of this recording sits under it, at "
                + "\(fixed(quiet)) dBFS")
        }
    }

    private static func levelRow(_ summary: EchoMeasurement.ClassSummary) -> String {
        let head = "  " + left(label(summary.windowClass), 13) + right("\(summary.windows)", 8)
        // A class with no windows in it has no level to report. Printing zero
        // decibels for one would read as full scale, and printing a zero
        // change would read as a canceller that did nothing.
        guard let before = summary.microphoneBeforeDBFS,
              let after = summary.microphoneAfterDBFS,
              let change = summary.changeDB else {
            return head + right("-", 9) + right("-", 12) + right("-", 12) + right("-", 12)
        }
        return head
            + right(String(format: "%.1fs", summary.seconds), 9)
            + right("\(fixed(before)) dB", 12)
            + right("\(fixed(after)) dB", 12)
            + right("\(fixed(change)) dB", 12)
    }

    private static func distributionRow(_ summary: EchoMeasurement.ClassSummary) -> String {
        let head = "  " + left(label(summary.windowClass), 13)
        guard let median = summary.medianChangeDB, let p95 = summary.p95ChangeDB,
              let worst = summary.worstChangeDB, let gain = summary.largestGainDB else {
            return head + right("-", 9) + right("-", 9) + right("-", 9) + right("-", 9)
                + right("\(summary.windowsOverLossThreshold)", 24)
        }
        return head + right(fixed(median), 9) + right(fixed(p95), 9) + right(fixed(worst), 9)
            + right(fixed(gain), 9) + right("\(summary.windowsOverLossThreshold)", 24)
    }

    private static func label(_ windowClass: EchoMeasurement.WindowClass) -> String {
        switch windowClass {
        case .farEndOnly: "far end only"
        case .userOnly: "user only"
        case .both: "both"
        case .neither: "neither"
        }
    }

    private static func fixed(_ value: Double) -> String { String(format: "%.1f", value) }

    private static func left(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    private static func right(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
    }
}
