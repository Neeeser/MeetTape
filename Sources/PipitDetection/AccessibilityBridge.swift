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

    /// One node's identifying text.
    ///
    /// Every field here costs a synchronous call into another process, so the
    /// struct holds what a visitor actually reads and nothing else. Role and
    /// value used to be collected for nobody, which was two wasted round trips
    /// per node on a walk that runs twice a second.
    struct Node {
        let title: String
        let description: String
        /// Electron and Chromium apps expose the page's own id and class list
        /// once `AXManualAccessibility` is set, and Slack's class names say what
        /// they mean. Without these a huddle tile is anonymous. Both are read
        /// only where a caller asked for them, because outside a huddle there
        /// are no tiles to find and the reads are pure cost.
        let domIdentifier: String
        let domClassList: String
    }

    static func snapshot(_ element: AXUIElement, wantsDOM: Bool = false) -> Node {
        Node(
            title: string(element, kAXTitleAttribute as String) ?? "",
            description: string(element, kAXDescriptionAttribute as String) ?? "",
            domIdentifier: wantsDOM ? (string(element, "AXDOMIdentifier") ?? "") : "",
            domClassList: wantsDOM ? (string(element, "AXDOMClassList") ?? "") : ""
        )
    }

    /// Walk that hands the element over as well as its text, so a subtree can be
    /// re-entered. Returning false from `visit` prunes that node's children
    /// without stopping the walk.
    static func walkElements(
        _ element: AXUIElement, maxDepth: Int, budget: inout Int, wantsDOM: Bool = false,
        depth: Int = 0, visit: (AXUIElement, Node) -> Bool
    ) {
        guard budget > 0 else { return }
        budget -= 1
        guard visit(element, snapshot(element, wantsDOM: wantsDOM)) else { return }
        guard depth < maxDepth else { return }
        for child in children(element) {
            walkElements(
                child, maxDepth: maxDepth, budget: &budget, wantsDOM: wantsDOM,
                depth: depth + 1, visit: visit
            )
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

    static func webTreeIsBuilt(pid: pid_t) -> Bool {
        enabledPIDs.withLock { $0.contains(pid) }
    }

    private static func enableWebTree(_ application: AXUIElement, pid: pid_t) {
        let alreadyEnabled = enabledPIDs.withLock { $0.contains(pid) }
        guard !alreadyEnabled else { return }
        let result = AXUIElementSetAttributeValue(
            application, "AXManualAccessibility" as CFString, kCFBooleanTrue
        )
        // Only a set that worked counts. Slack's accessibility server is not up
        // the instant the app launches, and recording the attempt regardless
        // meant one early failure left the web tree unbuilt for the life of that
        // process: every tile identifier empty, the roster silently dead, and
        // nothing to see until the user restarted Slack.
        guard result == .success else { return }
        enabledPIDs.withLock { $0.insert(pid) }
    }

    public func read() -> SlackAccessibilityObservation {
        guard AccessibilityBridge.isTrusted else { return .unavailable }
        guard let pid = AccessibilityBridge.processID(forBundleIdentifier: bundleIdentifier) else {
            return SlackAccessibilityObservation(hasLeaveHuddleControl: false, subtreeWasEmpty: true)
        }

        let application = AXUIElement.forApplication(pid: pid)
        // The web tree is what carries the tile identifiers, and Chromium only
        // builds it once a client asks. Asking costs Slack a full accessibility
        // tree for the rest of its life, so it is asked for only once a huddle
        // is actually running. The leave control that proves one is running is
        // found without it, which is how this worked before tiles existed.
        //
        // The cost of waiting is one poll: the first read inside a huddle sees
        // no tiles, the next sees them all.
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
        //
        // Raised with the depth limit. The walk goes to 24 now because the
        // huddle tiles sit deeper than the controls do, and a depth-first walk
        // spends budget on depth before breadth, so holding the old allowance
        // would have reached fewer sibling subtrees than before. A whole Slack
        // process measured 708 nodes with the web tree built, so this is a wide
        // margin rather than a tuned number.
        let budgetPerWindow = 20_000

        // Tiles exist only inside a huddle, and their identifiers only once
        // Chromium has been asked to build the web tree. Outside a huddle both
        // are pure cost on a walk that runs twice a second, so the first pass
        // reads the cheap attributes and stops there.
        var pass = scan(windows: windows, wantsTiles: Self.webTreeIsBuilt(pid: pid))

        // A huddle was found and this pass was not looking for tiles, which is
        // the first poll of every huddle and of every launch. Ask for the tree
        // and look again rather than reporting a huddle with nobody in it: one
        // extra walk, once, against a roster that would otherwise arrive a poll
        // late every time the app restarts mid-call.
        if pass.hasLeave, !pass.wantedTiles {
            Self.enableWebTree(application, pid: pid)
            pass = scan(windows: windows, wantsTiles: true)
        }

        return SlackAccessibilityObservation(
            hasLeaveHuddleControl: pass.hasLeave,
            // A truncated walk proves nothing about the control's absence.
            subtreeWasEmpty: pass.visitedNodes <= windows.count
                || (pass.truncated && !pass.hasLeave),
            isMuted: pass.muted,
            windowTitle: pass.title,
            tiles: pass.tiles
        )
    }

    private struct Pass {
        var hasLeave = false
        var muted: Bool?
        var title: String?
        var visitedNodes = 0
        var truncated = false
        var tiles: [SlackHuddleTile] = []
        var wantedTiles = false
    }

    private func scan(windows: [AXUIElement], wantsTiles: Bool) -> Pass {
        var pass = Pass()
        pass.wantedTiles = wantsTiles
        var byID: [String: SlackHuddleTile] = [:]
        var order: [String] = []
        // Each window gets its own budget, so a large workspace window cannot
        // consume the whole allowance before the huddle window is reached. A
        // whole Slack process measured 708 nodes with the web tree built, so
        // this is a wide margin rather than a tuned number.
        let budgetPerWindow = 20_000

        for window in windows {
            guard AccessibilityBridge.string(window, kAXRoleAttribute as String)
                == (kAXWindowRole as String) else { continue }
            if pass.title == nil {
                pass.title = AccessibilityBridge.string(window, kAXTitleAttribute as String)
            }
            var budget = budgetPerWindow
            // Tiles are collected during the walk and read after it: reading a
            // subtree from inside the walk would borrow the same budget twice.
            // Depth follows the same rule as the attributes, because the
            // controls sit high in the tree and only the tiles are deep.
            var found: [(element: AXUIElement, userID: String, isSelf: Bool, description: String)] = []
            AccessibilityBridge.walkElements(
                window, maxDepth: wantsTiles ? 24 : 16, budget: &budget, wantsDOM: wantsTiles
            ) { element, node in
                pass.visitedNodes += 1
                let haystack = "\(node.description) \(node.title)".lowercased()
                if haystack.contains("leave huddle") { pass.hasLeave = true }
                if haystack.contains("unmute microphone") { pass.muted = true }
                else if haystack.contains("mute microphone") { pass.muted = false }

                guard wantsTiles,
                      let userID = SlackHuddleTileParser.userID(from: node.domIdentifier)
                else { return true }
                found.append((
                    element: element, userID: userID,
                    isSelf: SlackHuddleTileParser.isSelf(node.domIdentifier),
                    description: node.description
                ))
                // A tile's state lives in its own subtree, read below, so the
                // outer walk does not descend into it.
                return false
            }
            for entry in found {
                let tile = readTile(
                    entry.element, userID: entry.userID, isSelf: entry.isSelf,
                    description: entry.description, budget: &budget
                )
                if let existing = byID[entry.userID] {
                    byID[entry.userID] = merge(existing, tile)
                } else {
                    byID[entry.userID] = tile
                    order.append(entry.userID)
                }
            }
            // Exhaustion, not a strict overrun: the walk stops decrementing at
            // zero, so zero is the only evidence there is. A walk that happens
            // to finish on its last node is reported truncated too, which reads
            // as "no information" and is the safe direction.
            if budget <= 0 { pass.truncated = true }
        }
        pass.tiles = order.compactMap { byID[$0] }
        return pass
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

    /// Reads one tile from its own subtree, spending the caller's budget.
    ///
    /// Sharing the budget rather than taking a fresh one per tile is the point:
    /// a twenty-person huddle would otherwise add thousands of uncounted
    /// cross-process reads to a walk that runs twice a second.
    private func readTile(
        _ element: AXUIElement, userID: String, isSelf: Bool, description: String,
        budget: inout Int
    ) -> SlackHuddleTile {
        var name = SlackHuddleTileParser.displayName(from: description)
        var muted: Bool?
        var speaking = false
        // Bounded hard: a tile subtree is small, and the poll runs twice a
        // second beside everything else detection does.
        AccessibilityBridge.walkElements(
            element, maxDepth: 8, budget: &budget, wantsDOM: true
        ) { _, node in
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
