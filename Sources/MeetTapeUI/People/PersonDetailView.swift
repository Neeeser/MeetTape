import MeetTapeCore
import SwiftUI

/// One person: who they are, what MeetTape has learned of their voice, and what
/// the user has written about them.
struct PersonDetailView: View {
    let model: PeopleDirectoryModel
    let entry: SpeakerDirectoryEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                badges
                stats
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

    private var stats: some View {
        HStack(spacing: 10) {
            statBox("Voice profile", entry.profile.summary, detail: speechDetail)
            statBox(
                "Heard in",
                entry.meetingCount == 1 ? "1 meeting" : "\(entry.meetingCount) meetings",
                detail: entry.identity.lastSeenAt.map {
                    "Last \($0.formatted(date: .abbreviated, time: .shortened))"
                }
            )
        }
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
