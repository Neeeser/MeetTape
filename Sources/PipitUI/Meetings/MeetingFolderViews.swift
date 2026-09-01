import PipitCore
import PipitServices
import SwiftUI

/// The colours a folder can be, indexed rather than stored.
///
/// An index on disk and a palette here, so changing the palette re-tints every
/// folder instead of leaving the old colours written into `folder.json`.
enum FolderTint {
    static let all: [Color] = [.blue, .green, .purple, .orange, .pink, .teal]

    static func color(_ index: Int) -> Color {
        all[((index % all.count) + all.count) % all.count]
    }
}

/// One folder in the sidebar: what it is called, what it holds, and who is
/// usually in it.
///
/// Shaped like the meeting row beside it, with a chevron where the faces would
/// run out, because clicking it goes somewhere rather than selecting something.
struct FolderRowView: View {
    let model: MeetingsWindowModel
    let row: FolderRow

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 7)
                .fill(tint.opacity(0.18))
                .frame(width: 26, height: 26)
                .overlay {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(tint)
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).font(.callout).lineLimit(1)
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            HStack(spacing: -5) {
                ForEach(row.regulars) { speaker in
                    SpeakerFace(
                        name: speaker.displayName ?? "",
                        identityID: speaker.identityID,
                        side: 17
                    )
                    .overlay(Circle().stroke(.background, lineWidth: 1.5))
                }
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture { model.open(folder: row.name) }
        .contextMenu {
            Button("Open") { model.open(folder: row.name) }
            Button("Reveal in Finder") { model.runtime.revealFolder(row.name) }
            Divider()
            Button(
                row.folder.filesAutomatically
                    ? "Stop filing matching meetings here"
                    : "File matching meetings here"
            ) {
                model.setFilesAutomatically(!row.folder.filesAutomatically, on: row.name)
            }
            .disabled(row.folder.rule.isEmpty)
            Button("Rename…") { model.pendingFolderRename = row.name }
            Button("Delete Folder…", role: .destructive) { model.deleteFolder(row.name) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.name), \(subtitle)")
    }

    private var tint: Color { FolderTint.color(row.folder.tintIndex) }

    private var subtitle: String {
        var parts = ["\(row.meetingCount) \(row.meetingCount == 1 ? "meeting" : "meetings")"]
        if let newest = row.newestAt {
            parts.append("last \(Format.listDate(newest))")
        }
        if row.folder.filesAutomatically, !row.folder.rule.isEmpty {
            parts.append("files on its own")
        }
        return parts.joined(separator: " · ")
    }
}

/// The tag a filed meeting carries on the timeline.
///
/// Named rather than a bare dot: a colour alone says a meeting is organised,
/// and the question a person actually has is which folder it is in. It gives up
/// its width before the time does, so a narrow window truncates the folder name
/// rather than the thing every row needs.
struct FolderTagView: View {
    let row: FolderRow

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "folder.fill").font(.system(size: 8))
            Text(row.name).lineLimit(1).truncationMode(.tail)
        }
        .font(.system(size: 10))
        .foregroundStyle(FolderTint.color(row.folder.tintIndex))
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(FolderTint.color(row.folder.tintIndex).opacity(0.18))
        )
        .frame(maxWidth: 116, alignment: .trailing)
        .help("In the folder \(row.name)")
    }
}

/// The pane for a folder: what it holds, what it files without asking, and what
/// has been suggested for it.
struct FolderDetailView: View {
    let model: MeetingsWindowModel
    let row: FolderRow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                ruleCard
                if !suggested.isEmpty { suggestedCard }
                contentsCard
                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(tint.opacity(0.18))
                    .frame(width: 30, height: 30)
                    .overlay {
                        Image(systemName: "folder.fill").font(.system(size: 14)).foregroundStyle(tint)
                    }
                Text(row.name).font(.title3.weight(.semibold))
                Spacer(minLength: 0)
            }
            TextField(
                "What this folder is for",
                text: Binding(
                    get: { row.folder.about },
                    set: { model.setAbout($0, on: row.name) }
                )
            )
            .textFieldStyle(.plain)
            .font(.callout)
            .foregroundStyle(.secondary)
            .help(
                "Read when a meeting is being placed, so two clients are told apart by what "
                    + "they are about rather than by who is in them."
            )
            HStack(spacing: 8) {
                Text(
                    "\(row.meetingCount) \(row.meetingCount == 1 ? "meeting" : "meetings") · "
                        + Format.shortDuration(row.totalDuration)
                )
                Text("·")
                Image(systemName: "folder").font(.caption2)
                Text("Meetings/Folders/\(row.name)").lineLimit(1).truncationMode(.head)
                Button("Reveal in Finder") { model.runtime.revealFolder(row.name) }
                    .buttonStyle(.link)
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
    }

    private var ruleCard: some View {
        SectionCard(
            title: "Move a matching meeting in without asking",
            subtitle: row.folder.rule.isEmpty
                ? "Nothing is filed here on its own. File a meeting by hand and Pipit offers to "
                    + "make a rule out of the ones that look like it."
                : autoSubtitle
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if !row.folder.rule.isEmpty {
                    Toggle(
                        "Files matching meetings here",
                        isOn: Binding(
                            get: { row.folder.filesAutomatically },
                            set: { model.setFilesAutomatically($0, on: row.name) }
                        )
                    )
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .trailing)

                    FlowChips(items: FolderRuleSummary.clauses(row.folder.rule))
                    Text(
                        "Matches \(model.runtime.meetingsMatching(row.folder.rule)) of the "
                            + "\(model.rows.count) meetings on disk."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var autoSubtitle: String {
        row.folder.filesAutomatically
            ? "A meeting matching every line below is filed when processing finishes, and its row "
                + "says so with an Undo."
            : "Matches are offered in the meeting pane instead. Nothing moves on its own while "
                + "this is off."
    }

    private var suggestedCard: some View {
        SectionCard(
            title: suggested.count == 1
                ? "One meeting looks like it belongs here"
                : "\(suggested.count) meetings look like they belong here",
            subtitle: "Read from the transcript and the title after processing. Nothing moves "
                + "until you say so."
        ) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(suggested, id: \.row.id) { entry in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.row.title).font(.callout).lineLimit(1)
                            Text("\(Format.listDate(entry.row.startedAt)) · \(entry.suggestion.why)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Button("Move it") { model.acceptFolderSuggestion(for: entry.row.id) }
                        Button("Dismiss") { model.dismissFolderSuggestion(for: entry.row.id) }
                            .buttonStyle(.link)
                    }
                }
            }
        }
    }

    private var contentsCard: some View {
        SectionCard(
            title: "\(row.meetingCount) \(row.meetingCount == 1 ? "meeting" : "meetings") inside",
            subtitle: "The list on the left is showing these. Click one to read it."
        ) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(members.prefix(10)) { meeting in
                    HStack(spacing: 8) {
                        Text(meeting.title).font(.caption).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(Format.listDate(meeting.startedAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { model.select(meeting.id, extending: false) }
                }
                if members.count > 10 {
                    Text("and \(members.count - 10) more")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var tint: Color { FolderTint.color(row.folder.tintIndex) }

    private var members: [MeetingRow] {
        model.rows.filter { $0.summary.folderName == row.name }
    }

    /// Meetings elsewhere in the archive that were offered this folder and have
    /// not answered yet.
    private var suggested: [(row: MeetingRow, suggestion: FolderSuggestion)] {
        model.rows.compactMap { meeting in
            guard let suggestion = meeting.folderSuggestion,
                  suggestion.folderName == row.name
            else { return nil }
            return (meeting, suggestion)
        }
    }
}

/// A row of chips that wraps, for the clauses of a rule.
struct FlowChips: View {
    let items: [String]

    var body: some View {
        // A grid rather than a hand-rolled flow layout: at three or four short
        // clauses the difference is invisible, and this cannot get the height
        // wrong.
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 120), spacing: 6, alignment: .leading)],
            alignment: .leading,
            spacing: 6
        ) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    .lineLimit(1)
            }
        }
    }
}

/// The prompts filing needs: a name for a new folder, a name for a renamed one,
/// what went wrong, and the offer to turn a hand-filed meeting into a rule.
///
/// A modifier rather than four modifiers on the window body, which the type
/// checker would not finish.
struct FolderPrompts: ViewModifier {
    let model: MeetingsWindowModel

    func body(content: Content) -> some View {
        content
            .alert("New Folder", isPresented: newFolderShowing) {
                TextField("Name", text: Binding(
                    get: { model.pendingNewFolder?.name ?? "" },
                    set: { model.pendingNewFolder?.name = $0 }
                ))
                Button("Cancel", role: .cancel) { model.pendingNewFolder = nil }
                Button("Create") { model.commitNewFolder() }
            } message: {
                Text(
                    "A directory under Meetings/Folders. The meetings you file into it move there."
                )
            }
            .alert("Rename Folder", isPresented: renameShowing) {
                RenameFolderFields(model: model)
            } message: {
                Text("The directory is renamed and every meeting inside it moves with it.")
            }
            .alert("Something went wrong", isPresented: problemShowing) {
                Button("OK", role: .cancel) { model.folderProblem = nil }
            } message: {
                Text(model.folderProblem ?? "")
            }
            .sheet(item: Binding(
                get: { model.recurringOffer },
                set: { model.recurringOffer = $0 }
            )) { offer in
                RecurringOfferSheet(model: model, offer: offer)
            }
    }

    private var newFolderShowing: Binding<Bool> {
        Binding(
            get: { model.pendingNewFolder != nil },
            set: { if !$0 { model.pendingNewFolder = nil } }
        )
    }

    private var renameShowing: Binding<Bool> {
        Binding(
            get: { model.pendingFolderRename != nil },
            set: { if !$0 { model.pendingFolderRename = nil } }
        )
    }

    private var problemShowing: Binding<Bool> {
        Binding(
            get: { model.folderProblem != nil },
            set: { if !$0 { model.folderProblem = nil } }
        )
    }
}

/// The rename alert's own fields, which need the name the folder started with
/// after the field has been typed into.
private struct RenameFolderFields: View {
    let model: MeetingsWindowModel
    @State private var typed = ""
    @State private var original = ""

    var body: some View {
        TextField("Name", text: $typed)
            .onAppear {
                original = model.pendingFolderRename ?? ""
                typed = original
            }
        Button("Cancel", role: .cancel) { model.pendingFolderRename = nil }
        Button("Rename") {
            model.pendingFolderRename = nil
            model.renameFolder(original, to: typed)
        }
    }
}

extension View {
    func folderPrompts(model: MeetingsWindowModel) -> some View {
        modifier(FolderPrompts(model: model))
    }
}

/// The offer made right after a meeting is filed by hand: this looks like a
/// series, so file the next one too.
///
/// Every clause is separate and the count under them answers the ticks as they
/// stand, because a rule that quietly means more than the user thought is the
/// thing that makes automatic filing untrustworthy.
struct RecurringOfferSheet: View {
    let model: MeetingsWindowModel
    let offer: RecurringOffer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(headline).font(.headline)
                Text(blurb).font(.callout).foregroundStyle(.secondary)
            }
            .padding(.bottom, 14)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(offer.proposal.clauses) { clause in
                    Toggle(isOn: Binding(
                        get: { offer.ticked.contains(clause.kind) },
                        set: { _ in model.toggleOfferClause(clause.kind) }
                    )) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(clause.label).font(.callout)
                            Text(clause.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }

            Text(matchLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 12)

            HStack(spacing: 8) {
                Spacer()
                Button("Not now") { model.recurringOffer = nil }
                Button("File future meetings here") { model.saveOfferedRule() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(offer.ticked.isEmpty)
            }
            .padding(.top, 18)
        }
        .padding(20)
        .frame(width: 460)
    }

    private var headline: String {
        "\(offer.facts.title) happens more than once"
    }

    private var blurb: String {
        let count = offer.proposal.lookalikeCount
        return "\(count) \(count == 1 ? "meeting" : "meetings") on disk look like this one. "
            + "Pipit can move the next one into \(offer.folderName) without asking."
    }

    private var matchLine: String {
        guard !offer.ticked.isEmpty else {
            return "With nothing ticked, every new meeting would land here. Pick at least one line."
        }
        let count = model.offerMatchCount()
        return "Matches \(count) of the \(model.rows.count) meetings on disk."
    }
}
