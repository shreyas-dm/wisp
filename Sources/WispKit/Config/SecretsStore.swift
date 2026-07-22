import Foundation
import Security

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
        // TODO(fork-voice-memory): Keychain lookup, then env fallback.
        ProcessInfo.processInfo.environment[ref]
    }

    public func setAPIKey(_ key: String, for ref: String) throws {
        // TODO(fork-voice-memory): implement Keychain write.
    }

    public func deleteAPIKey(for ref: String) throws {
        // TODO(fork-voice-memory): implement Keychain delete.
    }

    /// Refs that currently resolve, for `wisp doctor`.
    public func availableRefs(from profiles: [LLMModelProfile]) -> [String] {
        profiles.compactMap { $0.apiKeyRef }.filter { apiKey(for: $0) != nil }
    }
}
