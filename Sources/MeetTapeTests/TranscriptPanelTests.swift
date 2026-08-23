import AppKit
import Foundation
import MeetTapeCore
import MeetTapeServices
import SwiftUI
import TestKit
@testable import MeetTapeUI

/// The review panel's transcript, laid out for real.
///
/// A block is an `NSTextView` inside SwiftUI, and a representable that reports
/// the wrong height renders as a sliver or as nothing at all without failing
/// anything. These lay the panel out through `NSHostingController` and look at
/// what came back.
enum TranscriptPanelTests {
    /// A meeting whose transcript is one speaker talking through eight lines,
    /// which is what the assembler produces for a long answer.
    static func makeMeeting(root: URL) throws -> String {
        let repository = MeetingRepository(root: root.appendingPathComponent("Meetings"))
        let started = Date(timeIntervalSince1970: 1_787_070_000)
        let created = try repository.createMeeting(
            source: .googleMeet, provider: .googleMeet, startedAt: started,
            titles: TitleCandidates(provider: "Weekly sync", timestampFallback: "f"), now: started
        )
        _ = try created.store.updateMetadata {
            $0.durationSeconds = 240
            $0.processing = ProcessingStatus(state: .complete, updatedAt: started)
        }
        let sentence = "so the way this works is that every word carries its own moment "
            + "and the boundary a reader puts in the transcript lands on one of them"
        var utterances: [Utterance] = []
        for index in 0..<8 {
            let start = Double(index) * 30
            let words = sentence.split(separator: " ").enumerated().map {
                RawTranscriptWord(
                    start: start + Double($0.offset) * 0.9,
                    end: start + Double($0.offset) * 0.9 + 0.6,
                    text: " \($0.element)"
                )
            }
            utterances.append(Utterance(
                id: Utterance.identifier(
                    chunkID: "c1", track: .remote, start: start, end: start + 28
                ),
                start: start, end: start + 28, track: .remote,
                rawSpeakerLabel: "remote-001_speaker_00", speakerKey: "remote-001_speaker_00",
                text: sentence, chunkID: "c1", model: "m", words: words
            ))
        }
        try created.store.writeCanonicalTranscript(
            CanonicalTranscript(generatedAt: started, utterances: utterances)
        )
        return created.metadata.id
    }

    /// Every text view in a laid-out panel, in the order they appear.
    static func paragraphs(in view: NSView) -> [TranscriptTextView] {
        if let paragraph = view as? TranscriptTextView { return [paragraph] }
        return view.subviews.flatMap(paragraphs(in:))
    }

    static var suite: Suite {
        Suite("TranscriptPanel", [
            test("one speaker's eight lines lay out as one readable paragraph") { expect in
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meetingID = try makeMeeting(root: root)

                await MainActor.run {
                    NSApplication.shared.setActivationPolicy(.prohibited)
                    let runtime = MeetTapeRuntime(settingsDirectory: root)
                    var settings = runtime.settings
                    settings.storageRootPath = root.appendingPathComponent("Meetings").path
                    runtime.update(settings: settings)

                    let model = MeetingReviewModel(runtime: runtime, meetingID: meetingID)
                    expect.equal(model.combinedLines.count, 8, "eight lines to show")

                    let controller = NSHostingController(
                        rootView: AnyView(MeetingReviewView(model: model))
                    )
                    controller.view.frame = NSRect(x: 0, y: 0, width: 720, height: 2_000)
                    controller.view.layoutSubtreeIfNeeded()
                    controller.view.displayIfNeeded()

                    let found = paragraphs(in: controller.view)
                    expect.equal(found.count, 1, "one speaker throughout, so one block")
                    guard let paragraph = found.first else { return }
                    expect.isTrue(
                        paragraph.string.hasPrefix("so the way this works"),
                        "the words are in it"
                    )
                    expect.equal(
                        paragraph.spans.count, 8 * 27,
                        "every word of every line is placed in the paragraph"
                    )
                    expect.isTrue(
                        paragraph.frame.height > 60,
                        "eight lines of text need more than a sliver: got "
                            + "\(paragraph.frame.height)"
                    )
                    expect.isTrue(paragraph.frame.width > 300, "and the full column width")
                }
            },

            test("the header names every line of the turn") { expect in
                // The header is the only menu the lines have now. Naming just
                // the first would rename thirty seconds of a four-minute
                // answer and tear the paragraph in two on the next reload.
                let root = try ManifestTests.makeTemporaryDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let meetingID = try makeMeeting(root: root)

                await MainActor.run {
                    let runtime = MeetTapeRuntime(settingsDirectory: root)
                    var settings = runtime.settings
                    settings.storageRootPath = root.appendingPathComponent("Meetings").path
                    runtime.update(settings: settings)
                    let model = MeetingReviewModel(runtime: runtime, meetingID: meetingID)
                    guard let block = CombinedLineBlock.blocks(from: model.combinedLines).first
                    else { return expect.fail("no block") }
                    expect.equal(block.lines.count, 8)
                    model.assignBlock(block, toNewPerson: "Dana")
                    expect.equal(
                        Set(model.combinedLines.map(\.speakerName)), ["Dana"],
                        "every line of the turn, not only the first"
                    )
                    expect.equal(model.correctedLines.count, 8)
                }
            },

            test("a right-click resolves to the word gap nearest it") { expect in
                await MainActor.run {
                    // "we ship on friday", one word per second.
                    let view = TranscriptTextView()
                    view.spans = (0..<4).map {
                        TranscriptWordSpan(
                            location: $0 * 5, length: 4, startSeconds: Double($0),
                            endSeconds: Double($0) + 0.8, utteranceID: $0 < 2 ? "l1" : "l2"
                        )
                    }
                    expect.equal(
                        view.nearestBoundary(to: 6)?.startSeconds, 1.0, "the gap it was aimed at"
                    )
                    expect.equal(
                        view.nearestBoundary(to: 13)?.startSeconds, 3.0,
                        "and the nearer of the two around it"
                    )
                    expect.equal(
                        view.nearestBoundary(to: 13)?.utteranceID, "l2",
                        "named with the line it falls in, which time alone cannot say"
                    )
                    expect.equal(
                        view.nearestBoundary(to: 0)?.startSeconds, 1.0,
                        "a click before the first word divides at the second, never at nothing"
                    )
                    let selection = view.selectedSpanRange(NSRange(location: 5, length: 8))
                    expect.equal(selection?.start, 1.0)
                    expect.equal(selection?.end, 2.8, "through the end of the last word touched")
                    expect.equal(
                        selection?.lines, ["l1", "l2"], "every line the selection crossed"
                    )
                }
            },

            test("a block measures taller as the column narrows") { expect in
                await MainActor.run {
                    let view = TranscriptTextView()
                    view.textContainer?.widthTracksTextView = false
                    view.textContainer?.lineFragmentPadding = 0
                    view.textContainerInset = .zero
                    view.string = String(repeating: "one two three four five ", count: 40)
                    view.font = .preferredFont(forTextStyle: .body)
                    let wide = view.height(forWidth: 600)
                    let narrow = view.height(forWidth: 300)
                    expect.isTrue(wide > 0, "a paragraph has a height at all")
                    expect.isTrue(
                        narrow > wide,
                        "and wrapping into a narrower column makes it taller: \(narrow) vs \(wide)"
                    )
                }
            },
        ])
    }
}
