import PipitCore
import PipitServices
import SwiftUI

/// One person: who they are, what Pipit has learned of their voice, and what
/// the user has written about them.
struct PersonDetailView: View {
    let model: PeopleDirectoryModel
    let entry: SpeakerDirectoryEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                badges
                linkedAccounts
                stats
                meetings
                notes
                actions
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            PersonAvatar(
                identity: entry.identity, image: model.avatarImage(for: entry),
                side: 56, showsBadge: false
            )
            .onTapGesture { Task { await model.chooseAvatar() } }
            .help("Choose a picture")

            VStack(alignment: .leading, spacing: 6) {
                TextField(
                    entry.identity.kind == .anonymous ? "Name this voice" : "Name",
                    text: model.text(\.nameDraft)
                )
                .font(.title3)
                .textFieldStyle(.plain)
                .onSubmit { Task { await model.commitName() } }

                TextField("Organization", text: model.text(\.organizationDraft))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textFieldStyle(.plain)
                    .onSubmit { Task { await model.commitName() } }

                if !entry.identity.aliases.isEmpty {
                    Text("Also \(entry.identity.aliases.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Button("Save") { Task { await model.commitName() } }
                        .disabled(model.nameDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    // Beside the name, because it is the one action here that
                    // is about this person rather than about the row: nobody
                    // else's voice can be read into the microphone.
                    if entry.identity.isLocalUser {
                        Button("Learn my voice…") { model.startVoiceEnrollment() }
                            .help("Read a few sentences so Pipit knows your voice")
                    }
                    if entry.identity.hasAvatar {
                        Button("Remove picture") { Task { await model.removeAvatar() } }
                    }
                }
                .padding(.top, 2)
                if entry.identity.kind == .anonymous {
                    Text(
                        "Every meeting this voice appeared in will show the name. Nothing is "
                            + "transcribed or analysed again."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var badges: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Heard on").font(.caption).foregroundStyle(.secondary)
            // Every platform at once rather than a picker, because the set is
            // eight items and toggling is the whole interaction.
            HStack(spacing: 6) {
                ForEach(PersonBadge.allCases) { badge in
                    let on = entry.identity.badges.contains(badge)
                    Button {
                        Task { await model.toggleBadge(badge) }
                    } label: {
                        Image(systemName: badge.symbolName)
                            .font(.system(size: 13))
                            .frame(width: 26, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(on ? Color.accentColor.opacity(0.22) : .clear)
                            )
                            .foregroundStyle(on ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(badge.label)
                }
            }
        }
    }

    /// The platform accounts confirmed as this person.
    ///
    /// One row per binding: the platform, the platform's own identifier, and
    /// the way out. A binding is written when the user says who a meeting's
    /// speaker is, so this is where a wrong answer gets taken back.
    @ViewBuilder private var linkedAccounts: some View {
        if !model.handles.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Linked accounts").font(.caption).foregroundStyle(.secondary)
                ForEach(model.handles, id: \.self) { handle in
                    HStack(spacing: 8) {
                        Text(handle.provider.capitalized)
                            .font(.caption.weight(.medium))
                        Text(handle.handle)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Unlink") { Task { await model.unlink(handle) } }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("This account stops naming this person. Their voice and name stay.")
                    }
                }
                Text("Meetings name this person from these accounts automatically.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var stats: some View {
        HStack(spacing: 10) {
            statBox("Voice profile", entry.profile.summary, detail: speechDetail)
            statBox(
                "Last heard",
                entry.identity.lastSeenAt.map { Format.day($0) } ?? "Not yet",
                detail: entry.meetingCount == 1
                    ? "1 meeting" : "\(entry.meetingCount) meetings"
            )
        }
    }

    /// The meetings this person was heard in, each a way into its transcript.
    ///
    /// A count answered "how often", which is the question nobody had. The one
    /// people ask of a name in this list is which conversations it was in, and
    /// the play button answers the one after that by ear.
    @ViewBuilder private var meetings: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Meetings").font(.caption).foregroundStyle(.secondary)
            if model.loadingAppearances {
                Text("Reading the archive…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else if model.appearances.isEmpty {
                Text(
                    entry.meetingCount == 0
                        ? "Not heard in a meeting yet."
                        : "The recordings this voice was heard in are no longer on disk."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                ForEach(model.appearances) { appearance in meetingRow(appearance) }
            }
        }
    }

    private func meetingRow(_ appearance: PersonAppearance) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(appearance.title).font(.callout).lineLimit(1)
                Text(
                    "\(Format.day(appearance.startedAt)) · "
                        + "\(Format.shortDuration(appearance.speechSeconds)) of speech"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if appearance.hasAudio {
                Button {
                    model.playSample(appearance)
                } label: {
                    Image(
                        systemName: model.player.playing == appearance.meetingID
                            ? "stop.fill" : "play.fill"
                    )
                    .font(.system(size: 11))
                    .frame(width: 22, height: 20)
                }
                .buttonStyle(.plain)
                .foregroundStyle(
                    model.player.playing == appearance.meetingID ? Color.accentColor : .secondary
                )
                .help("Hear this person in this meeting")
            }
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.35)))
        .onTapGesture { model.openMeeting(appearance) }
        .help("Open this meeting")
    }

    private var speechDetail: String? {
        let seconds = entry.profile.speechSeconds
        guard seconds > 0 else { return nil }
        return "\(Int(seconds / 60)) min of confirmed speech"
    }

    private func statBox(_ label: String, _ value: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout)
            if let detail {
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Notes").font(.caption).foregroundStyle(.secondary)
                Text("written into the transcript of every meeting they are in")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            TextEditor(text: Binding(
                get: { model.notesDraft },
                set: { model.notesDraft = $0; model.notesChanged() }
            ))
            .font(.callout)
            .frame(minHeight: 90)
            .padding(4)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Forget learned voice") { model.confirmForgetVoice() }
                .disabled(entry.profile == .none)
            Button("Delete", role: .destructive) { model.confirmDeleteSelection() }
            Spacer()
        }
    }
}
