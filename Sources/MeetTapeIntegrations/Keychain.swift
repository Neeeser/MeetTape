import Foundation
import MeetTapeCore
import Security

/// The OpenAI API key, stored in the login keychain.
///
/// It never reaches preferences, meeting files, logs or crash reports.
///
/// This accessor reads the keychain every time it is asked. What the running
/// application uses is this wrapped in `CachingAPIKeyStore`, which reads once
/// per process: an uncached read raises a login-keychain prompt on any build the
/// item's access control does not trust, and there was one read per API request.
public struct KeychainAPIKeyStore: APIKeyProviding, Sendable {
    public let service: String
    public let account: String

    public init(service: String = "com.meettape.app.openai", account: String = "api-key") {
        self.service = service
        self.account = account
    }

    public func apiKey() throws -> String {
        guard let key = read(), !key.isEmpty else { throw ProcessingError.missingAPIKey }
        return key
    }

    /// Whether an item is stored, asked without requesting its value.
    ///
    /// The secret is never brought into the process to answer a yes/no. This
    /// still blocks on the authorisation prompt when the item's ACL does not
    /// trust the caller: a login-keychain item enforces its ACL on the search
    /// as well as on the read, so no query answers this without possibly
    /// waiting for a person. Callers must not be holding the main actor.
    public var hasKey: Bool {
        var result: CFTypeRef?
        return SecItemCopyMatching(query(returningData: false) as CFDictionary, &result)
            == errSecSuccess
    }

    /// Whether the keychain positively says there is no key.
    ///
    /// A read can fail for reasons that are not absence: a locked login
    /// keychain, or a denied prompt after an ad-hoc rebuild invalidates the
    /// item's ACL. Treating those as absence made the optional cloud stages skip
    /// silently and the meeting complete with no title and no summary and
    /// nothing on screen saying why. Only errSecItemNotFound is absence.
    public var isKnownAbsent: Bool {
        var result: CFTypeRef?
        return SecItemCopyMatching(query(returningData: false) as CFDictionary, &result)
            == errSecItemNotFound
    }

    private func query(returningData: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if returningData { query[kSecReturnData as String] = true }
        return query
    }

    public func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public func save(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return delete() }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(trimmed.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemDelete(query as CFDictionary)
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    public func delete() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Masks a key for display. Only ever shows the shape, never the secret.
    public static func masked(_ key: String) -> String {
        guard key.count > 8 else { return String(repeating: "•", count: max(key.count, 4)) }
        return "\(key.prefix(3))\(String(repeating: "•", count: 8))\(key.suffix(4))"
    }
}

/// Holds the key in memory after the first successful read.
///
/// The keychain is asked once per process instead of once per request. macOS
/// raises a login-keychain password prompt whenever the running binary is not
/// the one that created the item, which every unsigned rebuild produces, and a
/// per-request read turned that into a prompt for every call: enrichment alone
/// makes one per title, description, notes, summary and speaker pass, so a
/// single resumed meeting asked five times.
///
/// The secret is in process memory for the life of the process, which is the
/// trade being made. Two things still take it back: rotating the key writes
/// through this cache, and a request the API refuses drops it, so the next read
/// returns to the keychain rather than reusing a key that no longer works.
public final class CachingAPIKeyStore: APIKeyProviding, @unchecked Sendable {
    private let underlying: any APIKeyProviding
    private let lock = NSLock()
    private var cached: String?

    public init(_ underlying: any APIKeyProviding) {
        self.underlying = underlying
    }

    public func apiKey() throws -> String {
        lock.lock()
        let held = cached
        lock.unlock()
        if let held { return held }

        // Outside the lock: this call can block until a person answers a
        // keychain prompt, and holding the lock across it would stall every
        // other request behind it for as long as the dialog is up.
        let key = try underlying.apiKey()
        lock.lock()
        cached = key
        lock.unlock()
        return key
    }

    /// A key already in hand is proof there is one, without asking the keychain
    /// and without risking the prompt.
    public var isKnownAbsent: Bool {
        lock.lock()
        let held = cached
        lock.unlock()
        if held != nil { return false }
        return underlying.isKnownAbsent
    }

    public func invalidateCachedKey() {
        lock.lock()
        cached = nil
        lock.unlock()
        underlying.invalidateCachedKey()
    }

    /// Adopts a key that has just been written, so rotating one does not need a
    /// relaunch and does not raise a second prompt to read back what was just
    /// saved.
    public func adopt(_ key: String) {
        lock.lock()
        cached = key.isEmpty ? nil : key
        lock.unlock()
    }
}

/// An in-memory key source for tests and for the opt-in live integration run.
public struct EnvironmentAPIKeyStore: APIKeyProviding, Sendable {
    public let variableName: String

    public init(variableName: String = "OPENAI_API_KEY") {
        self.variableName = variableName
    }

    public func apiKey() throws -> String {
        guard let value = ProcessInfo.processInfo.environment[variableName], !value.isEmpty else {
            throw ProcessingError.missingAPIKey
        }
        return value
    }

    /// An absent or empty variable is absence, not a failure to read.
    public var isKnownAbsent: Bool {
        (ProcessInfo.processInfo.environment[variableName] ?? "").isEmpty
    }
}

/// Prefers the keychain and falls back to the environment, which is how the
/// opt-in live tests run without ever writing a key to disk.
public struct LayeredAPIKeyStore: APIKeyProviding, Sendable {
    private let providers: [any APIKeyProviding]

    public init(providers: [any APIKeyProviding]) {
        self.providers = providers
    }

    public func apiKey() throws -> String {
        for provider in providers {
            if let key = try? provider.apiKey(), !key.isEmpty { return key }
        }
        throw ProcessingError.missingAPIKey
    }

    /// Only when every layer says so. Taking the protocol default here made
    /// this store answer "cannot say" for a machine with no key at all, which
    /// is the store DEBUG builds use: the optional cloud stages then attempted
    /// a request, failed unretryably, and the meeting stopped before the step
    /// that writes the markdown and the mixdown.
    public var isKnownAbsent: Bool { providers.allSatisfy(\.isKnownAbsent) }

    public func invalidateCachedKey() {
        for provider in providers { provider.invalidateCachedKey() }
    }
}
