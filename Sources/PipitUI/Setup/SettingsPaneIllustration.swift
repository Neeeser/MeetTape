import AppKit
import PipitCore
import SwiftUI
import UniformTypeIdentifiers

/// A picture of the System Settings row the user is being asked to switch on,
/// which is also the thing they can drag into that list.
///
/// Drawn rather than bundled as a screenshot. A screenshot carries a fixed
/// application icon and name, a fixed appearance, and the layout of whichever
/// macOS release it was taken on: Jump Desktop Connect still ships a Mojave-era
/// `accessibility@2x.png` that its own wizard stopped using. Drawing it means the
/// row shows Pipit's real icon, follows light and dark, and cannot go stale.
///
/// It shows the state being asked for, not the state that exists. Someone who
/// has just removed Pipit from the real list sees a picture that still has it,
/// so the caption above says what to do rather than leaving the picture to be
/// read as a live view of the pane.
struct SettingsPaneIllustration: View {
    let kind: PermissionKind

    private var isDraggable: Bool { kind.acceptsDroppedApplication }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(instruction)
                .font(.callout.weight(.medium))
            pane
        }
    }

    private var instruction: String {
        // Dropping Pipit into the list switches it on in the same move, so
        // the instruction stops at the drop.
        isDraggable
            ? "Drag \(ApplicationIdentity.name) into the list"
            : "Switch \(ApplicationIdentity.name) on"
    }

    private var pane: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text(kind.paneCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                applicationRow
            }
            .padding(12)
        }
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(instruction). Illustration of the \(kind.paneTitle) pane in System Settings."
        )
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.left").foregroundStyle(.secondary)
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            Text(kind.paneTitle).font(.callout.weight(.semibold))
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var applicationRow: some View {
        let row = HStack(spacing: 8) {
            ApplicationIcon(size: 20)
            Text(ApplicationIdentity.settingsListName).font(.callout)
            Spacer()
            switchGraphic
                // The one piece of the picture that is not a faithful copy. It is
                // what the user has to find, and a faithful copy of a toggle in a
                // list of toggles is not findable.
                .overlay(
                    Capsule().strokeBorder(.red, lineWidth: 2).padding(-3)
                )
        }
        .contentShape(Rectangle())

        if isDraggable {
            // The row looks like the thing that belongs in the list, so it is the
            // thing people try to drag. Offering only the small chip below meant
            // the obvious gesture did nothing.
            row.applicationDrag()
        } else {
            row
        }
    }

    /// The switch, drawn rather than built from `Toggle`.
    ///
    /// A real `Toggle` has to be disabled here, since it is a picture and not a
    /// control, and a disabled switch draws grey in both states. That put a grey
    /// switch inside the red ring on a screen whose whole job is to say "make this
    /// one blue".
    private var switchGraphic: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(width: 30, height: 18)
            .overlay(alignment: .trailing) {
                Circle()
                    .fill(.white)
                    .padding(2)
                    .shadow(radius: 0.5)
            }
    }
}

/// Pipit's own icon, at whatever size the caller draws it.
struct ApplicationIcon: View {
    var size: CGFloat

    var body: some View {
        Group {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon).resizable()
            } else {
                // The test runner and any non-bundled build have no icon.
                RoundedRectangle(cornerRadius: size * 0.22).fill(.tint)
            }
        }
        .frame(width: size, height: size)
    }
}

public enum ApplicationIdentity {
    /// What Pipit is called in prose.
    static var name: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Pipit"
    }

    /// What System Settings writes in its list, which is the bundle's file name
    /// and keeps the `.app` extension. `CFBundleName` drops it, so a picture
    /// built from that reads "Pipit" against a real row saying "Pipit.app".
    static var settingsListName: String {
        let file = Bundle.main.bundleURL.lastPathComponent
        return file.isEmpty ? "\(name).app" : file
    }

    /// The dragged item: Pipit's application bundle, as a file URL.
    ///
    /// Registered from `NSURL`, which advertises `public.url` and
    /// `public.file-url`. `NSItemProvider(contentsOf:)` was tried first and
    /// produced a drag that picked up, dropped, and did nothing: it wants a
    /// readable file, and an application is a directory.
    public static func dragItemProvider(for url: URL = Bundle.main.bundleURL) -> NSItemProvider {
        let provider = NSItemProvider(object: url as NSURL)
        provider.suggestedName = url.lastPathComponent
        return provider
    }
}

extension View {
    /// Makes this view drag Pipit's application bundle.
    ///
    func applicationDrag() -> some View {
        onDrag {
            ApplicationIdentity.dragItemProvider()
        } preview: {
            // Without an explicit preview the whole row is dragged, which covers
            // the list being dropped onto.
            ApplicationIcon(size: 64)
        }
    }
}

/// Pipit's icon, draggable into a System Settings list.
///
/// The Accessibility and Screen Recording panes accept an application dropped
/// onto their list, which saves opening a file picker and finding it. The panes
/// granted by a system prompt have no list, so this is never offered there.
struct AppDragChip: View {
    var body: some View {
        HStack(spacing: 8) {
            ApplicationIcon(size: 26)
            Text("drag \(ApplicationIdentity.name) from here or from the picture above")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .applicationDrag()
        .help("Drag this into the list in System Settings to add \(ApplicationIdentity.name).")
        .accessibilityLabel("Drag \(ApplicationIdentity.name) into the System Settings list")
    }
}
