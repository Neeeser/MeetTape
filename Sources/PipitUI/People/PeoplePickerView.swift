import PipitCore
import SwiftUI

/// The popover that answers "who is this voice?".
///
/// One view for every surface that asks: the speaker chip, the turn header and
/// the right-click on a selection. Each of them drew its own flat alphabetical
/// menu of the whole directory, which at forty voices is a scroll rather than a
/// choice, and none of them could be searched.
///
/// Typing a name nobody has and pressing Return creates that person, so the
/// separate naming field these surfaces used to grow is gone.
public struct PeoplePickerView: View {
    let people: [SpeakerDirectoryEntry]
    var context: [IdentityID: PeoplePickerContext] = [:]
    let model: PeoplePickerModel
    /// Left out when the caller has nothing to clear, as a fresh selection has.
    var leaveUnnamedTitle: String?
    var onPick: (SpeakerDirectoryEntry) -> Void
    var onNewPerson: (String) -> Void
    var onLeaveUnnamed: () -> Void = {}

    @FocusState private var searchFocused: Bool

    public init(
        people: [SpeakerDirectoryEntry],
        context: [IdentityID: PeoplePickerContext] = [:],
        model: PeoplePickerModel,
        leaveUnnamedTitle: String? = nil,
        onPick: @escaping (SpeakerDirectoryEntry) -> Void,
        onNewPerson: @escaping (String) -> Void,
        onLeaveUnnamed: @escaping () -> Void = {}
    ) {
        self.people = people
        self.context = context
        self.model = model
        self.leaveUnnamedTitle = leaveUnnamedTitle
        self.onPick = onPick
        self.onNewPerson = onNewPerson
        self.onLeaveUnnamed = onLeaveUnnamed
    }

    private var sections: [PeoplePickerSection] {
        PeoplePickerRanking.sections(people, context: context, query: model.query)
    }

    private var visibleIDs: [IdentityID] { sections.flatMap(\.rows).map(\.id) }

    private var trimmedQuery: String {
        model.query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            search
            Divider()
            if sections.isEmpty {
                Text(people.isEmpty ? "Nobody yet." : "No match.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                list
            }
            Divider()
            footer
        }
        .frame(width: 300)
        .onAppear {
            searchFocused = true
            model.highlight = visibleIDs.first
        }
    }

    private var search: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Search people", text: model.text(\.query))
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit(commit)
                // On the field rather than the container: it holds focus for
                // the life of the popover, so an arrow key never reaches an
                // ancestor.
                .onKeyPress(.downArrow) { move(by: 1) }
                .onKeyPress(.upArrow) { move(by: -1) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        // The list is rebuilt under the cursor as the query narrows, so a
        // highlight left on a row that no longer shows would name nobody.
        .onChange(of: model.query) { _, _ in model.highlight = visibleIDs.first }
    }

    private var list: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sections) { section in
                        Text(section.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.top, 7)
                            .padding(.bottom, 2)
                        ForEach(section.rows) { row in personRow(row) }
                    }
                }
                .padding(.bottom, 4)
            }
            .frame(maxHeight: 300)
            .onChange(of: model.highlight) { _, highlighted in
                guard let highlighted else { return }
                scroller.scrollTo(highlighted, anchor: .bottom)
            }
        }
    }

    private func personRow(_ row: PeoplePickerRow) -> some View {
        let selected = model.highlight == row.id
        return HStack(spacing: 8) {
            SpeakerFace(
                name: row.entry.identity.isNamed ? row.entry.identity.resolvedName : "",
                identityID: row.id, side: 22
            )
            VStack(alignment: .leading, spacing: 0) {
                Text(row.entry.identity.resolvedName)
                    .font(.callout)
                    .lineLimit(1)
                if !row.detail.isEmpty {
                    Text(row.detail)
                        .font(.caption2)
                        .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.7))
                            : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if row.entry.identity.isLocalUser { youBadge }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 5).fill(Color.accentColor).padding(.horizontal, 4)
            }
        }
        .contentShape(Rectangle())
        .id(row.id)
        .onTapGesture { onPick(row.entry) }
        .onHover { inside in if inside { model.highlight = row.id } }
    }

    private var youBadge: some View {
        Text("You")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.accentColor.opacity(0.20)))
            .foregroundStyle(Color.accentColor)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The search field is also where a new person is typed, so with
            // nothing in it there is nothing to create. The row says what to do
            // rather than sitting there greyed out and unexplained.
            Button {
                onNewPerson(trimmedQuery)
            } label: {
                Label(
                    trimmedQuery.isEmpty
                        ? "Type a name to add someone" : "New person “\(trimmedQuery)”",
                    systemImage: "plus"
                )
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .disabled(trimmedQuery.isEmpty)
            if let leaveUnnamedTitle {
                Button {
                    onLeaveUnnamed()
                } label: {
                    Label(leaveUnnamedTitle, systemImage: "waveform")
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// Return names whoever is highlighted, and creates the typed name when
    /// nothing is. Searching for somebody who is not in the list yet and
    /// pressing Return is how they get created.
    private func commit() {
        if let highlight = model.highlight,
           let row = sections.flatMap(\.rows).first(where: { $0.id == highlight }) {
            onPick(row.entry)
            return
        }
        guard !trimmedQuery.isEmpty else { return }
        onNewPerson(trimmedQuery)
    }

    private func move(by offset: Int) -> KeyPress.Result {
        let ids = visibleIDs
        guard !ids.isEmpty else { return .ignored }
        guard let current = model.highlight, let index = ids.firstIndex(of: current) else {
            model.highlight = offset > 0 ? ids.first : ids.last
            return .handled
        }
        let next = index + offset
        guard ids.indices.contains(next) else { return .handled }
        model.highlight = ids[next]
        return .handled
    }
}

/// What the picker holds while it is open.
///
/// Owned by the model behind the window rather than by the view, so the
/// popover keeps what was typed across the redraws an assignment causes.
@MainActor
@Observable
public final class PeoplePickerModel {
    public var query = ""
    public var highlight: IdentityID?

    public init() {}

    public func reset() {
        query = ""
        highlight = nil
    }

    public func text(_ keyPath: ReferenceWritableKeyPath<PeoplePickerModel, String>) -> Binding<String> {
        Binding(get: { self[keyPath: keyPath] }, set: { self[keyPath: keyPath] = $0 })
    }
}
