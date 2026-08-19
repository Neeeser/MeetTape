import AppKit
import Foundation
import MeetTapeCore

/// Decides whether a process connecting to the sensor socket is really a browser
/// relay.
///
/// This matters more than it looks. MeetTape holds the microphone and system
/// audio grants, so a local process that can make it believe a meeting started
/// gets recording without ever triggering a TCC prompt of its own. The socket
/// lives in a 0700 directory and is 0600, which bounds the attacker to processes
/// running as the user; this check bounds it further to MeetTape's own host
/// binary, launched by a browser.
public struct SensorPeerVerifier: Sendable {
    public struct Peer: Sendable, Equatable {
        public let processID: pid_t
        public let executablePath: String
        public let parentPath: String?
        public let parentBundleIdentifier: String?

        public init(
            processID: pid_t, executablePath: String,
            parentPath: String?, parentBundleIdentifier: String?
        ) {
            self.processID = processID
            self.executablePath = executablePath
            self.parentPath = parentPath
            self.parentBundleIdentifier = parentBundleIdentifier
        }
    }

    /// Absolute paths the host binary is allowed to run from.
    public let allowedHostPaths: Set<String>
    /// Bundle identifiers of browsers allowed to be the host's parent.
    public let allowedParentBundleIDs: Set<String>

    public init(
        allowedHostPaths: Set<String>? = nil,
        allowedParentBundleIDs: Set<String>? = nil
    ) {
        if let allowedHostPaths {
            self.allowedHostPaths = allowedHostPaths
        } else {
            var paths: Set<String> = [
                SensorTransport.defaultApplicationSupport
                    .appendingPathComponent("meettape-nativehost").path,
            ]
            if let bundled = NativeMessagingInstaller.bundledHostURL()?.path { paths.insert(bundled) }
            self.allowedHostPaths = paths
        }
        self.allowedParentBundleIDs = allowedParentBundleIDs
            ?? Set(BrowserKind.allCases.flatMap(\.bundleIdentifiers))
    }

    public func peer(of descriptor: Int32) -> Peer? {
        var processID: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &processID, &size) == 0,
              processID > 0
        else { return nil }
        guard let path = executablePath(of: processID) else { return nil }
        let parent = parentProcessID(of: processID)
        return Peer(
            processID: processID,
            executablePath: path,
            parentPath: parent.flatMap { executablePath(of: $0) },
            parentBundleIdentifier: parent.flatMap {
                NSRunningApplication(processIdentifier: $0)?.bundleIdentifier
            }
        )
    }

    /// True when the peer is MeetTape's own host binary, launched by a browser.
    ///
    /// The parent check is what makes it meaningful: the host is a relay for
    /// whatever it is fed on standard input, so "it is our binary" alone would
    /// not stop an attacker from running it themselves.
    public func isTrusted(_ peer: Peer) -> Bool {
        guard allowedHostPaths.contains(peer.executablePath) else { return false }
        // The bundle identifier is the direct answer; the executable path is the
        // fallback for a browser that is running but not registered.
        if let identifier = peer.parentBundleIdentifier,
           allowedParentBundleIDs.contains(identifier) {
            return true
        }
        guard let parentPath = peer.parentPath else { return false }
        return allowedParentBundleIDs.contains { identifier in
            guard let applicationURL = NSWorkspace.shared
                .urlForApplication(withBundleIdentifier: identifier)
            else { return false }
            return parentPath.hasPrefix(applicationURL.deletingLastPathComponent().path)
        }
    }

    /// Why a peer was refused, for the log and the permissions pane.
    public func rejectionReason(_ peer: Peer) -> String {
        if !allowedHostPaths.contains(peer.executablePath) {
            return "the connecting process is not MeetTape's relay"
        }
        return "the relay was not launched by a browser"
    }

    private func executablePath(of processID: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(processID, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer[0..<Int(length)], as: UTF8.self)
    }

    private func parentProcessID(of processID: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let read = proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, &info, Int32(size))
        guard read == Int32(size) else { return nil }
        return pid_t(info.pbi_ppid)
    }
}
