import AppKit
import ApplicationServices
import Foundation

// Dumps the accessibility tree of a running app so we can see what a meeting
// client actually exposes: participant names, speaking state, mute state.

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

func attrNames(_ e: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyAttributeNames(e, &names) == .success else { return [] }
    return (names as? [String]) ?? []
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: axdump <bundle-id> [maxDepth] [budget] [grep]")
    exit(2)
}
let bundleID = args[1]
let maxDepth = args.count > 2 ? Int(args[2])! : 30
var budget = args.count > 3 ? Int(args[3])! : 60_000
let needle = args.count > 4 ? args[4].lowercased() : ""

print("AXIsProcessTrusted: \(AXIsProcessTrusted())")
guard AXIsProcessTrusted() else {
    _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    print("not trusted; prompted")
    exit(1)
}

guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
    print("not running: \(bundleID)")
    exit(1)
}
print("pid: \(app.processIdentifier)")
let root = AXUIElementCreateApplication(app.processIdentifier)
// Electron/Chromium apps gate their web a11y tree behind this attribute.
AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)

var lines = 0
func walk(_ e: AXUIElement, _ depth: Int) {
    if budget <= 0 { return }
    budget -= 1
    let role = str(e, kAXRoleAttribute as String) ?? "?"
    let sub = str(e, kAXSubroleAttribute as String) ?? ""
    let title = str(e, kAXTitleAttribute as String) ?? ""
    let desc = str(e, kAXDescriptionAttribute as String) ?? ""
    let value = str(e, kAXValueAttribute as String) ?? ""
    let help = str(e, kAXHelpAttribute as String) ?? ""
    let ident = str(e, "AXIdentifier") ?? ""
    let dom = str(e, "AXDOMIdentifier") ?? ""
    let cls = str(e, "AXDOMClassList") ?? ""
    var parts: [String] = ["\(role)\(sub.isEmpty ? "" : "/\(sub)")"]
    for (k, v) in [("title", title), ("desc", desc), ("value", value), ("help", help),
                   ("id", ident), ("domid", dom), ("class", cls)] where !v.isEmpty {
        parts.append("\(k)=\(v.prefix(120).replacingOccurrences(of: "\n", with: "\\n"))")
    }
    let line = parts.joined(separator: " | ")
    if needle.isEmpty || line.lowercased().contains(needle) {
        print(String(repeating: "  ", count: min(depth, 20)) + line)
        lines += 1
        if ProcessInfo.processInfo.environment["AXFULL"] != nil {
            for n in attrNames(e) where ![kAXChildrenAttribute as String, "AXRole", "AXSubrole", "AXTitle", "AXDescription", "AXValue", "AXHelp", "AXIdentifier", "AXParent", "AXPosition", "AXSize", "AXFrame", "AXTopLevelUIElement", "AXWindow"].contains(n) {
                if let v = str(e, n), !v.isEmpty {
                    print(String(repeating: "  ", count: min(depth, 20)) + "    · \(n) = \(v.prefix(160))")
                }
            }
        }
    }
    if depth >= maxDepth { return }
    for c in kids(e) { walk(c, depth + 1) }
}

walk(root, 0)
FileHandle.standardError.write("\n-- printed \(lines) lines, budget left \(budget)\n".data(using: .utf8)!)
