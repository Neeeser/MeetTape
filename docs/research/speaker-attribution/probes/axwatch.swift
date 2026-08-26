// Watches one app's accessibility tree and prints what changes.
//
// The speaking indicator in a Slack huddle is whichever node flips in time with
// speech, so this diffs the tree instead of guessing at labels. Run it during a
// huddle, take turns talking, and read the diff.
//
//   xcrun swiftc -O axwatch.swift -o axwatch
//   ./axwatch com.tinyspeck.slackmacgap --interval 0.2 --seconds 90 > huddle.log
//
// Accessibility permission belongs to the terminal that runs this, not to the
// binary.

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

struct Options {
    var bundleID = ""
    var interval = 0.25
    var seconds = 120.0
    var maxDepth = 40
    var budget = 200_000
    var windowFilter: String?
}

var options = Options()
var rest = Array(CommandLine.arguments.dropFirst())
guard let first = rest.first, !first.hasPrefix("--") else {
    print("usage: axwatch <bundle-id> [--interval 0.25] [--seconds 120] [--window <substring>]")
    exit(2)
}
options.bundleID = first
rest.removeFirst()
var index = 0
while index < rest.count {
    switch rest[index] {
    case "--interval": options.interval = Double(rest[index + 1]) ?? 0.25; index += 2
    case "--seconds": options.seconds = Double(rest[index + 1]) ?? 120; index += 2
    case "--depth": options.maxDepth = Int(rest[index + 1]) ?? 40; index += 2
    case "--window": options.windowFilter = rest[index + 1].lowercased(); index += 2
    default: index += 1
    }
}

guard AXIsProcessTrusted() else {
    _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    print("accessibility not granted for this terminal")
    exit(1)
}
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: options.bundleID).first
else {
    print("not running: \(options.bundleID)")
    exit(1)
}

let root = AXUIElementCreateApplication(app.processIdentifier)
// Electron and Chromium apps only build the web accessibility tree once a
// client asks for it.
AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)

let interesting = [
    "AXRole", "AXSubrole", "AXTitle", "AXDescription", "AXValue", "AXHelp",
    "AXIdentifier", "AXDOMIdentifier", "AXDOMClassList", "AXSelected",
    "AXExpanded", "AXARIALive", "AXARIAAtomic", "AXInvalid", "AXOrientation",
]

func describe(_ e: AXUIElement) -> String {
    var parts: [String] = []
    for name in interesting {
        if let v = str(e, name), !v.isEmpty {
            parts.append("\(name.dropFirst(2))=\(v.prefix(140).replacingOccurrences(of: "\n", with: "\\n"))")
        }
    }
    return parts.joined(separator: " | ")
}

/// Snapshot keyed by index path, so a node keeps its identity between ticks
/// even when it carries no stable identifier.
func snapshot() -> [String: String] {
    var out: [String: String] = [:]
    var budget = options.budget
    func walk(_ e: AXUIElement, _ path: String, _ depth: Int) {
        if budget <= 0 { return }
        budget -= 1
        out[path] = describe(e)
        if depth >= options.maxDepth { return }
        for (i, c) in kids(e).enumerated() { walk(c, "\(path).\(i)", depth + 1) }
    }
    var roots: [(String, AXUIElement)] = []
    if let filter = options.windowFilter {
        for (i, w) in kids(root).enumerated() {
            let title = (str(w, kAXTitleAttribute as String) ?? "").lowercased()
            if title.contains(filter) { roots.append(("w\(i)", w)) }
        }
        if roots.isEmpty { return [:] }
    } else {
        roots = kids(root).enumerated().map { ("w\($0.offset)", $0.element) }
    }
    for (name, element) in roots { walk(element, name, 0) }
    return out
}

let started = Date()
var previous: [String: String] = [:]
var ticks = 0
print("watching \(options.bundleID) pid \(app.processIdentifier) every \(options.interval)s for \(options.seconds)s")

while Date().timeIntervalSince(started) < options.seconds {
    let began = Date()
    let current = snapshot()
    let stamp = String(format: "%8.3f", began.timeIntervalSince(started))
    if ticks == 0 {
        print("\(stamp) BASELINE \(current.count) nodes")
        for (path, line) in current.sorted(by: { $0.key < $1.key }) where !line.isEmpty {
            print("\(stamp)   = \(path) \(line)")
        }
    } else {
        for (path, line) in current.sorted(by: { $0.key < $1.key }) {
            let before = previous[path]
            if before == nil {
                if !line.isEmpty { print("\(stamp)   + \(path) \(line)") }
            } else if before != line {
                print("\(stamp)   ~ \(path)")
                print("\(stamp)       was \(before!)")
                print("\(stamp)       now \(line)")
            }
        }
        for path in previous.keys where current[path] == nil {
            if !(previous[path] ?? "").isEmpty { print("\(stamp)   - \(path) \(previous[path]!)") }
        }
    }
    previous = current
    ticks += 1
    let elapsed = Date().timeIntervalSince(began)
    if elapsed < options.interval { Thread.sleep(forTimeInterval: options.interval - elapsed) }
    fflush(stdout)
}
FileHandle.standardError.write("\n-- \(ticks) ticks\n".data(using: .utf8)!)
