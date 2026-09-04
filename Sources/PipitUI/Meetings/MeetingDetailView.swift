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
    /// Confirms a copy for two seconds, because the clipboard says nothing.
    @State private var copied = false

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
            if detail.metadata?.processing.skippedForMissingKey == true {
                missingKeyBar
                Divider()
            }
            // Under the notices rather than over them: a meeting that did not
            // finish is the more urgent thing to read, and this asks a question
            // that can wait.
            if let suggestion = detail.titleSuggestion {
                suggestionBar(suggestion)
                Divider()
            }
            // Under the title bar rather than over it. Accepting a title
            // renames the directory, and the folder offer quotes that title, so
            // the title is the question to answer first.
            if let folder = model.folderSuggestion(for: detail.meetingID) {
                folderSuggestionBar(folder)
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

            if let warnings = detail.metadata?.captureWarnings, !warnings.isEmpty {
                // What went wrong while this was recorded, kept with the
                // meeting. A far end that was never captured is the usual one,
                // and a transcript read without knowing that reads as a
                // recogniser failure.
                Label(
                    CaptureWarning.message(forKey: warnings[0]),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .help(warnings.map(CaptureWarning.message(forKey:)).joined(separator: "\n"))
                .padding(.top, 4)
            }

            HStack(spacing: 8) {
                folderMenu
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

    /// Says why a meeting completed with no summary.
    ///
    /// The one stage that needs the cloud is the one stage allowed to be
    /// skipped without failing the meeting, which left no trace anywhere when a
    /// stored key went missing.
    private var missingKeyBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            Text("No API key stored, so summary, notes and speaker suggestions were skipped")
                .font(.callout)
            Spacer(minLength: 8)
            Button("Open Settings") { model.openSettings() }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.08))
    }

    /// Which folder this meeting is in, and the way to change it.
    ///
    /// On the path line because the path line is where the folder already was:
    /// with folders on disk, what that line prints and what this control sets
    /// are the same fact.
    @ViewBuilder private var folderMenu: some View {
        let current = model.rows.first { $0.id == detail.meetingID }?.summary.folderName
        let tint = current
            .flatMap { name in model.folderRows.first { $0.name == name } }
            .map { FolderTint.color($0.folder.tintIndex) }
        Menu {
            ForEach(model.folderRows) { folder in
                Button {
                    file(in: folder.name)
                } label: {
                    if folder.name == current {
                        Label(folder.name, systemImage: "checkmark")
                    } else {
                        Text(folder.name)
                    }
                }
            }
            if !model.folderRows.isEmpty { Divider() }
            Button("New Folder…") {
                model.pendingNewFolder = NewFolderRequest(filing: [detail.meetingID])
            }
            if current != nil {
                Button("Remove from Folder") { file(in: nil) }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder.fill").font(.system(size: 9))
                Text(current ?? "Not in a folder")
            }
            .font(.caption)
            .foregroundStyle(tint ?? .secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .help("Filing a meeting moves its folder on disk. Nothing inside it is rewritten.")
    }

    private func file(in folder: String?) {
        guard let row = model.rows.first(where: { $0.id == detail.meetingID }) else { return }
        model.file([row], in: folder)
    }

    /// The folder this meeting was thought to belong in.
    ///
    /// The same bar as the suggested title above it, with one difference that
    /// matters: the icon says whether a model was involved. A repeat arrow means
    /// metadata matched metadata and nothing was read.
    private func folderSuggestionBar(_ suggestion: FolderSuggestion) -> some View {
        HStack(spacing: 7) {
            Image(systemName: suggestion.reason == .model ? "sparkles" : "arrow.trianglehead.2.clockwise")
                .foregroundStyle(suggestion.reason == .model ? Color.accentColor : .secondary)
                .accessibilityHidden(true)
            Text(suggestion.reason == .model ? "Suggested folder" : "Recurring meeting")
                .foregroundStyle(.secondary)
                .layoutPriority(1)
            Text(suggestion.folderName).layoutPriority(1)
            Text(suggestion.why)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(quoteHelp(suggestion))
            Spacer(minLength: 8)
            Button("Move it") { model.acceptFolderSuggestion(for: detail.meetingID) }
            Button("Dismiss") { model.dismissFolderSuggestion(for: detail.meetingID) }
                .buttonStyle(.link)
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(
            suggestion.reason == .model
                ? Color.accentColor.opacity(0.08)
                : Color.primary.opacity(0.04)
        )
    }

    private func quoteHelp(_ suggestion: FolderSuggestion) -> String {
        guard let quote = suggestion.quote, !quote.isEmpty else { return suggestion.why }
        guard let at = suggestion.atSeconds else { return "\u{201C}\(quote)\u{201D}" }
        return "\u{201C}\(quote)\u{201D} at \(Format.duration(at))"
    }

    /// The generated title, offered against the name the meeting already has.
    ///
    /// Shaped like the notice and receipt bars beside it rather than as a card
    /// or a popover, so it reads as one more thing the pane is telling you.
    /// Below the title rather than beside it, because a row that appears next
    /// to the title moves the title while it is being read.
    private func suggestionBar(_ suggestion: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "sparkles")
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text("Suggested title").foregroundStyle(.secondary).layoutPriority(1)
            // A generated title can outrun a narrow pane, and the whole point
            // is reading it before deciding.
            Text(suggestion).lineLimit(1).truncationMode(.tail).help(suggestion)
            Spacer(minLength: 8)
            Button("Use it") { detail.acceptTitleSuggestion() }
                .buttonStyle(.link)
                .help("Renames this meeting, and its folder, to the suggested title.")
            Button("Dismiss") { detail.declineTitleSuggestion() }
                .buttonStyle(.link)
                .help("Keeps the current title and stops offering this one.")
        }
        .font(.caption)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.08))
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
                // Only where somebody is still unnamed. The control fills a
                // gap, so with no gap it is not drawn rather than drawn dim.
                if detail.unnamedSpeakerCount > 0 { suggestNames }
                reanalyze
            }
            if detail.speakerRows.isEmpty {
                Text(waitingText).font(.caption).foregroundStyle(.secondary)
            } else {
                SpeakerChips(model: model, detail: detail)
            }
            // Only where there is something to propose. A meeting whose voices
            // all matched, and one where nobody was named out loud, both draw
            // nothing here rather than a line saying so.
            if !detail.speakerSuggestions.isEmpty {
                SuggestionPills(model: model, detail: detail)
            }
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

    /// Asks the model to name the speakers nothing else could.
    ///
    /// An icon with no label, because the row it sits on is already a label and
    /// a caption plus a menu title. The same command is spelled out in the menu
    /// beside it, which is what makes the icon learnable rather than guessed at.
    private var suggestNames: some View {
        Button {
            detail.suggestSpeakerNames()
        } label: {
            if detail.isSuggestingNames {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "sparkles").font(.caption)
            }
        }
        .buttonStyle(.borderless)
        .disabled(detail.isSuggestingNames)
        .help(suggestNamesTitle)
    }

    private var suggestNamesTitle: String {
        let count = detail.unnamedSpeakerCount
        return "Suggest names for \(count) \(count == 1 ? "speaker" : "speakers")"
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
            // Below a divider rather than beside the two run commands. Those
            // re-cluster the audio on this Mac and clear names. This reads the
            // words and sends them away. Same menu, different machine.
            if detail.unnamedSpeakerCount > 0 {
                Divider()
                Button(suggestNamesTitle) { detail.suggestSpeakerNames() }
                    .disabled(detail.isSuggestingNames)
            }
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
            copyTranscriptButton
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    /// Puts `transcript.md` on the clipboard.
    ///
    /// On the tab row rather than in the transcript itself: it copies the whole
    /// document whichever tab is open, and the row is the one bar that stays on
    /// screen while the transcript scrolls.
    private var copyTranscriptButton: some View {
        Button {
            guard detail.copyTranscript() else { return }
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
        } label: {
            Label(
                copied ? "Copied" : "Copy transcript",
                systemImage: copied ? "checkmark" : "doc.on.doc"
            )
        }
        .controlSize(.small)
        .disabled(detail.transcript == nil)
        .help("Copies transcript.md, the whole transcript as it stands on disk.")
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
                } else if detail.canGenerateEnrichment {
                    writeSummary
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

    /// Offered where a finished meeting has no summary, which is what a meeting
    /// processed before a key was stored looks like.
    ///
    /// Inside the section rather than in a bar at the top of the pane: the tab
    /// the text belongs to is where a reader goes looking for it. Nothing is
    /// replaced, so there is nothing to confirm and no bar to dismiss.
    private var writeSummary: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("No summary was written for this meeting.")
                .foregroundStyle(.secondary)
            Button {
                detail.generateEnrichment()
            } label: {
                if detail.isEnriching {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("Reading the transcript…")
                    }
                } else {
                    Label("Write a summary", systemImage: "sparkles")
                }
            }
            .disabled(detail.isEnriching)
            Text(
                "One request writes the summary, the notes and a suggested title. "
                    + "Nothing already on this meeting is replaced."
            )
            .font(.caption).foregroundStyle(.secondary)
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

                if let generated = detail.generatedNotes, !generated.isEmpty {
                    SectionCard(
                        title: "Meeting notes",
                        subtitle: "Written from the transcript. Kept apart from your notes above."
                    ) {
                        Text(generated).font(.body).textSelection(.enabled)
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

/// Names the model heard, under the speakers they belong to.
///
/// A recommendation rather than an answer: the pill says who it thinks a
/// speaker is and what it heard, and nothing reaches the speaker map until
/// somebody presses the tick. Written this way round because a name filled in
/// for you is only worth having when it is right, and the one place the model
/// is asked about is the one place nothing else could work it out.
struct SuggestionPills: View {
    let model: MeetingsWindowModel
    let detail: MeetingReviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                Text("Heard in the conversation")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Dismiss all") { model.dismissAllSuggestions() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            FlowRow(spacing: 6) {
                ForEach(detail.speakerSuggestions) { row in pill(row) }
            }
        }
        .padding(.top, 3)
    }

    private func pill(_ row: MeetingSuggestionRow) -> some View {
        HStack(spacing: 6) {
            SpeakerFace(name: "", side: 20)
            Text(row.speakerLabel)
                .font(.callout)
                .foregroundStyle(.secondary)
            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(row.suggestion.name).font(.callout.weight(.medium))
            // The band rather than the number behind it. A model's confidence
            // reads as a probability when it is shown as a percentage, and it
            // is not one.
            Text(row.suggestion.band.displayName)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 2) {
                Button { model.acceptSuggestion(row) } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 21, height: 21)
                        .background(Circle().fill(Color.accentColor))
                }
                .buttonStyle(.plain)
                .help("Name \(row.speakerLabel) as \(row.suggestion.name)")

                Button { model.dismissSuggestion(row) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 21, height: 21)
                        .background(Circle().fill(Color.primary.opacity(0.07)))
                }
                .buttonStyle(.plain)
                .help("Not this. The name is not offered again.")
            }
            .padding(.leading, 2)
        }
        .padding(.leading, 3)
        .padding(.trailing, 3)
        .padding(.vertical, 3)
        .background { Capsule().fill(Color.accentColor.opacity(0.09)) }
        .overlay { Capsule().stroke(Color.accentColor.opacity(0.30), lineWidth: 1) }
        .help(why(row.suggestion))
    }

    /// The line that earned the guess, which is the whole case for it.
    private func why(_ suggestion: SpeakerNameSuggestion) -> String {
        let renderer = TranscriptRenderer()
        var text = "“\(suggestion.quote)” at \(renderer.timecode(suggestion.atSeconds))"
        if suggestion.expandedFromCalendar {
            text += "\nFull name from the calendar invite."
        }
        return text
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
            Button(row.displayName) { detail.beginNaming(target(row)) }
                .buttonStyle(.plain)
                .font(.callout)
                .popover(isPresented: picking(row), arrowEdge: .bottom) {
                    PeoplePickerView(
                        people: detail.knownPeople,
                        context: detail.pickerContext,
                        model: detail.picker,
                        leaveUnnamedTitle: row.isUnnamed ? nil : "Leave unnamed",
                        onPick: { person in
                            detail.cancelNaming()
                            model.assignCluster(row, to: person)
                        },
                        onNewPerson: { name in
                            detail.cancelNaming()
                            model.assignCluster(row, toNewPerson: name)
                        },
                        onLeaveUnnamed: {
                            detail.cancelNaming()
                            model.clearCluster(row)
                        }
                    )
                }
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

    private func target(_ row: MeetingSpeakerRow) -> SpeakerNamingTarget {
        .cluster(row.allClusterIDs, in: row.recordingID)
    }

    private func picking(_ row: MeetingSpeakerRow) -> Binding<Bool> {
        let id = target(row).id
        return Binding(
            get: { detail.isNaming(id) },
            set: { open in if !open, detail.isNaming(id) { detail.cancelNaming() } }
        )
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
