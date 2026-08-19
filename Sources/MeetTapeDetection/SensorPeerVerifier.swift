import AppKit
import Foundation
import MeetTapeCore
import Security

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
    /// What the peer's own code signature says about it.
    public enum SignatureState: Sendable, Equatable {
        /// Signed by the same team as MeetTape, with the relay's identifier.
        case matchesApplication
        /// A code object exists and does not satisfy that requirement.
        case mismatched
        /// No conclusion available: an ad-hoc build has no team to pin, and the
        /// audit token or the code object could not be read.
        case unknown
    }

    public struct Peer: Sendable, Equatable {
        public let processID: pid_t
        public let executablePath: String
        public let parentPath: String?
        public let parentBundleIdentifier: String?
        public let signature: SignatureState

        public init(
            processID: pid_t, executablePath: String,
            parentPath: String?, parentBundleIdentifier: String?,
            signature: SignatureState = .unknown
        ) {
            self.processID = processID
            self.executablePath = executablePath
            self.parentPath = parentPath
            self.parentBundleIdentifier = parentBundleIdentifier
            self.signature = signature
        }
    }

    /// Absolute paths the host binary is allowed to run from.
    public let allowedHostPaths: Set<String>
    /// Bundle identifiers of browsers allowed to be the host's parent.
    public let allowedParentBundleIDs: Set<String>

    /// Resolves a bundle identifier to the application's location. Injected so the
    /// parent check can be tested on a machine without that browser installed.
    private let applicationURL: @Sendable (String) -> URL?

    public init(
        allowedHostPaths: Set<String>? = nil,
        allowedParentBundleIDs: Set<String>? = nil,
        applicationURL: @escaping @Sendable (String) -> URL? = { identifier in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
        }
    ) {
        self.applicationURL = applicationURL
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
            },
            signature: CodeSignatureCheck.state(ofPeerOn: descriptor)
        )
    }

    /// True when the peer is MeetTape's own host binary, launched by a browser.
    ///
    /// The parent check is what makes it meaningful: the host is a relay for
    /// whatever it is fed on standard input, so "it is our binary" alone would
    /// not stop an attacker from running it themselves.
    public func isTrusted(_ peer: Peer) -> Bool {
        guard allowedHostPaths.contains(peer.executablePath) else { return false }
        // The host binary lives in Application Support, which the user can write
        // to, so the path alone does not identify the code running there. On a
        // signed build the peer must carry the same team identifier as MeetTape.
        // An ad-hoc build has no team to compare, and reports .unknown.
        guard peer.signature != .mismatched else { return false }
        // The bundle identifier is the direct answer; the executable path is the
        // fallback for a browser that is running but not registered.
        if let identifier = peer.parentBundleIdentifier,
           allowedParentBundleIDs.contains(identifier) {
            return true
        }
        guard let parentPath = peer.parentPath else { return false }
        return allowedParentBundleIDs.contains { identifier in
            guard let bundle = applicationURL(identifier) else { return false }
            // The path of the bundle itself, with a separator, so that a sibling
            // in the same folder cannot pass as the browser.
            return parentPath.hasPrefix(bundle.path + "/")
        }
    }

    /// Why a peer was refused, for the log and the permissions pane.
    public func rejectionReason(_ peer: Peer) -> String {
        if !allowedHostPaths.contains(peer.executablePath) {
            return "the connecting process is not MeetTape's relay"
        }
        if peer.signature == .mismatched {
            return "the relay is not signed by the team that signed MeetTape"
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

/// Reads the code signature of the process on the other end of a socket.
///
/// The relay lives in a directory the user can write to, so file permissions do
/// not establish what code is running there. A Developer ID build can require the
/// peer to carry MeetTape's own team identifier, which a replaced binary cannot
/// produce. An ad-hoc build has no team identifier, so this reports `.unknown`
/// and the path and parent checks stand alone.
enum CodeSignatureCheck {
    /// `LOCAL_PEERTOKEN` from `sys/un.h`, which Swift does not import.
    private static let localPeerToken: Int32 = 0x006

    static func state(ofPeerOn descriptor: Int32) -> SensorPeerVerifier.SignatureState {
        guard let team = ownTeamIdentifier() else { return .unknown }
        guard let token = auditToken(of: descriptor) else { return .unknown }
        guard let code = guest(for: token) else { return .unknown }

        let text = "identifier \"com.meettape.nativehost\""
            + " and anchor apple generic"
            + " and certificate leaf[subject.OU] = \"\(team)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let requirement
        else { return .unknown }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
            ? .matchesApplication : .mismatched
    }

    /// Nil for an ad-hoc signature, which carries no team.
    private static func ownTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode
        else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information
        ) == errSecSuccess else { return nil }
        let dictionary = information as? [String: Any]
        let team = dictionary?[kSecCodeInfoTeamIdentifier as String] as? String
        return team?.isEmpty == false ? team : nil
    }

    private static func auditToken(of descriptor: Int32) -> audit_token_t? {
        var token = audit_token_t()
        var size = socklen_t(MemoryLayout<audit_token_t>.size)
        let read = withUnsafeMutablePointer(to: &token) { pointer in
            getsockopt(descriptor, SOL_LOCAL, localPeerToken, pointer, &size)
        }
        guard read == 0, size == socklen_t(MemoryLayout<audit_token_t>.size) else { return nil }
        return token
    }

    private static func guest(for token: audit_token_t) -> SecCode? {
        var value = token
        let data = Data(bytes: &value, count: MemoryLayout<audit_token_t>.size)
        let attributes = [kSecGuestAttributeAudit: data] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess else {
            return nil
        }
        return code
    }
}
