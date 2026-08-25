import AppKit
import PipitCore
import PipitServices
import SwiftUI

/// The words, as one paragraph per turn, with the speaker's name on the header
/// and the correction menus on the words themselves.
struct MeetingTranscriptView: View {
    let model: MeetingsWindowModel
    let detail: MeetingReviewModel

    var body: some View {
        if detail.combinedLines.isEmpty {
            waiting
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if detail.isSplitRecording { continuationNotice }
                    // Lazy because a long meeting is thousands of lines and each
                    // one carries a menu.
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(CombinedLineBlock.blocks(from: detail.combinedLines)) { block in
                            blockView(block)
                        }
                    }
                    if detail.isNaming { namingField }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var waiting: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if detail.metadata?.processing.state != .failed {
                    ProgressView().controlSize(.small)
                }
                Text(processingLabel).foregroundStyle(.secondary)
                Button("Refresh") { detail.reload() }.buttonStyle(.link)
            }
            if let progress = detail.progress, progress.totalChunks > 0 {
                ProgressView(
                    value: Double(progress.completedChunks), total: Double(progress.totalChunks)
                )
                .frame(maxWidth: 360)
            }
            Text("The audio is already on disk. Closing this window changes nothing.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What the pane says while it waits.
    private var processingLabel: String {
        guard let state = detail.metadata?.processing.state else { return "Waiting" }
        if let progress = detail.progress, let text = progress.detail { return text }
        if let progress = detail.progress, let fraction = progress.fraction,
            fraction > 0, fraction < 1 {
            return "\(state.displayName), \(Int(fraction * 100))%"
        }
        return state.displayName
    }

    /// What the pane says when the conversation is held in more than one
    /// recording.
    private var continuationNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
            Text(
                "Recorded in \(detail.recordings.count) parts, shown in order. "
                    + "The call dropped and was rejoined."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer()
            ForEach(detail.recordings.dropFirst(), id: \.id) { recording in
                Button("Separate part \(index(of: recording) + 1)") {
                    model.separate(recording.id)
                }
                .buttonStyle(.link)
                .font(.caption)
                .help("Keeps both recordings and undoes the link between them")
            }
        }
    }

    private func index(of recording: MeetingMetadata) -> Int {
        detail.recordings.firstIndex { $0.id == recording.id } ?? 0
    }

    /// One speaker's turn: a name, the range it covers, and the words as one
    /// paragraph.
    ///
    /// The assembler caps a turn at 30 seconds and the diarizer prefers
    /// splitting a speaker over merging two, so one person talking arrives as
    /// several lines in a row. A timecode above each of them broke a
    /// three-minute answer into nineteen pieces on screen. The lines are still
    /// there underneath, and the menu on the header names the whole turn.
    private func blockView(_ block: CombinedLineBlock) -> some View {
        let paragraph = block.paragraph()
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                blockMenu(for: block)
                Text(range(of: block))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if block.lines.contains(where: { detail.correctedLines.contains($0.id) }) {
                    Image(systemName: "pencil.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("You set the speaker here")
                }
            }
            TranscriptParagraph(
                text: paragraph.text,
                spans: paragraph.spans,
                people: detail.knownPeople,
                onAction: { action, person in
                    guard let person else { return }
                    let target = target(action, in: block)
                    detail.assignRange(target, to: person)
                    model.noteLineCorrection(
                        person.identity.resolvedName, lines: target.parts.count
                    )
                },
                onNewPerson: { action in
                    detail.beginNamingRange(target(action, in: block))
                }
            )
        }
    }

    /// The colour this speaker has everywhere else.
    ///
    /// A line carries a resolved name rather than an identifier, so the
    /// identifier comes back through the speaker rows. Without that step the
    /// transcript hashed the name and the chip above it hashed the identity,
    /// and the same person was two colours in one window.
    private func tint(for name: String) -> Color {
        let identity = detail.speakerRows.first { $0.displayName == name }?.identity?.id
        return PersonTint.color(identity: identity, name: name)
    }

    private func range(of block: CombinedLineBlock) -> String {
        let renderer = TranscriptRenderer()
        let start = renderer.timecode(block.timelineStart)
        let end = renderer.timecode(block.timelineEnd)
        return start == end ? start : "\(start) – \(end)"
    }

    /// Where a right-click lands, in the recording's own seconds, one window
    /// per line it covers.
    ///
    /// A split runs to the end of the turn as the reader sees it: the rest of
    /// the line the boundary fell in, and the whole of every line printed after
    /// it. Not the rest of the turn by the clock, because a line printed later
    /// can have started earlier.
    private func target(
        _ action: TranscriptParagraphAction, in block: CombinedLineBlock
    ) -> SpeakerRangeTarget {
        switch action {
        case let .split(atSeconds, utteranceID):
            let following = block.lines.drop { $0.utterance.id != utteranceID }
            let parts = following.enumerated().map { offset, line in
                SpeakerRangePart(
                    utteranceID: line.utterance.id,
                    startSeconds: offset == 0 ? atSeconds : line.utterance.start,
                    endSeconds: line.utterance.end
                )
            }
            return SpeakerRangeTarget(
                recordingID: block.recordingID, track: block.track, parts: parts
            )
        case let .assign(parts):
            return SpeakerRangeTarget(
                recordingID: block.recordingID, track: block.track,
                parts: parts.map {
                    SpeakerRangePart(
                        utteranceID: $0.utteranceID, startSeconds: $0.startSeconds,
                        endSeconds: $0.endSeconds
                    )
                }
            )
        }
    }

    /// Names the whole turn. Every line under the header moves together,
    /// because the header is the only menu the lines have.
    private func blockMenu(for block: CombinedLineBlock) -> some View {
        Menu(block.speakerName) {
            ForEach(detail.knownPeople) { person in
                Button(person.identity.resolvedName) {
                    detail.assignBlock(block, to: person)
                    model.noteLineCorrection(
                        person.identity.resolvedName, lines: block.lines.count
                    )
                }
            }
            if !detail.knownPeople.isEmpty { Divider() }
            Button("New person…") { detail.beginNamingBlock(block) }
            Button("Use this speaker's name") { detail.clearBlock(block) }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.callout.weight(.semibold))
        .tint(tint(for: block.speakerName))
    }

    private var namingField: some View {
        HStack {
            TextField("Name", text: detail.text(\.newPersonDraft))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                .onSubmit { commit() }
            Button("Save") { commit() }
                .disabled(detail.newPersonDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel") { detail.cancelNaming() }
            Spacer()
        }
    }

    private func commit() {
        let name = detail.newPersonDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = detail.namingBlock?.lines.count ?? detail.namingRange?.parts.count ?? 0
        detail.commitNaming()
        guard !name.isEmpty, lines > 0 else { return }
        model.noteLineCorrection(name, lines: lines)
    }
}
