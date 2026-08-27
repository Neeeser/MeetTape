import AppKit
import PipitCore
import PipitServices
import SwiftUI

/// The meetings window: the archive on the left, one meeting on the right.
///
/// The same two-pane shape as the People window, for the same reason: a list
/// that grows to hundreds of rows needs search and grouping, and the thing it
/// selects needs room to be read.
public struct MeetingsWindowView: View {
    let model: MeetingsWindowModel

    public init(model: MeetingsWindowModel) {
        self.model = model
    }

    public var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 240, idealWidth: 272, maxWidth: 380)
            detail.frame(minWidth: 460)
        }
        .frame(minWidth: 900, minHeight: 560)
        .task { await model.reload() }
        .alert(
            model.pendingTrash?.title ?? "",
            isPresented: Binding(
                get: { model.pendingTrash != nil },
                set: { if !$0 { model.pendingTrash = nil } }
            )
        ) {
            // Captured here, while the alert still has one. The button's action
            // runs after the dismissal has cleared `pendingTrash`, so reading
            // it back there finds nothing to move.
            let trash = model.pendingTrash
            Button("Cancel", role: .cancel) { model.pendingTrash = nil }
            Button("Move to Trash", role: .destructive) {
                guard let trash else { return }
                Task { await model.performTrash(trash) }
            }
        } message: {
            Text(model.pendingTrash?.message ?? "")
        }
        .alert(
            "Not everything was moved",
            isPresented: Binding(
                get: { model.trashProblem != nil },
                set: { if !$0 { model.trashProblem = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.trashProblem = nil }
        } message: {
            Text(model.trashProblem ?? "")
        }
        // Writes a half-typed title or note before the window goes away. The
        // model saves 1.5 seconds after typing stops, so without this a close
        // inside that window loses what was typed.
        .onDisappear { model.end() }
    }

    // MARK: - sidebar

    /// Grouped once per pass and handed to the list and the footer. Both need
    /// it, and with a query typed the grouping walks every transcript the index
    /// holds, so asking twice does that walk twice.
    private var sidebar: some View {
        let sections = model.sections
        let visible = sections.reduce(0) { $0 + $1.rows.count }
        return VStack(spacing: 0) {
            VStack(spacing: 8) {
                searchField
                Picker("", selection: Binding(
                    get: { model.filter }, set: { model.filter = $0 }
                )) {
                    ForEach(MeetingsFilter.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(10)
            Divider()
            list(sections)
            Divider()
            footer(visible: visible)
        }
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Search titles, people, words", text: model.text(\.query))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 6).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        .help(
            model.searchesTranscripts
                ? "Searches titles, notes, speaker names and every word of every transcript"
                : "Searches titles, notes and speaker names. The transcripts are still being read"
        )
    }

    private func list(_ sections: [MeetingsSection]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if sections.isEmpty { emptyList }
                ForEach(sections) { section in
                    Text("\(section.title) · \(section.rows.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.top, 10)
                        .padding(.bottom, 4)
                    ForEach(section.rows) { row in MeetingRowView(model: model, row: row) }
                }
            }
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder private var emptyList: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.isLoading {
                Text("Reading the archive…")
            } else if model.rows.isEmpty {
                Text("No meetings yet")
                Text(
                    "Pipit starts recording when it sees a call. You can also import a "
                        + "recording from the menu bar."
                )
                .foregroundStyle(.secondary)
            } else if !model.query.isEmpty {
                Text("No match")
                Text(
                    model.searchesTranscripts
                        ? "Search covers titles, notes, speaker names and every word of every "
                            + "transcript."
                        : "Search covers titles, notes and speaker names. The transcripts are "
                            + "still being read."
                )
                .foregroundStyle(.secondary)
            } else if model.filter == .archived {
                Text("Nothing archived")
                Text(
                    "Right-click a meeting to archive it. It leaves this list and its folder "
                        + "stays where it is."
                )
                .foregroundStyle(.secondary)
            } else {
                Text("Nothing under this filter").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(12)
    }

    private func footer(visible: Int) -> some View {
        HStack(spacing: 8) {
            Text(footerText(visible: visible))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button {
                model.revealArchive()
            } label: {
                Label("Open folder", systemImage: "folder")
                    .font(.caption)
            }
            .buttonStyle(.link)
            .help("Every meeting is an ordinary folder. Opening it changes nothing.")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func footerText(visible: Int) -> String {
        // Against what the filter holds rather than the whole archive. With
        // anything archived, All never shows every row and the footer read
        // "14 of 15" with nothing typed in the search field.
        let held = model.filteredRows.count
        if model.selection.count > 1 {
            return "\(visible) of \(held) · \(model.selection.count) selected"
        }
        if visible != held {
            return "\(visible) of \(held)"
        }
        return "\(held) \(held == 1 ? "meeting" : "meetings") · "
            + Format.shortDuration(model.totalDuration)
    }

    // MARK: - detail

    @ViewBuilder private var detail: some View {
        if model.selection.count > 1 {
            MeetingsSelectionView(model: model)
        } else if let detail = model.detail {
            MeetingDetailView(model: model, detail: detail)
        } else {
            VStack(spacing: 6) {
                Text("Select a meeting").font(.title3)
                Text("Its transcript, speakers and notes appear here. The folder on disk is one click away.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// One meeting in the sidebar: what it was, when, and who was in it.
///
/// The faces are what make an unnamed voice visible from the list: a meeting
/// still holding one shows the same grey waveform circle the People window uses,
/// so the work is findable without opening anything.
struct MeetingRowView: View {
    let model: MeetingsWindowModel
    let row: MeetingRow

    var body: some View {
        let selected = model.selection.contains(row.id)
        return HStack(spacing: 8) {
            kindIcon
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title).font(.callout).lineLimit(1)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            trailing
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color.accentColor.opacity(0.18) : .clear)
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            model.select(row.id, extending: NSEvent.modifierFlags.contains(.command))
        }
        .contextMenu { menu }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.title), \(subtitle)")
    }

    /// What a right-click offers. It acts on the whole selection when this row
    /// is part of it, and on this row alone otherwise, so the items say how
    /// many meetings they will reach.
    @ViewBuilder private var menu: some View {
        let targets = model.contextTargets(for: row)
        let many = targets.count > 1
        Button(many ? "Reveal \(targets.count) in Finder" : "Reveal in Finder") {
            model.revealTargets(targets)
        }
        Button(many ? "Rebuild \(targets.count) transcripts" : "Rebuild transcript") {
            model.rebuildTargets(targets)
        }
        Divider()
        if targets.allSatisfy(\.isArchived) {
            Button(many ? "Put \(targets.count) back" : "Put back") {
                model.setArchived(false, targets)
            }
        } else {
            Button(many ? "Archive \(targets.count) meetings" : "Archive") {
                model.setArchived(true, targets)
            }
        }
        // Offered on every row, including one that says it is recording. That
        // state also belongs to a meeting a crash left behind, and refusing
        // those is how a row becomes permanent. A recording in progress is
        // refused by the runtime, and the alert says which meeting and why.
        Button(
            many ? "Move \(targets.count) meetings to Trash…" : "Move to Trash…",
            role: .destructive
        ) {
            model.confirmTrash(targets)
        }
    }

    private var kindIcon: some View {
        // A rounded square rather than a circle, deliberately: a person is a
        // circle everywhere in this app, and a meeting is not a person.
        RoundedRectangle(cornerRadius: 7)
            .fill(kindTint.opacity(0.18))
            .frame(width: 26, height: 26)
            .overlay {
                Image(systemName: row.summary.source.symbolName)
                    .font(.system(size: 13))
                    .foregroundStyle(kindTint)
            }
    }

    private var kindTint: Color {
        switch row.summary.source {
        case .inPerson: .orange
        case .imported: .secondary
        default: .blue
        }
    }

    /// The date is spelled out under any heading that does not already name a
    /// day. Only Today and Yesterday do, so under "Earlier this month" and
    /// under a month heading a clock time alone left no way to tell which day a
    /// meeting was without opening it.
    private var subtitle: String {
        var parts = [
            Format.listDate(row.startedAt), Format.shortDuration(row.summary.durationSeconds),
        ]
        switch row.summary.source {
        case .inPerson: parts.append("In person")
        case .imported: parts.append("Imported")
        default: break
        }
        if row.summary.processingState != .complete {
            parts.append(row.summary.processingState.displayName)
        } else if model.filter == .unnamed, row.unnamedCount > 0 {
            parts.append("\(row.unnamedCount) unnamed")
        }
        return parts.joined(separator: " · ")
    }

    /// Faces when there is something to show, and the state otherwise. A
    /// meeting that failed or is still working has no speakers yet, and a dot
    /// says more there than three empty circles.
    @ViewBuilder private var trailing: some View {
        if row.needsAttention {
            Circle().fill(.red).frame(width: 7, height: 7)
        } else if row.isProcessing {
            Circle().fill(.orange).frame(width: 7, height: 7)
        } else {
            HStack(spacing: -5) {
                ForEach(row.speakers.prefix(3)) { speaker in
                    SpeakerFace(
                        name: speaker.displayName ?? "",
                        identityID: speaker.identityID,
                        side: 17
                    )
                    .overlay(Circle().stroke(.background, lineWidth: 1.5))
                }
            }
        }
    }
}

/// What a multiple selection can be told to do.
///
/// The same panel the People window shows, because the question is the same:
/// several rows are selected, so what applies to all of them.
struct MeetingsSelectionView: View {
    let model: MeetingsWindowModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(model.selection.count) meetings selected")
                        .font(.title3.weight(.semibold))
                    Text(names).font(.caption).foregroundStyle(.secondary)
                }

                if unnamedCount > 0 {
                    SectionCard(
                        title: "\(unnamedCount) \(unnamedCount == 1 ? "voice" : "voices") nobody has named",
                        subtitle: "Every one of them is in the People window as well, under Unnamed voices."
                    ) {
                        Text(
                            "Open a meeting to name a voice in it. A voice heard in more than one "
                                + "of these takes the name in all of them at once."
                        )
                        .font(.callout)
                    }
                }

                SectionCard(
                    title: "Act on all \(model.selection.count)",
                    subtitle: "Rebuilding reads the model output already on disk. Nothing is transcribed again."
                ) {
                    HStack(spacing: 8) {
                        Button("Reveal in Finder") { model.revealSelection() }
                        Button("Rebuild transcripts") { model.rebuildSelection() }
                        if model.selectedRows.allSatisfy(\.isArchived) {
                            Button("Put back") { model.setArchived(false, model.selectedRows) }
                        } else {
                            Button("Archive") { model.setArchived(true, model.selectedRows) }
                        }
                        Button("Move to Trash…", role: .destructive) {
                            model.confirmTrash(model.selectedRows)
                        }
                        Spacer()
                    }
                }

                SectionCard(
                    title: "\(Format.shortDuration(duration)) of audio",
                    subtitle: "Under the meetings folder, one folder per meeting."
                ) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.selectedRows.prefix(8)) { row in
                            Text(row.summary.directory.lastPathComponent)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var names: String {
        let titles = model.selectedRows.prefix(6).map(\.title).joined(separator: ", ")
        let extra = model.selection.count - min(6, model.selection.count)
        return extra > 0 ? "\(titles), and \(extra) more" : titles
    }

    private var unnamedCount: Int { model.selectedRows.reduce(0) { $0 + $1.unnamedCount } }
    private var duration: Double { PipitRuntime.totalDuration(of: model.selectedRows) }
}
