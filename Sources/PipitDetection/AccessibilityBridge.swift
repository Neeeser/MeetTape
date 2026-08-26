import AppKit
import ApplicationServices
import os
import Foundation
import PipitCore

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
        // AXDOMClassList arrives as an array of class names.
        if let list = value as? [Any] { return list.map { "\($0)" }.joined(separator: ",") }
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
        /// Electron and Chromium apps expose the page's own id and class list
        /// once `AXManualAccessibility` is set, and Slack's class names say what
        /// they mean. Without these a huddle tile is anonymous.
        let domIdentifier: String
        let domClassList: String
    }

    static func snapshot(_ element: AXUIElement) -> Node {
        Node(
            role: string(element, kAXRoleAttribute as String) ?? "",
            title: string(element, kAXTitleAttribute as String) ?? "",
            description: string(element, kAXDescriptionAttribute as String) ?? "",
            value: string(element, kAXValueAttribute as String) ?? "",
            domIdentifier: string(element, "AXDOMIdentifier") ?? "",
            domClassList: string(element, "AXDOMClassList") ?? ""
        )
    }

    /// Walk that hands the element over as well as its text, so a subtree can be
    /// re-entered. Returning false from `visit` prunes that node's children
    /// without stopping the walk.
    static func walkElements(
        _ element: AXUIElement, maxDepth: Int, budget: inout Int, depth: Int = 0,
        visit: (AXUIElement, Node) -> Bool
    ) {
        guard budget > 0 else { return }
        budget -= 1
        guard visit(element, snapshot(element)) else { return }
        guard depth < maxDepth else { return }
        for child in children(element) {
            walkElements(child, maxDepth: maxDepth, budget: &budget, depth: depth + 1, visit: visit)
        }
    }

}

/// Reads Slack's huddle controls and its roster.
///
/// `AXButton` described as "Leave Huddle" is the only reliable join signal, and
/// its mute counterpart inverts its label while muted.
///
/// The huddle grid is readable too. Setting `AXManualAccessibility` builds
/// Slack's web accessibility tree, and each tile then carries the Slack user id
/// in `AXDOMIdentifier`, the display name in its description, the mute state in
/// its name overlay, and a speaking class that exists only while that person
/// holds the floor. All four are readable for other people, not only for the
/// local user, which is the case that matters, because the far end arrives as
/// one mixed track.
public struct SlackAccessibilityReader: Sendable {
    public let bundleIdentifier: String

    public init(bundleIdentifier: String = "com.tinyspeck.slackmacgap") {
        self.bundleIdentifier = bundleIdentifier
    }

    /// Processes already asked to build their web tree. Keyed by pid, so a
    /// relaunched Slack is asked again.
    private static let enabledPIDs = OSAllocatedUnfairLock<Set<pid_t>>(initialState: [])

    private static func enableWebTree(_ application: AXUIElement, pid: pid_t) {
        let alreadyEnabled = enabledPIDs.withLock { pids -> Bool in
            if pids.contains(pid) { return true }
            pids.insert(pid)
            return false
        }
        guard !alreadyEnabled else { return }
        AXUIElementSetAttributeValue(
            application, "AXManualAccessibility" as CFString, kCFBooleanTrue
        )
    }

    public func read() -> SlackAccessibilityObservation {
        guard AccessibilityBridge.isTrusted else { return .unavailable }
        guard let pid = AccessibilityBridge.processID(forBundleIdentifier: bundleIdentifier) else {
            return SlackAccessibilityObservation(hasLeaveHuddleControl: false, subtreeWasEmpty: true)
        }

        let application = AXUIElement.forApplication(pid: pid)
        // Chromium only builds the web tree once a client asks for it, and the
        // tile identifiers live in that tree. The flag latches, so it is set
        // once per Slack process rather than on every poll: asking twice a
        // second makes Slack rebuild and maintain a full accessibility tree
        // whether or not a huddle is running.
        Self.enableWebTree(application, pid: pid)
        let windows = AccessibilityBridge.children(application)
        guard !windows.isEmpty else {
            return SlackAccessibilityObservation(hasLeaveHuddleControl: false, subtreeWasEmpty: true)
        }

        var hasLeave = false
        var muted: Bool?
        var title: String?
        var visitedNodes = 0
        var truncated = false
        // Each window gets its own budget, so a large workspace window cannot
        // consume the whole allowance before the huddle window is reached.
        let budgetPerWindow = 4_000

        var tiles: [String: SlackHuddleTile] = [:]
        var tileOrder: [String] = []

        for window in windows {
            guard AccessibilityBridge.string(window, kAXRoleAttribute as String) == (kAXWindowRole as String)
            else { continue }
            if title == nil {
                title = AccessibilityBridge.string(window, kAXTitleAttribute as String)
            }
            var budget = budgetPerWindow
            AccessibilityBridge.walkElements(window, maxDepth: 24, budget: &budget) { element, node in
                visitedNodes += 1
                let haystack = "\(node.description) \(node.title)".lowercased()
                if haystack.contains("leave huddle") { hasLeave = true }
                if haystack.contains("unmute microphone") { muted = true }
                else if haystack.contains("mute microphone") { muted = false }

                guard let userID = SlackHuddleTileParser.userID(from: node.domIdentifier) else {
                    return true
                }
                // A tile's own subtree carries its state, so it is read here and
                // its children are not walked again by the outer pass.
                let tile = readTile(
                    element, userID: userID,
                    isSelf: SlackHuddleTileParser.isSelf(node.domIdentifier),
                    description: node.description
                )
                if let existing = tiles[userID] {
                    tiles[userID] = merge(existing, tile)
                } else {
                    tiles[userID] = tile
                    tileOrder.append(userID)
                }
                return false
            }
            if budget <= 0 { truncated = true }
        }

        // A truncated walk proves nothing about the control's absence.
        return SlackAccessibilityObservation(
            hasLeaveHuddleControl: hasLeave,
            subtreeWasEmpty: visitedNodes <= windows.count || (truncated && !hasLeave),
            isMuted: muted,
            windowTitle: title,
            tiles: tileOrder.compactMap { tiles[$0] }
        )
    }

    /// One person joined from two devices is two tiles sharing a user id. They
    /// are one person: speaking on either device is that person speaking, and
    /// they count as unmuted if either device is.
    private func merge(_ lhs: SlackHuddleTile, _ rhs: SlackHuddleTile) -> SlackHuddleTile {
        SlackHuddleTile(
            userID: lhs.userID,
            displayName: lhs.displayName ?? rhs.displayName,
            isSelf: lhs.isSelf || rhs.isSelf,
            isMuted: (lhs.isMuted == false || rhs.isMuted == false)
                ? false : (lhs.isMuted ?? rhs.isMuted),
            isSpeaking: lhs.isSpeaking || rhs.isSpeaking
        )
    }

    private func readTile(
        _ element: AXUIElement, userID: String, isSelf: Bool, description: String
    ) -> SlackHuddleTile {
        var name = SlackHuddleTileParser.displayName(from: description)
        var muted: Bool?
        var speaking = false
        // Bounded hard: a tile subtree is small, and the poll runs twice a
        // second beside everything else detection does.
        var budget = 240
        AccessibilityBridge.walkElements(element, maxDepth: 8, budget: &budget) { _, node in
            if name == nil { name = SlackHuddleTileParser.displayName(from: node.description) }
            if SlackHuddleTileParser.isSpeaking(classList: node.domClassList) { speaking = true }
            if let state = SlackHuddleTileParser.isMuted(description: node.description) {
                muted = state
            }
            return true
        }
        return SlackHuddleTile(
            userID: userID, displayName: name, isSelf: isSelf,
            isMuted: muted, isSpeaking: speaking
        )
    }
}

extension AXUIElement {
    static func forApplication(pid: pid_t) -> AXUIElement {
        AXUIElementCreateApplication(pid)
    }
}
