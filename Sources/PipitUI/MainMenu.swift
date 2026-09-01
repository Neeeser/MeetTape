import AppKit

/// The menu bar menu Pipit shows while it has a Dock icon.
///
/// Pipit is driven from its status item and needs no menu bar of its own, but a
/// regular application that never set one shows nothing beside the Apple menu:
/// measured here, the accessibility API reports no menu bar at all for such a
/// process. The standard editing commands are dispatched through this menu too,
/// so without it Cmd-C and Cmd-V do nothing in the API key and speaker name
/// fields.
///
/// Installed whichever policy is in force. An accessory application does not
/// display a menu bar, and the key equivalents keep working either way.
@MainActor
enum MainMenu {
    /// Builds the menu and hands it to `NSApp`.
    ///
    /// `target` owns the two items that open Pipit's own windows.
    static func install(target: AnyObject, showAbout: Selector, showSettings: Selector) {
        let bar = NSMenu()
        bar.addItem(
            submenu(
                NSMenu(title: "Pipit"),
                [
                    item("About Pipit", showAbout, target: target),
                    .separator(),
                    item("Settings…", showSettings, ",", target: target),
                    .separator(),
                    item("Hide Pipit", #selector(NSApplication.hide(_:)), "h"),
                    hideOthers(),
                    .separator(),
                    item("Quit Pipit", #selector(NSApplication.terminate(_:)), "q"),
                ]
            )
        )
        bar.addItem(
            submenu(
                NSMenu(title: "Edit"),
                [
                    item("Undo", Selector(("undo:")), "z"),
                    redo(),
                    .separator(),
                    item("Cut", #selector(NSText.cut(_:)), "x"),
                    item("Copy", #selector(NSText.copy(_:)), "c"),
                    item("Paste", #selector(NSText.paste(_:)), "v"),
                    item("Select All", #selector(NSText.selectAll(_:)), "a"),
                ]
            )
        )
        let windows = NSMenu(title: "Window")
        bar.addItem(
            submenu(
                windows,
                [
                    item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
                    item("Zoom", #selector(NSWindow.performZoom(_:))),
                    .separator(),
                    item("Close", #selector(NSWindow.performClose(_:)), "w"),
                ]
            )
        )
        NSApp.mainMenu = bar
        // macOS keeps the list of open windows at the bottom of this one.
        NSApp.windowsMenu = windows
    }

    private static func submenu(_ menu: NSMenu, _ items: [NSMenuItem]) -> NSMenuItem {
        items.forEach(menu.addItem)
        let holder = NSMenuItem()
        holder.submenu = menu
        return holder
    }

    /// An item sent to `target`, or down the responder chain when there is none.
    private static func item(
        _ title: String, _ action: Selector, _ key: String = "", target: AnyObject? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        return item
    }

    private static func redo() -> NSMenuItem {
        let item = item("Redo", Selector(("redo:")), "z")
        item.keyEquivalentModifierMask = [.command, .shift]
        return item
    }

    private static func hideOthers() -> NSMenuItem {
        let item = item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h")
        item.keyEquivalentModifierMask = [.command, .option]
        return item
    }
}
