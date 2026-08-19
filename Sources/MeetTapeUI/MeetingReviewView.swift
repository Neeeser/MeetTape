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
        .onDisappear { model.saveNotes() }
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

    private var speakersCard: some View {
        SectionCard(
            title: "Speakers",
            subtitle: "Renaming applies immediately and does not re-run transcription."
        ) {
            if model.speakerKeys.isEmpty {
                Text("No speakers identified yet.").foregroundStyle(.secondary).font(.callout)
            } else {
                VStack(spacing: 8) {
                    ForEach(model.speakerKeys, id: \.self) { key in
                        speakerRow(key)
                    }
                }
            }
        }
    }

    private func speakerRow(_ key: String) -> some View {
        let assignment = model.speakers.entries[key]
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(SpeakerMap.fallbackName(for: key)).font(.callout)
                if let evidence = assignment?.evidence, assignment?.origin == .ai {
                    Text(evidence).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(width: 150, alignment: .leading)

            TextField("Name", text: model.nameBinding(for: key))
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.commitName(for: key) }
                .accessibilityLabel("Name for \(SpeakerMap.fallbackName(for: key))")

            if let assignment {
                Text(originLabel(assignment))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 96, alignment: .leading)
            }

            Button("Set") { model.commitName(for: key) }
                .disabled((model.draftNames[key] ?? "").isEmpty)
        }
    }

    private func originLabel(_ assignment: SpeakerAssignment) -> String {
        switch assignment.origin {
        case .human: "You set this"
        case .deterministic: "From the microphone track"
        case .ai:
            assignment.confidence.map { String(format: "Suggested %.0f%%", $0 * 100) } ?? "Suggested"
        }
    }

    private var transcriptCard: some View {
        SectionCard(
            title: "Transcript",
            subtitle: model.transcript == nil ? "Not available yet." : nil
        ) {
            if let transcript = model.transcript, !transcript.utterances.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(transcript.utterances) { utterance in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(model.speakers.resolvedName(for: utterance.speakerKey))
                                    .font(.callout.weight(.semibold))
                                Text(TranscriptRenderer().timecode(utterance.start))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text(utterance.text).font(.callout).textSelection(.enabled)
                        }
                    }
                }
            } else {
                HStack(spacing: 8) {
                    if model.metadata?.processing.state != .failed {
                        ProgressView().controlSize(.small)
                    }
                    Text(model.metadata?.processing.state.displayName ?? "Waiting")
                        .foregroundStyle(.secondary)
                    Button("Refresh") { model.reload() }.buttonStyle(.link)
                }
            }
        }
    }
}
