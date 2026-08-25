import PipitCore
import SwiftUI

/// The people window: everyone Pipit can recognise on the left, one of them
/// on the right.
///
/// Replaces a flat list in a settings tab, which held every person and every
/// unnamed voice in one scroll with no search, no grouping and nothing that
/// could act on more than one row.
public struct PeopleDirectoryView: View {
    let model: PeopleDirectoryModel

    public init(model: PeopleDirectoryModel) {
        self.model = model
    }

    public var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 240, idealWidth: 264, maxWidth: 360)
            detail.frame(minWidth: 380)
        }
        .frame(minWidth: 820, minHeight: 520)
        .task { await model.reload() }
        .alert(
            model.pendingAction?.title ?? "",
            isPresented: Binding(
                get: { model.pendingAction != nil },
                set: { if !$0 { model.pendingAction = nil } }
            )
        ) {
            // Captured here, while the alert still has one. The button's action
            // runs after the dismissal has cleared `pendingAction`, so reading
            // it back there finds nothing and the confirmation does nothing.
            let action = model.pendingAction
            Button("Cancel", role: .cancel) { model.pendingAction = nil }
            Button(action?.confirmLabel ?? "Delete", role: .destructive) {
                guard let action else { return }
                Task { await model.perform(action) }
            }
        } message: {
            Text(model.pendingAction?.message ?? "")
        }
        .sheet(
            isPresented: Binding(
                get: { model.organizationPrompt != nil },
                set: { if !$0 { model.organizationPrompt = nil } }
            )
        ) {
            organizationSheet
        }
    }

    // MARK: - sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                TextField("Search name, organization, notes", text: model.text(\.query))
                    .textFieldStyle(.roundedBorder)
                Picker("", selection: Binding(
                    get: { model.filter }, set: { model.filter = $0 }
                )) {
                    ForEach(PeopleFilter.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(10)
            Divider()
            list
            Divider()
            footer
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if model.visibleCount == 0 {
                    Text(model.entries.isEmpty
                        ? "Nobody yet. Naming a speaker on a meeting creates them here."
                        : "No match.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(12)
                }
                ForEach(model.sections) { section in
                    Text("\(section.title) · \(section.entries.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.top, 10)
                        .padding(.bottom, 4)
                    ForEach(section.entries) { entry in row(entry) }
                }
            }
            .padding(.bottom, 8)
        }
    }

    private func row(_ entry: SpeakerDirectoryEntry) -> some View {
        let selected = model.selection.contains(entry.id)
        return HStack(spacing: 8) {
            PersonAvatar(identity: entry.identity, image: model.avatarImage(for: entry))
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.identity.resolvedName)
                    .font(.callout)
                    .lineLimit(1)
                Text(rowSubtitle(entry))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            profileDot(entry.profile)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .background(selected ? Color.accentColor.opacity(0.18) : .clear)
        .onTapGesture {
            model.select(entry.id, extending: NSEvent.modifierFlags.contains(.command))
        }
    }

    private func rowSubtitle(_ entry: SpeakerDirectoryEntry) -> String {
        entry.meetingCount == 1 ? "1 meeting" : "\(entry.meetingCount) meetings"
    }

    /// How much verified voice material stands behind this person, at a glance.
    @ViewBuilder private func profileDot(_ status: VoiceProfileStatus) -> some View {
        switch status {
        case .none:
            Circle().strokeBorder(.tertiary, lineWidth: 1).frame(width: 7, height: 7)
        case .learning:
            Circle().fill(.orange).frame(width: 7, height: 7)
        case .ready:
            Circle().fill(.green).frame(width: 7, height: 7)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("\(model.visibleCount) of \(model.entries.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                Button("Set organization…") { model.beginSetOrganization() }
                    .disabled(model.selection.isEmpty)
                Button("Merge into one person") { Task { await model.mergeSelection() } }
                    .disabled(!model.canMerge)
                Divider()
                Button("Delete \(model.purgeCandidates.count) unnamed voices heard once…") {
                    model.confirmPurge()
                }
                .disabled(model.purgeCandidates.isEmpty)
                Button("Delete selected", role: .destructive) { model.confirmDeleteSelection() }
                    .disabled(model.selection.isEmpty)
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    // MARK: - detail

    @ViewBuilder private var detail: some View {
        if model.selection.count > 1 {
            PeopleSelectionSummary(model: model)
        } else if let entry = model.focused {
            PersonDetailView(model: model, entry: entry)
        } else {
            VStack(spacing: 6) {
                Text("Select someone").font(.title3)
                Text("Their voice profile, notes and meeting history appear here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var organizationSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.organizationPrompt.map {
                $0.targets.count == 1
                    ? "Organization" : "Organization for \($0.targets.count) people"
            } ?? "Organization")
            .font(.headline)
            TextField("Organization", text: Binding(
                get: { model.organizationPrompt?.draft ?? "" },
                set: { model.organizationPrompt?.draft = $0 }
            ))
            .frame(width: 280)
            HStack {
                Spacer()
                Button("Cancel") { model.organizationPrompt = nil }
                Button("Save") {
                    guard let prompt = model.organizationPrompt else { return }
                    Task { await model.commitOrganization(prompt) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
    }
}

/// What a multiple selection can be told to do.
struct PeopleSelectionSummary: View {
    let model: PeopleDirectoryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(model.selection.count) selected").font(.title3)
            Text(model.selectedEntries.prefix(8).map(\.identity.resolvedName)
                .joined(separator: ", ")
                + (model.selection.count > 8 ? ", and \(model.selection.count - 8) more" : ""))
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Set organization…") { model.beginSetOrganization() }
                Button("Merge into one person") { Task { await model.mergeSelection() } }
                    .disabled(!model.canMerge)
                Button("Delete", role: .destructive) { model.confirmDeleteSelection() }
            }
            if model.selection.count != 2 {
                Text("Merging joins exactly two voices, so select two.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
