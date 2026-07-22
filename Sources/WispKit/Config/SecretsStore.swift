import Foundation
import Security

public enum SecretsStoreError: Error, Sendable, Equatable {
    case keychain(OSStatus)
    case invalidKey
}

/// API keys live in the login Keychain under service "so.wisp.keys",
/// account = the key ref (e.g. "ANTHROPIC_API_KEY"). Environment variables
/// with the same name act as a fallback so CLI usage and CI work without
/// touching the Keychain.
public final class SecretsStore: APIKeyResolving, @unchecked Sendable {
    public let service: String

    public init(service: String = "so.wisp.keys") {
        self.service = service
    }

    public func apiKey(for ref: String) -> String? {
        if let stored = readKeychainItem(account: ref), !stored.isEmpty {
            return stored
        }
        if let fromEnvironment = ProcessInfo.processInfo.environment[ref], !fromEnvironment.isEmpty {
            return fromEnvironment
        }
        return nil
    }

    public func setAPIKey(_ key: String, for ref: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else {
            throw SecretsStoreError.invalidKey
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: ref,
        ]
        let update: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw SecretsStoreError.keychain(addStatus)
            }
        default:
            throw SecretsStoreError.keychain(updateStatus)
        }
    }

    public func deleteAPIKey(for ref: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: ref,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SecretsStoreError.keychain(status)
        }
    }

    /// Refs that currently resolve, for `wisp doctor`.
    public func availableRefs(from profiles: [LLMModelProfile]) -> [String] {
        profiles.compactMap { $0.apiKeyRef }.filter { apiKey(for: $0) != nil }
    }

    private func readKeychainItem(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
