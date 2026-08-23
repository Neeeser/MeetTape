import AppKit
import MeetTapeCore
import MeetTapeServices
import SwiftUI

/// The post-meeting panel.
///
/// It appears as soon as the audio is safe, before transcription has run, so the
/// title and context can be captured while they are fresh. Closing it does not
/// interrupt anything.
public struct MeetingReviewView: View {
    let model: MeetingReviewModel

    public init(model: MeetingReviewModel) {
        self.model = model
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                detailsCard
                if let suggestion = model.continuationSuggestion {
                    continuationCard(suggestion)
                }
                if let failure = model.metadata?.processing.lastFailure {
                    failureCard(failure)
                }
                participantsCard
                speakersCard
                transcriptCard
                if let summary = model.summary, !summary.isEmpty {
                    SectionCard(title: "Summary", subtitle: "Generated from the transcript. Your notes are stored separately.") {
                        Text(summary).font(.callout).textSelection(.enabled)
                    }
                }
            }
            .padding(20)
        }
        .frame(minWidth: 640, minHeight: 480)
        .onDisappear { model.saveEdits() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Meeting saved").font(.title3.weight(.semibold))
            if let metadata = model.metadata {
                HStack(spacing: 10) {
                    Text(metadata.source.displayName)
                    Text("·")
                    Text(Format.day(metadata.startedAt))
                    Text("·")
                    Text(Format.shortDuration(metadata.durationSeconds))
                    StageBadge(state: metadata.processing.state)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let directory = model.directory {
                HStack {
                    Text(directory.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Button("Reveal in Finder") { model.reveal() }.buttonStyle(.link)
                    if model.transcript != nil {
                        Button("Rebuild Transcript") { model.rebuildTranscript() }
                            .buttonStyle(.link)
                            .help("Re-assembles the transcript from the stored API responses. Makes no API request.")
                    }
                }
            }
            if model.metadata?.hadOtherAudibleTabs == true {
                Label(
                    "Another browser tab was playing audio during this meeting, so the meeting "
                        + "track may contain that audio as well.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
    }

    private var detailsCard: some View {
        SectionCard(title: "Title and context", subtitle: "Saved immediately, including while processing is running.") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Title", text: model.titleBinding())
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.save() }
                Text("Notes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: model.notesBinding())
                    .font(.body)
                    .frame(minHeight: 90)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                Text(
                    "Context such as “Company X call with me, my boss Chris, John and Tim” is "
                        + "used as input when speaker names are suggested."
                )
                .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Save") { model.save() }
                    Spacer()
                }
            }
        }
    }

    private func continuationCard(_ suggestion: (title: String, reason: String)) -> some View {
        SectionCard(
            title: "Same meeting?",
            subtitle: "Combining links the two recordings. Neither recording's audio is moved or modified."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text("This may be a continuation of “\(suggestion.title)”. \(suggestion.reason).")
                HStack {
                    Button("Combine") { model.combineWithEarlier() }
                    Button("Keep Separate") { model.keepSeparate() }
                }
            }
        }
    }

    private func failureCard(_ failure: ProcessingFailure) -> some View {
        SectionCard(title: "Processing stopped", subtitle: failure.stage.displayName) {
            VStack(alignment: .leading, spacing: 10) {
                Text(failure.message)
                HStack {
                    if failure.isRetryable {
                        Button("Retry") { model.retry() }
                    } else {
                        Button("Try Again Anyway") { model.retry() }
                    }
                }
            }
        }
    }

    private var participantsCard: some View {
        SectionCard(
            title: "Participants",
            subtitle: "Optional. Helps recognition without ever forcing a name onto a speaker who did not match."
        ) {
            VStack(alignment: .leading, spacing: 8) {
                if !model.expectedParticipants.isEmpty {
                    ForEach(model.expectedParticipants, id: \.self) { name in
                        HStack {
                            Text(name).font(.callout)
                            Spacer()
                            Button("Remove") { model.removeParticipant(name) }
                                .buttonStyle(.link).font(.caption)
                        }
                    }
                }
                HStack {
                    TextField("Add a name", text: model.text(\.participantDraft))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.addParticipant() }
                    Button("Add") { model.addParticipant() }
                        .disabled(model.participantDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text(
                    "Changing this re-runs speaker matching only. Nothing is transcribed again."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var speakersCard: some View {
        SectionCard(
            title: "Speakers",
            subtitle: "Naming a speaker applies immediately and does not re-run transcription."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if model.speakerRows.isEmpty {
                    Text("No speakers identified yet.").foregroundStyle(.secondary).font(.callout)
                } else {
                    ForEach(model.speakerRows) { row in speakerRow(row) }
                }
                if model.namingCluster != nil { namingField }
                reanalyzeRow
            }
        }
        .task { await model.reloadAll() }
    }

    private func speakerRow(_ row: MeetingSpeakerRow) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.displayName).font(.callout)
                Text(speakerDetail(row)).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(minWidth: 190, alignment: .leading)

            ConfidenceBadge(band: row.band, origin: row.origin)

            Spacer()

            Menu("Change") {
                ForEach(model.knownPeople) { person in
                    Button(person.identity.resolvedName) {
                        model.assignCluster(row.clusterID, to: person)
                    }
                }
                if !model.knownPeople.isEmpty { Divider() }
                Button("New person…") { model.beginNamingCluster(row.clusterID) }
                Button("Leave unknown") { model.clearCluster(row.clusterID) }
            }
            .fixedSize()
        }
    }

    /// What the automatic decision was, in words rather than a number.
    ///
    /// A cosine similarity of 0.92 is not a 92% probability: genuine matches sit
    /// between 0.72 and 0.96 and so do the hardest wrong ones, so the score is
    /// kept for diagnostics and never shown as a percentage.
    private func speakerDetail(_ row: MeetingSpeakerRow) -> String {
        var parts: [String] = [Format.shortDuration(row.speechSeconds)]
        switch row.origin {
        case .human: parts.append("you set this")
        case .deterministic: parts.append("your microphone track")
        case .voiceProfile: parts.append("matched a saved voice")
        case .anonymousVoice:
            parts.append(
                row.meetingCount > 1
                    ? "heard in \(row.meetingCount) meetings"
                    : "heard before"
            )
        case .ai:
            if row.identity == nil { parts.append("not recognized") }
        }
        return parts.joined(separator: " · ")
    }

    private var namingField: some View {
        HStack {
            TextField("Name", text: model.text(\.newPersonDraft))
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.commitNaming() }
            Button("Save") { model.commitNaming() }
                .disabled(model.newPersonDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel") { model.cancelNaming() }
        }
    }

    private var reanalyzeRow: some View {
        HStack(spacing: 8) {
            Text("Re-analyze speakers").font(.caption).foregroundStyle(.secondary)
            TextField("Count", text: model.text(\.reanalyzeCount))
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
            Button("Run") { model.reanalyzeSpeakers() }
                .disabled(!model.canReanalyze)
            if model.isReanalyzing { ProgressView().controlSize(.small) }
            Text(
                model.localModelsReady
                    ? "Leave the count empty to let MeetTape decide. The words are not "
                        + "re-transcribed. Speaker names are cleared, because the clusters "
                        + "they name no longer exist. Corrections to single lines are kept."
                    : "Runs on this Mac. Download the speech models in Settings to use it."
            )
            .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var transcriptCard: some View {
        SectionCard(
            title: "Transcript",
            subtitle: model.transcript == nil
                ? "Not available yet."
                : "Click a line's name or time to correct that line alone."
        ) {
            if !model.combinedLines.isEmpty {
                if model.isSplitRecording { continuationNotice }
                // Lazy because a long meeting is thousands of lines and each one
                // carries a menu.
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(CombinedLineBlock.blocks(from: model.combinedLines)) { block in
                        blockView(block)
                    }
                }
                if model.namingLine != nil { namingField }
            } else {
                HStack(spacing: 8) {
                    if model.metadata?.processing.state != .failed {
                        ProgressView().controlSize(.small)
                    }
                    Text(processingLabel)
                        .foregroundStyle(.secondary)
                    Button("Refresh") { model.reload() }.buttonStyle(.link)
                }
            }
        }
    }

    /// What the panel says when the conversation is held in more than one
    /// recording.
    private var continuationNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
            Text(
                "Recorded in \(model.recordings.count) parts, shown in order. "
                    + "The call dropped and was rejoined."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer()
            ForEach(model.recordings.dropFirst(), id: \.id) { recording in
                Button("Separate part \(index(of: recording) + 1)") {
                    model.detach(recording.id)
                }
                .buttonStyle(.link)
                .font(.caption)
                .help("Keeps both recordings and undoes the link between them")
            }
        }
        .padding(.bottom, 4)
    }

    private func index(of recording: MeetingMetadata) -> Int {
        model.recordings.firstIndex { $0.id == recording.id } ?? 0
    }

    /// One speaker's consecutive lines under a single name header. Every line
    /// keeps its own correction menu: the first on its name, the rest on their
    /// timecodes.
    private func blockView(_ block: CombinedLineBlock) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(block.lines.enumerated()), id: \.element.id) { index, line in
                utteranceRow(line, showsName: index == 0)
            }
        }
    }

    private func utteranceRow(_ line: CombinedLine, showsName: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if showsName {
                    speakerMenu(for: line, label: line.speakerName)
                        .font(.callout.weight(.semibold))
                    Text(TranscriptRenderer().timecode(line.timelineStart))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    speakerMenu(for: line, label: TranscriptRenderer().timecode(line.timelineStart))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("Correct the speaker on this line alone")
                }
                if model.correctedLines.contains(line.id) {
                    Image(systemName: "pencil.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("You set the speaker on this line")
                }
            }
            Text(line.utterance.text).font(.callout).textSelection(.enabled)
        }
    }

    private func speakerMenu(for line: CombinedLine, label: String) -> some View {
        Menu(label) {
            ForEach(model.knownPeople) { person in
                Button(person.identity.resolvedName) {
                    model.assignUtterance(line, to: person)
                }
            }
            if !model.knownPeople.isEmpty { Divider() }
            Button("New person…") { model.beginNamingUtterance(line) }
            Button("Use this speaker's name") { model.clearUtterance(line) }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// What the panel says while it waits.
    private var processingLabel: String {
        guard let state = model.metadata?.processing.state else { return "Waiting" }
        if let progress = model.progress, let detail = progress.detail { return detail }
        if let progress = model.progress, let fraction = progress.fraction, fraction > 0, fraction < 1 {
            return "\(state.displayName) — \(Int(fraction * 100))%"
        }
        return state.displayName
    }
}

/// High, Likely or Unknown. Never a percentage: the score behind it is a cosine
/// similarity, and the genuine and impostor distributions overlap at the top.
struct ConfidenceBadge: View {
    let band: SpeakerConfidenceBand
    let origin: SpeakerAssignmentOrigin

    var body: some View {
        Text(label)
            .font(.caption2)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(colour.opacity(0.15), in: Capsule())
            .foregroundStyle(colour)
    }

    private var label: String {
        switch origin {
        case .human: "Confirmed"
        case .deterministic: "You"
        case .voiceProfile: band.displayName
        case .anonymousVoice: "Seen before"
        case .ai: band == .unknown ? "Unknown" : band.displayName
        }
    }

    private var colour: Color {
        switch origin {
        case .human, .deterministic: .green
        case .voiceProfile: band == .high ? .green : .orange
        case .anonymousVoice: .blue
        case .ai: .secondary
        }
    }
}
