import Foundation
import MeetTapeCore
import Security

/// The OpenAI API key, stored in the login keychain.
///
/// It never reaches preferences, meeting files, logs or crash reports. The
/// accessor reads it per request rather than caching it, so a revoked key stops
/// working immediately.
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

    public var hasKey: Bool { read()?.isEmpty == false }

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
}
