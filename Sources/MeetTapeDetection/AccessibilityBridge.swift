import AppKit
import ApplicationServices
import Foundation
import MeetTapeCore

/// Minimal accessibility reading, bounded so a 500 ms poll stays cheap.
public enum AccessibilityBridge {
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that offers to open the Accessibility pane.
    ///
    /// Accessibility has no programmatic grant: the prompt only points at System
    /// Settings, and the user has to flip the switch there.
    @discardableResult
    public static func requestTrust() -> Bool {
        // kAXTrustedCheckOptionPrompt is an imported global whose Swift form is a
        // mutable var, so the literal key is used directly.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    public static func processID(forBundleIdentifier bundleIdentifier: String) -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first?.processIdentifier
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        guard let value = attribute(element, name) else { return nil }
        if CFGetTypeID(value) == CFStringGetTypeID() { return (value as! CFString) as String }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        guard let value = attribute(element, kAXChildrenAttribute as String) else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    /// One node's identifying text, lowercased for matching.
    struct Node {
        let role: String
        let title: String
        let description: String
        let value: String
    }

    static func snapshot(_ element: AXUIElement) -> Node {
        Node(
            role: string(element, kAXRoleAttribute as String) ?? "",
            title: string(element, kAXTitleAttribute as String) ?? "",
            description: string(element, kAXDescriptionAttribute as String) ?? "",
            value: string(element, kAXValueAttribute as String) ?? ""
        )
    }

    /// Depth- and node-bounded walk. Returns false from `visit` to stop early.
    static func walk(
        _ element: AXUIElement, maxDepth: Int, budget: inout Int, depth: Int = 0,
        visit: (Node) -> Bool
    ) -> Bool {
        guard budget > 0 else { return true }
        budget -= 1
        if !visit(snapshot(element)) { return false }
        guard depth < maxDepth else { return true }
        for child in children(element) {
            if !walk(child, maxDepth: maxDepth, budget: &budget, depth: depth + 1, visit: visit) {
                return false
            }
        }
        return true
    }
}

/// Reads Slack's huddle controls.
///
/// `AXButton` described as "Leave Huddle" is the only reliable join signal, and
/// its mute counterpart inverts its label while muted. Nothing else about a huddle
/// is exposed: participant names and the active speaker are not available from
/// Slack on macOS, and the app is expected to work without them.
public struct SlackAccessibilityReader: Sendable {
    public let bundleIdentifier: String

    public init(bundleIdentifier: String = "com.tinyspeck.slackmacgap") {
        self.bundleIdentifier = bundleIdentifier
    }

    public func read() -> SlackAccessibilityObservation {
        guard AccessibilityBridge.isTrusted,
              let pid = AccessibilityBridge.processID(forBundleIdentifier: bundleIdentifier)
        else {
            return SlackAccessibilityObservation(hasLeaveHuddleControl: false, subtreeWasEmpty: true)
        }

        let application = AXUIElement.forApplication(pid: pid)
        let windows = AccessibilityBridge.children(application)
        guard !windows.isEmpty else {
            return SlackAccessibilityObservation(hasLeaveHuddleControl: false, subtreeWasEmpty: true)
        }

        var hasLeave = false
        var muted: Bool?
        var title: String?
        var visitedNodes = 0
        var budget = 6_000

        for window in windows {
            guard AccessibilityBridge.string(window, kAXRoleAttribute as String) == (kAXWindowRole as String)
            else { continue }
            if title == nil {
                title = AccessibilityBridge.string(window, kAXTitleAttribute as String)
            }
            _ = AccessibilityBridge.walk(window, maxDepth: 14, budget: &budget) { node in
                visitedNodes += 1
                let haystack = "\(node.description) \(node.title)".lowercased()
                if haystack.contains("leave huddle") { hasLeave = true }
                if haystack.contains("unmute microphone") { muted = true }
                else if haystack.contains("mute microphone") { muted = false }
                return true
            }
        }

        return SlackAccessibilityObservation(
            hasLeaveHuddleControl: hasLeave,
            subtreeWasEmpty: visitedNodes <= windows.count,
            isMuted: muted,
            windowTitle: title
        )
    }
}

extension AXUIElement {
    static func forApplication(pid: pid_t) -> AXUIElement {
        AXUIElementCreateApplication(pid)
    }
}
