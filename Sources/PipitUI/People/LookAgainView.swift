import PipitCore
import PipitServices
import SwiftUI

/// Unnamed voices that match somebody now, offered one at a time.
///
/// Recognition runs once, when a meeting is processed. A profile that grew
/// afterwards never gets to answer the old question, so a voice heard before its
/// person had a profile stays a number for good, and an unnamed voice heard once
/// is deleted after ninety days. This is where that is put right.
///
/// Offered rather than applied. These are exactly the decisions the first pass
/// declined to make on its own, and applying them here would be the automatic
/// naming that pass exists to avoid, one step further along.
struct LookAgainView: View {
    let model: PeopleDirectoryModel
    let state: PeopleDirectoryModel.LookAgainState
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if state.scanning {
                Text("Scoring unnamed voices…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(18)
            } else if state.matches.isEmpty {
                Text(
                    "Naming a speaker on a meeting, or reading a few sentences aloud in "
                        + "Settings, gives the next pass more to match against."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
            } else {
                list
            }
            Divider()
            footer
        }
        .frame(width: 760)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.title3.weight(.semibold))
            if !state.matches.isEmpty {
                Text(
                    "Confirming a match gives that voice the name in every meeting it was "
                        + "heard in, and its audio joins that person's voice profile. Nothing "
                        + "changes until you confirm."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private var title: String {
        if state.scanning { return "Looking again" }
        let count = state.matches.count
        if count == 0 { return "No unnamed voice matches a profile" }
        return count == 1
            ? "One unnamed voice matches a profile"
            : "\(count) unnamed voices match a profile"
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(state.matches) { row in
                    if let name = state.confirmed[row.voice.id] {
                        confirmedRow(row, name: name)
                    } else {
                        matchRow(row)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 14)
        }
        .frame(maxHeight: 420)
    }

    // MARK: - a row waiting for an answer

    private func matchRow(_ row: VoiceRematch) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                voice(row).frame(width: 196, alignment: .leading)
                Image(systemName: "arrow.right")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                candidate(row)
                // No confidence badge. Only matches that clear the naming bar
                // are offered, so a band on every row would read the same on
                // every row; the score and the gap under it are the evidence.
                Button("Confirm") { Task { await model.confirmMatch(row) } }
                Button("Not this") { model.dismissMatch(row) }
            }
            Text(reason(row))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
    }

    private func voice(_ row: VoiceRematch) -> some View {
        HStack(spacing: 8) {
            SpeakerFace(name: "", identityID: row.voice.id, side: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.voice.resolvedName).font(.callout).lineLimit(1)
                Text(
                    "\(row.heardIn.count == 1 ? "1 meeting" : "\(row.heardIn.count) meetings") · "
                        + "\(Format.shortDuration(row.speechSeconds)) of speech"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let appearance = row.heardIn.first, appearance.hasAudio {
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
                .help("Hear this voice")
            }
        }
    }

    private func candidate(_ row: VoiceRematch) -> some View {
        HStack(spacing: 8) {
            SpeakerFace(
                name: row.match.isNamed ? row.match.resolvedName : "",
                identityID: row.match.id, side: 32
            )
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(row.match.resolvedName).font(.callout).lineLimit(1)
                    if row.match.isLocalUser {
                        Text("You")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.20)))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(scoreLine(row))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    /// The score and what it beat. A number on its own says nothing: genuine
    /// scores and impostor scores overlap almost completely, and it is the gap
    /// to the runner-up that carries the decision.
    private func scoreLine(_ row: VoiceRematch) -> String {
        let score = String(format: "%.2f", row.score)
        guard let runnerUp = row.runnerUpScore else { return "\(score), nothing else close" }
        return "\(score), next best \(String(format: "%.2f", runnerUp))"
    }

    /// Why this was missed the first time, and how long is left to say so.
    private func reason(_ row: VoiceRematch) -> String {
        var parts: [String] = []
        if let appearance = row.heardIn.first {
            parts.append("\(appearance.title) (\(Format.day(appearance.startedAt)))")
        }
        if row.profileCameLater, let began = row.matchProfileBegan {
            parts.append(
                "\(row.match.resolvedName)'s voice profile begins on \(Format.day(began)), "
                    + "after this meeting was processed"
            )
        }
        if let forgotten = row.forgottenAt {
            let days = Int(forgotten.timeIntervalSinceNow / 86_400)
            parts.append(
                days <= 0 ? "Due to be forgotten" : "Forgotten in \(days) day\(days == 1 ? "" : "s")"
            )
        }
        return parts.joined(separator: ". ") + (parts.isEmpty ? "" : ".")
    }

    // MARK: - a row already answered

    private func confirmedRow(_ row: VoiceRematch, name: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.green)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.green.opacity(0.18)))
            VStack(alignment: .leading, spacing: 1) {
                Text("\(row.voice.resolvedName) is \(name)").font(.callout)
                Text(
                    row.heardIn.count == 1
                        ? "One meeting now names them."
                        : "\(row.heardIn.count) meetings now name them."
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.35)))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(
                state.scored == 1
                    ? "1 voice scored" : "\(state.scored) voices scored"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer()
            Button("Done") { close() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }
}
