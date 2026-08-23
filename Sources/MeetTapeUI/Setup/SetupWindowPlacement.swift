import AppKit
import CoreGraphics
import Foundation

/// Keeps the setup window beside System Settings rather than on top of it.
///
/// The wizard floats above other applications, because an accessory application
/// cannot win focus back after a permission prompt and a set of instructions is
/// useless behind the window it describes. The cost of floating is that it also
/// covers System Settings, which is where the instructions have to be carried
/// out. Moving aside is what pays that cost back.
public enum SetupWindowPlacement {
    /// Bundle identifier of System Settings.
    public static let systemSettingsBundleID = "com.apple.systempreferences"

    /// Gap between the two windows.
    public static let gap: CGFloat = 16

    /// Where to put a window of `size` so it does not cover `obstacle`.
    ///
    /// All rectangles are in AppKit screen coordinates, origin bottom left.
    /// Chooses the side of the obstacle with more room, centres vertically on it,
    /// and clamps to the screen. When neither side can hold the window, it goes
    /// to the roomier side and is left overlapping: covering part of System
    /// Settings beats being pushed off the display.
    public static func frame(
        for size: CGSize, avoiding obstacle: CGRect, within screen: CGRect
    ) -> CGRect {
        let roomLeft = obstacle.minX - screen.minX
        let roomRight = screen.maxX - obstacle.maxX
        let needed = size.width + gap

        var x: CGFloat
        if roomRight >= needed || roomRight >= roomLeft {
            x = obstacle.maxX + gap
        } else {
            x = obstacle.minX - gap - size.width
        }
        x = min(max(x, screen.minX), max(screen.minX, screen.maxX - size.width))

        var y = obstacle.midY - size.height / 2
        y = min(max(y, screen.minY), max(screen.minY, screen.maxY - size.height))

        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// The System Settings window, in AppKit screen coordinates.
    ///
    /// Read from the window list rather than through the accessibility API,
    /// because setup runs before Accessibility has been granted. Window bounds
    /// are readable without any permission; only the titles are gated.
    @MainActor
    public static func systemSettingsFrame() -> CGRect? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let candidates = windows.compactMap { window -> CGRect? in
            guard let owner = window[kCGWindowOwnerName as String] as? String,
                owner == "System Settings",
                let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { return nil }
            return rect
        }
        // The settings window, not a sheet or a popover it owns.
        guard let biggest = candidates.max(by: { $0.width * $0.height < $1.width * $1.height })
        else { return nil }
        return flipped(biggest)
    }

    /// Converts a window-server rectangle, whose origin is the top left of the
    /// primary display, to AppKit's bottom-left origin.
    @MainActor
    public static func flipped(_ rect: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return rect }
        return CGRect(
            x: rect.minX,
            y: primary.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// The visible area of whichever screen holds most of `rect`.
    @MainActor
    public static func screen(containing rect: CGRect) -> CGRect {
        let best = NSScreen.screens.max { left, right in
            left.frame.intersection(rect).area < right.frame.intersection(rect).area
        }
        return (best ?? NSScreen.main)?.visibleFrame ?? rect
    }
}

extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
