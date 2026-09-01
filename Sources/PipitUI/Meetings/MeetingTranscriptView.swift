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
                people: detail.peopleHere,
                onAction: { action, person in
                    guard let person else { return }
                    let target = target(action, in: block)
                    detail.assignRange(target, to: person)
                    model.noteLineCorrection(
                        person.identity.resolvedName, lines: target.parts.count
                    )
                },
                onSomeoneElse: { action in
                    detail.beginNaming(.range(target(action, in: block), in: block.id))
                }
            )
            // Anchored on the block, because the menu that raised it is an
            // AppKit one and has already closed by the time this opens.
            .popover(isPresented: pickingRange(in: block), arrowEdge: .bottom) {
                if let open = detail.namingRange(inBlock: block.id) { picker(open) }
            }
        }
    }

    private func pickingRange(in block: CombinedLineBlock) -> Binding<Bool> {
        Binding(
            get: { detail.namingRange(inBlock: block.id) != nil },
            set: { open in
                if !open, detail.namingRange(inBlock: block.id) != nil { detail.cancelNaming() }
            }
        )
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
        let target = SpeakerNamingTarget.block(block)
        return Button(block.speakerName) { detail.beginNaming(target) }
            .buttonStyle(.plain)
            .font(.callout.weight(.semibold))
            .foregroundStyle(tint(for: block.speakerName))
            .popover(isPresented: picking(target.id), arrowEdge: .bottom) { picker(target) }
    }

    /// The picker, wherever the transcript raises it. The turn header opens it
    /// on the whole block. A right-click on a selection opens it on that
    /// stretch alone.
    private func picker(_ target: SpeakerNamingTarget) -> some View {
        PeoplePickerView(
            // The whole directory, unlike the AppKit submenu behind it: this
            // one has a search field, so the long tail is reachable.
            people: detail.knownPeople,
            context: detail.pickerContext,
            model: detail.picker,
            leaveUnnamedTitle: leaveUnnamedTitle(for: target),
            onPick: { person in
                detail.cancelNaming()
                apply(target, name: person.identity.resolvedName) {
                    switch target.subject {
                    case let .block(block): detail.assignBlock(block, to: person)
                    case let .range(range): detail.assignRange(range, to: person)
                    case .cluster: break
                    }
                }
            },
            onNewPerson: { name in
                detail.cancelNaming()
                apply(target, name: name) {
                    switch target.subject {
                    case let .block(block): detail.assignBlock(block, toNewPerson: name)
                    case let .range(range): detail.assignRange(range, toNewPerson: name)
                    case .cluster: break
                    }
                }
            },
            onLeaveUnnamed: {
                detail.cancelNaming()
                if case let .block(block) = target.subject { detail.clearBlock(block) }
            }
        )
    }

    /// Only a whole turn can be handed back to its cluster. A stretch inside
    /// one was carved out by hand and has nothing to fall back to.
    private func leaveUnnamedTitle(for target: SpeakerNamingTarget) -> String? {
        if case .block = target.subject { return "Use this speaker's name" }
        return nil
    }

    /// Applies the change and reports how many lines it moved, which is what
    /// the receipt above the transcript counts.
    private func apply(_ target: SpeakerNamingTarget, name: String, _ change: () -> Void) {
        change()
        let lines: Int
        switch target.subject {
        case let .block(block): lines = block.lines.count
        case let .range(range): lines = range.parts.count
        case .cluster: lines = 0
        }
        guard !name.isEmpty, lines > 0 else { return }
        model.noteLineCorrection(name, lines: lines)
    }

    private func picking(_ id: String) -> Binding<Bool> {
        Binding(
            get: { detail.isNaming(id) },
            set: { open in if !open, detail.isNaming(id) { detail.cancelNaming() } }
        )
    }
}
