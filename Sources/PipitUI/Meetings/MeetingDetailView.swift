import AppKit
import PipitCore
import PipitServices
import SwiftUI

/// One meeting: what it was, who was in it, and what was said.
///
/// The header and the speaker strip stay put while the transcript scrolls, so
/// changing who said what is one click away from any line rather than a scroll
/// back to a card at the top.
public struct MeetingDetailView: View {
    let model: MeetingsWindowModel
    let detail: MeetingReviewModel

    public init(model: MeetingsWindowModel, detail: MeetingReviewModel) {
        self.model = model
        self.detail = detail
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            // The folder can go away under an open pane: a meeting deleted in
            // the Finder, or one folded into another. Everything on screen is
            // then the last read rather than what is on disk, and nothing else
            // here says so.
            if let message = detail.errorMessage {
                noticeBar(message)
                Divider()
            }
            if let failure = detail.metadata?.processing.lastFailure {
                failureBar(failure)
                Divider()
            }
            speakerStrip
            if let receipt = model.receipt, receipt.meetingID == detail.meetingID {
                receiptBar(receipt.text)
            }
            Divider()
            tabs
            content
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - header

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Title", text: detail.titleBinding())
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))
                .onSubmit { detail.save() }

            HStack(spacing: 6) {
                if let metadata = detail.metadata {
                    Text(metadata.source.displayName)
                    Text("·")
                    Text(Format.day(metadata.startedAt))
                    Text("·")
                    Text(Format.shortDuration(metadata.durationSeconds))
                    if let source = metadata.recordedDateSource {
                        // Only an imported file carries this. Where the date
                        // came from decides whether the position this meeting
                        // holds in a list sorted by date can be trusted, so it
                        // is said either way rather than only when it is good
                        // news.
                        Text("·")
                        Text(source.displayName)
                            .help(
                                source.isOriginal
                                    ? "The recording carried this date. Importing it left the date alone."
                                    : "The file said nothing about when it was recorded."
                            )
                    }
                    StageBadge(state: metadata.processing.state)
                }
                if detail.isSplitRecording {
                    Label("\(detail.recordings.count) parts", systemImage: "arrow.triangle.branch")
                        .help("The call dropped and was rejoined. Both halves are shown in order.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 4)

            HStack(spacing: 8) {
                Image(systemName: "folder").font(.caption)
                Text(archivePath)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(detail.directory?.path ?? "")
                Button("Reveal in Finder") { detail.reveal() }.buttonStyle(.link)
                if detail.transcript != nil {
                    Button("Rebuild transcript") { model.rebuildFocusedMeeting() }
                        .buttonStyle(.link)
                        .help("Re-assembles the transcript from the model output already on disk. Makes no request.")
                }
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.top, 8)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    /// The folder, from the meetings root down. The absolute path is long
    /// enough to push the two links off a narrow window, and the part a person
    /// recognises is the end of it.
    private var archivePath: String {
        guard let directory = detail.directory else { return "" }
        let components = directory.pathComponents
        return components.suffix(4).joined(separator: "/")
    }

    private func failureBar(_ failure: ProcessingFailure) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 1) {
                Text("Processing stopped at \(failure.stage.displayName.lowercased())")
                    .font(.callout)
                Text(failure.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            Button(failure.isRetryable ? "Retry" : "Try again anyway") { detail.retry() }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.red.opacity(0.07))
    }

    private func noticeBar(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            Text(text).font(.callout)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }

    private func receiptBar(_ text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(text).font(.caption)
            Spacer(minLength: 8)
            Button("Reveal in Finder") { detail.reveal() }.buttonStyle(.link).font(.caption)
            Button("Dismiss") { model.dismissReceipt() }.buttonStyle(.link).font(.caption)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color.green.opacity(0.08))
    }

    // MARK: - speakers

    private var speakerStrip: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("Speakers").font(.caption).foregroundStyle(.secondary)
                Spacer()
                reanalyze
            }
            if detail.speakerRows.isEmpty {
                Text(waitingText).font(.caption).foregroundStyle(.secondary)
            } else {
                SpeakerChips(model: model, detail: detail)
            }
            if detail.namingCluster != nil { namingField }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var waitingText: String {
        switch detail.metadata?.processing.state {
        case .some(.complete): "Nobody was identified in this recording."
        case .some(.failed): "Processing stopped before speakers were worked out."
        default: "Speakers appear when the transcript lands. The audio is already on disk."
        }
    }

    private var reanalyze: some View {
        Menu {
            Button("Run with the count Pipit picks") {
                detail.reanalyzeCount = ""
                detail.reanalyzeSpeakers()
            }
            .disabled(!detail.localModelsReady)
            Menu("Run with a set count") {
                ForEach(2...8, id: \.self) { count in
                    Button("\(count) speakers") {
                        detail.reanalyzeCount = "\(count)"
                        detail.reanalyzeSpeakers()
                    }
                }
            }
            .disabled(!detail.localModelsReady)
            Divider()
            Text(
                detail.localModelsReady
                    ? "The words are not transcribed again. Names on whole speakers are cleared, "
                        + "because the clusters they name no longer exist. Corrections to single "
                        + "lines are kept."
                    : "Runs on this Mac. Download the speech models in Settings to use it."
            )
        } label: {
            Label(
                detail.isReanalyzing ? "Re-analyzing…" : "Re-analyze speakers",
                systemImage: "arrow.triangle.2.circlepath"
            )
            .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(detail.isReanalyzing)
    }

    private var namingField: some View {
        HStack {
            TextField("Name", text: detail.text(\.newPersonDraft))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
                .onSubmit { commitNaming() }
            Button("Save") { commitNaming() }
                .disabled(detail.newPersonDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel") { detail.cancelNaming() }
            Spacer()
        }
    }

    /// Routed through the window model so the naming of a whole cluster still
    /// reports what it rewrote. The detail model's own `commitNaming` covers
    /// the cases the transcript raises, which report themselves.
    private func commitNaming() {
        if let cluster = detail.namingCluster,
            let row = detail.speakerRows.first(where: {
                $0.clusterID == cluster.clusterID && $0.recordingID == cluster.recordingID
            }) {
            let name = detail.newPersonDraft
            detail.cancelNaming()
            model.assignCluster(row, toNewPerson: name)
            return
        }
        detail.commitNaming()
    }

    // MARK: - tabs and content

    private var tabs: some View {
        HStack {
            Picker("", selection: Binding(get: { model.tab }, set: { model.tab = $0 })) {
                ForEach(MeetingDetailTab.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 268)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var content: some View {
        switch model.tab {
        case .transcript: MeetingTranscriptView(model: model, detail: detail)
        case .summary: summary
        case .notes: notes
        }
    }

    private var summary: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let summary = detail.summary, !summary.isEmpty {
                    Text(summary).font(.body).textSelection(.enabled)
                } else {
                    Text("No summary. Enrichment writes one when it runs.")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var notes: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let suggestion = detail.continuationSuggestion { continuationCard(suggestion) }

                SectionCard(
                    title: "Notes",
                    subtitle: "Saved as you type, including while processing runs."
                ) {
                    VStack(alignment: .leading, spacing: 6) {
                        TextEditor(text: detail.notesBinding())
                            .font(.body)
                            .frame(minHeight: 110)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                        Text(
                            "Context such as “Northwind call with me, my boss Chris and Tim” is "
                                + "used as input when speaker names are suggested."
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }

                SectionCard(
                    title: "Expected participants",
                    subtitle: "Relaxes the margin a saved voice needs. It never forces a name onto a speaker who did not match."
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(detail.expectedParticipants, id: \.self) { name in
                            HStack {
                                Text(name).font(.callout)
                                Spacer()
                                Button("Remove") { detail.removeParticipant(name) }
                                    .buttonStyle(.link).font(.caption)
                            }
                        }
                        HStack {
                            TextField("Add a name", text: detail.text(\.participantDraft))
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { detail.addParticipant() }
                            Button("Add") { detail.addParticipant() }
                                .disabled(
                                    detail.participantDraft
                                        .trimmingCharacters(in: .whitespaces).isEmpty
                                )
                        }
                        Text("Changing this re-runs speaker matching only. Nothing is transcribed again.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if detail.metadata?.hadOtherAudibleTabs == true {
                    SectionCard(title: "Another tab was playing audio", subtitle: nil) {
                        Text(
                            "A browser tab other than the meeting was audible during this "
                                + "recording, so the meeting track may hold that audio as well."
                        )
                        .font(.callout)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func continuationCard(_ suggestion: (title: String, reason: String)) -> some View {
        SectionCard(
            title: "Same meeting?",
            subtitle: "Combining links the two recordings. Neither recording's audio is moved or modified."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text("This may be a continuation of “\(suggestion.title)”. \(suggestion.reason).")
                    .font(.callout)
                HStack {
                    Button("Combine") { model.combineWithEarlier() }
                    Button("Keep separate") { detail.keepSeparate() }
                }
            }
        }
    }
}

/// One chip per speaker, each a menu that renames them everywhere in the
/// meeting.
///
/// An unnamed voice is outlined rather than left to look like the rest: it is
/// the one row in the strip that is asking for something.
struct SpeakerChips: View {
    let model: MeetingsWindowModel
    let detail: MeetingReviewModel

    var body: some View {
        // A wrapping row, because four or five speakers do not fit on one line
        // in a narrow window and a horizontal scroll hides the last of them.
        FlowRow(spacing: 6) {
            ForEach(detail.speakerRows) { row in chip(row) }
        }
    }

    /// The face and the duration sit outside the menu, deliberately.
    ///
    /// A macOS borderless menu draws one element of its label and drops the
    /// rest: with the avatar inside, the name disappeared and the chip read as
    /// two letters. The menu therefore carries the name alone, and the capsule
    /// around all three is what makes it one control.
    private func chip(_ row: MeetingSpeakerRow) -> some View {
        let unnamed = row.isUnnamed
        return HStack(spacing: 6) {
            SpeakerFace(
                name: unnamed ? "" : row.displayName,
                identityID: row.identity?.id,
                side: 20
            )
            Menu(row.displayName) {
                Text(chipDetail(row))
                Divider()
                ForEach(detail.knownPeople) { person in
                    Button(person.identity.resolvedName) { model.assignCluster(row, to: person) }
                }
                if !detail.knownPeople.isEmpty { Divider() }
                Button("New person…") {
                    detail.beginNamingCluster(row.clusterID, in: row.recordingID)
                }
                Button("Leave unnamed") { model.clearCluster(row) }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.callout)
            Text(Format.shortDuration(row.speechSeconds))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 3)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .background {
            Capsule().fill(unnamed ? Color.orange.opacity(0.12) : Color.primary.opacity(0.06))
        }
        .overlay {
            if unnamed { Capsule().stroke(Color.orange.opacity(0.55), lineWidth: 1) }
        }
        .help(chipDetail(row))
    }

    /// What the automatic decision was, in words rather than a number.
    ///
    /// A cosine similarity of 0.92 is not a 92% probability: genuine matches sit
    /// between 0.72 and 0.96 and so do the hardest wrong ones, so the score is
    /// kept for diagnostics and never shown as a percentage.
    private func chipDetail(_ row: MeetingSpeakerRow) -> String {
        var parts = [Format.shortDuration(row.speechSeconds)]
        switch row.origin {
        case .human: parts.append("you set this")
        case .deterministic: parts.append("your microphone track")
        case .sensor: parts.append("named by the meeting")
        case .voiceProfile: parts.append("matched a saved voice, \(row.band.displayName.lowercased())")
        case .anonymousVoice:
            parts.append(
                row.meetingCount > 1 ? "heard in \(row.meetingCount) meetings" : "heard before"
            )
        case .ai:
            if row.identity == nil { parts.append("not recognized") }
        }
        return parts.joined(separator: " · ")
    }
}

/// A row that wraps onto the next line when it runs out of width.
///
/// SwiftUI has no wrapping stack on this deployment target, and the speaker
/// strip is the one place in the app that needs one.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = layout(subviews: subviews, width: width)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var y = bounds.minY
        for row in layout(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func layout(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty, needed > width {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
