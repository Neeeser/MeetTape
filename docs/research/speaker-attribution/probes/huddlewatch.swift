// Reads the Slack huddle roster and who is talking, and prints every change.
//
// This is the shape a real reader would take. Tiles are keyed by their DOM
// identifier, which carries the Slack user id, because the tree reorders under
// the walker and an index path does not survive that.
//
//   xcrun swiftc -O huddlewatch.swift -o /tmp/huddlewatch && /tmp/huddlewatch 120
//
// Signals read per tile:
//   AXDOMIdentifier   huddle-grid-gridcell-self_U03SOLOUSER  (Slack user id)
//   AXDescription     View Ada Lovelace's profile           (display name)
//   AXDescription     video is off, audio is on              (mute state)
//   AXDOMClassList    p-huddle_peer_tile__overlay--active_speaker

import AppKit
import ApplicationServices
import Foundation

func attr(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success else { return nil }
    return v
}

func str(_ e: AXUIElement, _ name: String) -> String? {
    guard let v = attr(e, name) else { return nil }
    if CFGetTypeID(v) == CFStringGetTypeID() { return (v as! CFString) as String }
    if let n = v as? NSNumber { return n.stringValue }
    if let a = v as? [Any] { return a.map { "\($0)" }.joined(separator: ",") }
    return nil
}

func kids(_ e: AXUIElement) -> [AXUIElement] {
    (attr(e, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

let seconds = Double(CommandLine.arguments.dropFirst().first ?? "120") ?? 120
let tilePrefix = "huddle-grid-gridcell"
let speakingClass = "p-huddle_peer_tile__overlay--active_speaker"

guard AXIsProcessTrusted() else {
    _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    print("accessibility not granted for this terminal")
    exit(1)
}
guard let app = NSRunningApplication
    .runningApplications(withBundleIdentifier: "com.tinyspeck.slackmacgap").first
else {
    print("Slack is not running")
    exit(1)
}
let root = AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)

struct Tile {
    var element: AXUIElement
    var userID: String
    var name: String?
    var isSelf: Bool
}

/// Walks for tiles. Costs a full traversal, so it runs on a slow cadence and the
/// element references it finds are polled directly in between.
func findTiles() -> [String: Tile] {
    var found: [String: Tile] = [:]
    var budget = 300_000
    func walk(_ e: AXUIElement, _ depth: Int) {
        if budget <= 0 || depth > 45 { return }
        budget -= 1
        if let id = str(e, "AXDOMIdentifier"), id.hasPrefix(tilePrefix),
           !id.contains("a11y_huddle_peer_tile_description") {
            // Own tile:    huddle-grid-gridcell-self_U01SELFUSER
            // Other tile:  huddle-grid-gridcell-<session-uuid>_U02OTHERUSR
            // The user id is what follows the last underscore either way. The
            // prefix is the session, so one person on two devices is two tiles
            // carrying one id.
            let userID = id.split(separator: "_").last.map(String.init) ?? id
            let isSelf = id.contains("-self_")
            let cleaned = userID
            let description = str(e, kAXDescriptionAttribute as String)
            let name = description?
                .replacingOccurrences(of: "View ", with: "")
                .replacingOccurrences(of: "'s profile", with: "")
            if found[id] == nil {
                found[id] = Tile(element: e, userID: cleaned, name: name, isSelf: isSelf)
            }
            return
        }
        for c in kids(e) { walk(c, depth + 1) }
    }
    walk(root, 0)
    return found
}

/// Reads one tile's live state from its own subtree.
func readTile(_ tile: Tile) -> (speaking: Bool, muted: Bool?, alive: Bool) {
    var speaking = false
    var muted: Bool?
    var saw = false
    var budget = 200
    func walk(_ e: AXUIElement, _ depth: Int) {
        if budget <= 0 || depth > 6 { return }
        budget -= 1
        if let classes = str(e, "AXDOMClassList") {
            saw = true
            if classes.contains(speakingClass) { speaking = true }
        }
        if let description = str(e, kAXDescriptionAttribute as String) {
            saw = true
            if description.contains("audio is on") { muted = false }
            else if description.contains("audio is off") { muted = true }
        }
        for c in kids(e) { walk(c, depth + 1) }
    }
    walk(tile.element, 0)
    return (speaking, muted, saw)
}

let started = Date()
var tiles = findTiles()
var lastScan = Date()
var previous: [String: String] = [:]
print("tiles: " + tiles.values
    .map { "\($0.name ?? "?") [\($0.userID)]\($0.isSelf ? " (self)" : " (remote)")" }
    .joined(separator: ", "))

while Date().timeIntervalSince(started) < seconds {
    let tick = Date()
    var stale = tiles.isEmpty
    for (id, tile) in tiles {
        let state = readTile(tile)
        if !state.alive { stale = true; continue }
        let line = "speaking=\(state.speaking) muted=\(state.muted.map(String.init) ?? "?")"
        if previous[id] != line {
            previous[id] = line
            let who = "\(tile.name ?? tile.userID)\(tile.isSelf ? " (self)" : " (remote)")"
            print(String(format: "%8.3f  %@  %@", tick.timeIntervalSince(started),
                         who.padding(toLength: 26, withPad: " ", startingAt: 0), line))
            fflush(stdout)
        }
    }
    // The grid re-renders and invalidates element references, so the tile list is
    // rebuilt whenever a read comes back empty, and periodically regardless.
    if stale || tick.timeIntervalSince(lastScan) > 5 {
        let rescanned = findTiles()
        if !rescanned.isEmpty { tiles = rescanned }
        lastScan = tick
    }
    let elapsed = Date().timeIntervalSince(tick)
    if elapsed < 0.05 { Thread.sleep(forTimeInterval: 0.05 - elapsed) }
}
