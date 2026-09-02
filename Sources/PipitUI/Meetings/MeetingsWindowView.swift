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
        .folderPrompts(model: model)
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
        // Once per pass, for the same reason `sections` is: the menu and the
        // offer both want it, and it walks every row the filter holds.
        let counts = model.sourceCounts
        return VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    searchField
                    modeSwitch
                }
                Picker("", selection: Binding(
                    get: { model.filter }, set: { model.filter = $0 }
                )) {
                    ForEach(MeetingsFilter.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // Meaningless over a list of folders, where no row has a
                // source of its own.
                if !model.showsFolderList { sourceMenu(counts) }
            }
            .padding(10)
            Divider()
            // From the counts already in hand. `model.suggestedSource` walks
            // the rows again for them, and this runs on every keystroke.
            if let suggested = MeetingsDirectoryFilter.offeredSource(
                for: model.query, held: model.sourceFilter, counts: counts,
                listingFolders: model.showsFolderList
            ) {
                sourceOffer(suggested, counts)
            }
            if let open = model.openFolderRow {
                breadcrumb(open)
                Divider()
            }
            if model.showsFolderList {
                folderList
            } else {
                list(sections)
            }
            Divider()
            footer(visible: visible)
        }
    }

    /// Which of the two lists is showing. Two icons rather than a second
    /// segmented row: the four filters below already own that row, and they
    /// apply to both views.
    private var modeSwitch: some View {
        Picker("", selection: Binding(
            get: { model.mode }, set: { model.show($0) }
        )) {
            ForEach(MeetingsListMode.allCases) { mode in
                Image(systemName: mode.symbol).tag(mode)
                    .help(mode.label)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private func breadcrumb(_ folder: FolderRow) -> some View {
        HStack(spacing: 6) {
            Button {
                model.closeFolder()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                    Text("Folders")
                }
            }
            .buttonStyle(.link)
            Text("/").foregroundStyle(.tertiary)
            Image(systemName: "folder.fill")
                .font(.system(size: 10))
                .foregroundStyle(FolderTint.color(folder.folder.tintIndex))
            Text(folder.name).fontWeight(.semibold).lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var folderList: some View {
        let folders = model.visibleFolders
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if folders.isEmpty {
                    emptyFolderList
                } else {
                    Text("Folders · \(folders.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.top, 10)
                        .padding(.bottom, 4)
                    ForEach(folders) { folder in
                        FolderRowView(model: model, row: folder)
                    }
                }
            }
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder private var emptyFolderList: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.query.isEmpty {
                Text("No folders yet")
                Text(
                    "A folder is an ordinary directory under Meetings/Folders. Right-click a "
                        + "meeting on the timeline to file it into a new one."
                )
                .foregroundStyle(.secondary)
            } else {
                Text("No match")
                Text("Folder names and what they are for.").foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(12)
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if let held = model.sourceFilter { sourceToken(held) }
            TextField(
                model.sourceFilter.map { "Search \($0.listName)" }
                    ?? "Search titles, people, words",
                text: model.text(\.query)
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .onSubmit { model.takeSuggestedSource() }
            // Backspace on an empty field drops the token, the way it does in
            // every other field that holds one.
            // The general form rather than `onKeyPress(.delete)`, which was
            // measured not to fire for the Delete key at all while this one
            // receives it as "\u{7F}".
            .onKeyPress { press in
                guard SearchFieldKey.dropsHeldSource(
                    characters: press.characters, query: model.query,
                    hasSource: model.sourceFilter != nil
                ) else { return .ignored }
                model.sourceFilter = nil
                return .handled
            }
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

    /// The source being held, kept in the search field rather than beside it.
    /// One home for the state: words typed after it search inside it, and this
    /// is where they are typed.
    private func sourceToken(_ source: MeetingSource) -> some View {
        let tint = SourceTint.color(source)
        return Button {
            model.sourceFilter = nil
        } label: {
            HStack(spacing: 3) {
                Image(systemName: source.symbolName).font(.system(size: 8))
                Text(source.listName)
                Image(systemName: "xmark").font(.system(size: 7, weight: .bold)).opacity(0.6)
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.18)))
            .fixedSize()
        }
        .buttonStyle(.plain)
        .help("Showing \(source.displayName) only. Click to drop it.")
    }

    /// Every source the archive holds, with a count each.
    ///
    /// The counts are what this is for. A field answers a question you already
    /// have, and the menu answers the one nobody can type: what is in here.
    /// The label stays "Source" while one is held, because the token in the
    /// field is already saying which.
    private func sourceMenu(_ counts: [MeetingSource: Int]) -> some View {
        // The source in force is always listed, whatever the count says. It
        // drops out of the counts under a filter that holds none of it, and a
        // menu with nothing ticked left no way to see what was narrowing the
        // list.
        let present = MeetingSource.allCases.filter {
            (counts[$0] ?? 0) > 0 || model.sourceFilter == $0
        }
        return HStack(spacing: 5) {
            Menu {
                Button("All sources") { model.sourceFilter = nil }
                if !present.isEmpty { Divider() }
                ForEach(present, id: \.self) { source in
                    Button {
                        model.sourceFilter = source
                    } label: {
                        Label(
                            "\(source.listName)  ·  \(counts[source] ?? 0)",
                            systemImage: model.sourceFilter == source
                                ? "checkmark" : source.symbolName
                        )
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Source")
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .frame(height: 19)
                .overlay(Capsule().stroke(.quaternary))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Spacer(minLength: 0)
        }
    }

    /// The source the typed words name, offered above the list.
    ///
    /// In the flow rather than a popover. A popover over a 272 point sidebar
    /// covers the rows the same words have already found.
    private func sourceOffer(_ source: MeetingSource, _ counts: [MeetingSource: Int]) -> some View {
        Button {
            model.takeSuggestedSource()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: source.symbolName)
                    .font(.system(size: 11))
                    .foregroundStyle(SourceTint.color(source))
                    .frame(width: 15)
                Text(source.listName)
                Spacer(minLength: 4)
                Text("\(counts[source] ?? 0)").foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.14)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .help("Show only \(source.displayName). Return takes it.")
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
            } else if let source = model.sourceFilter {
                Text("No \(source.listName) meetings")
                Text("Not under this filter. Drop the source in the search field to see the rest.")
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
            if model.showsFolderList {
                Button {
                    model.pendingNewFolder = NewFolderRequest(filing: [])
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus").font(.caption)
                }
                .buttonStyle(.link)
            } else {
                Button {
                    model.revealArchive()
                } label: {
                    Label("Open folder", systemImage: "folder")
                        .font(.caption)
                }
                .buttonStyle(.link)
                .help("Every meeting is an ordinary folder. Opening it changes nothing.")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func footerText(visible: Int) -> String {
        if model.showsFolderList {
            let folders = model.visibleFolders
            let filed = folders.reduce(0) { $0 + $1.meetingCount }
            let unfiled = model.rows.count { !$0.isArchived && $0.summary.folderName == nil }
            return "\(folders.count) \(folders.count == 1 ? "folder" : "folders") · "
                + "\(filed) filed · \(unfiled) unfiled"
        }
        if let open = model.openFolderRow {
            return "\(open.name) · \(open.meetingCount) "
                + "\(open.meetingCount == 1 ? "meeting" : "meetings") · "
                + Format.shortDuration(open.totalDuration)
        }
        return meetingFooterText(visible: visible)
    }

    private func meetingFooterText(visible: Int) -> String {
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
        } else if model.selection.isEmpty, let folder = model.openFolderRow {
            FolderDetailView(model: model, row: folder)
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

/// When a key press in the search field drops the source held there.
///
/// Backspace, and only with nothing typed after the token: with words in the
/// field, backspace edits the words. Matched on the characters the press
/// carries rather than through `onKeyPress(.delete)`, which was measured never
/// to fire for the Delete key here.
public enum SearchFieldKey {
    /// What the Delete key sends. `NSDeleteCharacter`, which is the key labelled
    /// delete on a Mac keyboard rather than forward delete.
    private static let backspace = "\u{7F}"

    public static func dropsHeldSource(
        characters: String, query: String, hasSource: Bool
    ) -> Bool {
        characters == backspace && query.isEmpty && hasSource
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
                HStack(spacing: 5) {
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    if let folder = model.folderTag(for: row) {
                        Spacer(minLength: 3)
                        FolderTagView(row: folder)
                    }
                }
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
        Menu(many ? "Move \(targets.count) to Folder" : "Move to Folder") {
            ForEach(model.folderRows) { folder in
                Button {
                    model.file(targets, in: folder.name)
                } label: {
                    // A tick on the folder every one of them is already in, so
                    // the menu says where the selection stands as well as where
                    // it could go.
                    if targets.allSatisfy({ $0.summary.folderName == folder.name }) {
                        Label(folder.name, systemImage: "checkmark")
                    } else {
                        Text(folder.name)
                    }
                }
            }
            if !model.folderRows.isEmpty { Divider() }
            Button("New Folder…") {
                model.pendingNewFolder = NewFolderRequest(filing: targets.map(\.id))
            }
            if targets.contains(where: { $0.summary.folderName != nil }) {
                Button("Remove from Folder") { model.file(targets, in: nil) }
            }
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

    /// The badge every row draws: the application's own mark where this Mac has
    /// the application, and Pipit's glyph otherwise.
    ///
    /// The tinted square is the same either way, so a column of rows reads as
    /// one thing. It is a rounded square deliberately: a person is a circle
    /// everywhere in this app, and a meeting is not a person. A real mark comes
    /// in with its plate keyed off and a little of its saturation taken, so it
    /// sits on the tint rather than fighting it.
    @MainActor private var kindIcon: some View {
        let source = row.summary.source
        let tint = SourceTint.color(source)
        return RoundedRectangle(cornerRadius: 7)
            .fill(tint.opacity(0.18))
            .frame(width: 26, height: 26)
            .overlay {
                if let mark = SourceMark.icon(for: source) {
                    Image(nsImage: mark)
                        .resizable()
                        .interpolation(.high)
                        .saturation(0.85)
                        .frame(width: 19, height: 19)
                } else {
                    Image(systemName: source.symbolName)
                        .font(.system(size: 13))
                        .foregroundStyle(tint)
                }
            }
    }

    /// The source leads, because it is the fixed part of the line. A column of
    /// clock times with the source somewhere after it is harder to run an eye
    /// down, and the badge beside it is the colour of the same word.
    ///
    /// The date is spelled out under any heading that does not already name a
    /// day. Only Today and Yesterday do, so under "Earlier this month" and
    /// under a month heading a clock time alone left no way to tell which day a
    /// meeting was without opening it.
    private var subtitle: String {
        var parts = [
            row.summary.source.listName,
            Format.listDate(row.startedAt),
            Format.shortDuration(row.summary.durationSeconds),
        ]
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
                        Menu("Move to Folder") {
                            ForEach(model.folderRows) { folder in
                                Button(folder.name) {
                                    model.file(model.selectedRows, in: folder.name)
                                }
                            }
                            if !model.folderRows.isEmpty { Divider() }
                            Button("New Folder…") {
                                model.pendingNewFolder = NewFolderRequest(
                                    filing: model.selectedRows.map(\.id)
                                )
                            }
                            Button("Remove from Folder") { model.file(model.selectedRows, in: nil) }
                        }
                        .fixedSize()
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
