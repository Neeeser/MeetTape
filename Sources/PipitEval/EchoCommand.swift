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

    static func run(meeting: URL, json: URL?, referenceOffset: Double?) -> Int32 {
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

        let measurement: EchoMeasurement
        do {
            measurement = try EchoMeasurement.measure(
                store: store, metadata: metadata, timeline: timeline,
                referenceOffset: referenceOffset
            )
        } catch {
            note("cannot measure \(metadata.id): \(error)")
            return 1
        }

        print("meeting         \(metadata.id)")
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
                    meeting: metadata.id, status: "measured", noReferenceReason: nil,
                    report: report
                )
            case .noReference(let reason):
                document = Document(
                    meeting: metadata.id, status: "no-reference", noReferenceReason: reason,
                    report: nil
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
            report.seconds, report.windows, report.windowSeconds
        ))
        print("reference       far end moved \(offset)s onto the microphone's clock, \(source)")
        print(String(
            format: "far end         above %.1f dBFS in %d windows, %.1f%% of the meeting",
            report.floorDBFS, report.farEndActiveWindows, report.farEndDutyCycle * 100
        ))
        print("")
        print("  " + left("window class", 13) + right("windows", 8) + right("seconds", 10)
            + right("mic before", 12) + right("mic after", 12) + right("change", 12))
        for summary in report.classes {
            print(row(summary))
        }
        print("")
        let median = report.reportedEnhancementMedianDB.map { String(format: "%.1f dB", $0) }
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
        print("  rather than what was removed. A window is classed from the two recorded")
        print("  levels alone, and those levels cannot tell the user from the far end's")
        print("  own echo in the microphone. The user only row is the one that says what")
        print("  the user kept.")
    }

    private static func row(_ summary: EchoMeasurement.ClassSummary) -> String {
        let label = switch summary.windowClass {
        case .farEndOnly: "far end only"
        case .userOnly: "user only"
        case .both: "both"
        case .neither: "neither"
        }
        let head = "  " + left(label, 13) + right("\(summary.windows)", 8)
        // A class with no windows in it has no level to report. Printing zero
        // decibels for one would read as full scale, and printing a zero
        // change would read as a canceller that did nothing.
        guard let before = summary.microphoneBeforeDBFS,
              let after = summary.microphoneAfterDBFS,
              let change = summary.changeDB else {
            return head + right("-", 10) + right("-", 12) + right("-", 12) + right("-", 12)
        }
        return head
            + right(String(format: "%.1fs", summary.seconds), 10)
            + right(String(format: "%.1f dB", before), 12)
            + right(String(format: "%.1f dB", after), 12)
            + right(String(format: "%.1f dB", change), 12)
    }

    private static func left(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    private static func right(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
    }
}
