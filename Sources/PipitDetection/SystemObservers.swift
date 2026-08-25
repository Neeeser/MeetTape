import AppKit
import CoreGraphics
import Foundation
import PipitAudio
import PipitCore

/// On-screen window titles for the applications Pipit watches.
///
/// Titles need Screen Recording permission. Without it the list still arrives but
/// every name is missing, which downgrades browser detection to audio state alone
/// rather than breaking it.
public struct WindowTitleReader: Sendable {
    public init() {}

    public var hasTitleAccess: Bool { CGPreflightScreenCaptureAccess() }

    /// Every on-screen window title, keyed by the owning application name.
    public func allTitles() -> [String: [String]] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }
        var result: [String: [String]] = [:]
        for window in windows {
            guard let owner = window[kCGWindowOwnerName as String] as? String,
                  let name = window[kCGWindowName as String] as? String,
                  !name.isEmpty
            else { continue }
            result[owner, default: []].append(name)
        }
        return result
    }

    /// Maps window titles to bundle identifiers, so an unknown call can carry a
    /// name the user recognises.
    public func titlesByBundleIdentifier(from titles: [String: [String]]) -> [String: String] {
        var result: [String: String] = [:]
        for application in NSWorkspace.shared.runningApplications {
            guard let identifier = application.bundleIdentifier,
                  let name = application.localizedName,
                  let windows = titles[name], let first = windows.first
            else { continue }
            result[identifier] = first
        }
        return result
    }

    public func titles(forOwnerNames owners: Set<String>) -> [String: [String]] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }
        var result: [String: [String]] = [:]
        for window in windows {
            guard let owner = window[kCGWindowOwnerName as String] as? String,
                  owners.contains(owner),
                  let name = window[kCGWindowName as String] as? String,
                  !name.isEmpty
            else { continue }
            result[owner, default: []].append(name)
        }
        return result
    }
}

/// Polls CoreAudio for which applications are using audio right now.
public struct AudioProcessObserver: Sendable {
    public init() {}

    public func snapshot() -> [ApplicationAudioState] {
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return CoreAudioSystem.processes().map { process in
            ApplicationAudioState(
                bundleIdentifier: process.bundleIdentifier,
                processID: process.processID,
                holdsMicrophone: process.isRunningInput,
                producesOutput: process.isRunningOutput,
                isFrontmost: process.bundleIdentifier == frontmost,
                windowTitle: nil
            )
        }
    }

    /// True when any process whose bundle identifier starts with one of the
    /// prefixes has an input stream running.
    public func holdsMicrophone(bundlePrefixes: [String], in states: [ApplicationAudioState]) -> Bool {
        states.contains { state in
            state.holdsMicrophone && bundlePrefixes.contains { state.bundleIdentifier.hasPrefix($0) }
        }
    }

    public func producesOutput(bundlePrefixes: [String], in states: [ApplicationAudioState]) -> Bool {
        states.contains { state in
            state.producesOutput && bundlePrefixes.contains { state.bundleIdentifier.hasPrefix($0) }
        }
    }
}

/// Sleep, wake and lock notifications.
///
/// Pipit does not record while the Mac is asleep. It rebuilds capture after
/// wake rather than waiting for the watchdog to notice, because wake reliably
/// invalidates both the engine and the tap.
public final class PowerEventObserver: @unchecked Sendable {
    private var observers: [NSObjectProtocol] = []
    private let onWake: @Sendable () -> Void
    private let onSleep: @Sendable () -> Void

    public init(onWake: @escaping @Sendable () -> Void, onSleep: @escaping @Sendable () -> Void) {
        self.onWake = onWake
        self.onSleep = onSleep
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { _ in onWake() })
        observers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: nil
        ) { _ in onSleep() })
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
    }
}
