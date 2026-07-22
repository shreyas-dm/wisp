import Foundation

/// Which wire protocol a model endpoint speaks.
public enum LLMAPIStyle: String, Codable, Sendable {
    /// Anthropic Messages API (`/v1/messages`).
    case anthropic
    /// OpenAI-compatible Chat Completions (`/chat/completions`) — covers
    /// OpenAI, Ollama, vLLM, LM Studio, OpenRouter, Groq, Zhipu GLM,
    /// Moonshot Kimi, DeepSeek, and most other open-model hosts.
    case openaiCompatible = "openai"
}

/// One configured model profile the user can pick from the menu bar.
public struct LLMModelProfile: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var displayName: String
    public var apiStyle: LLMAPIStyle
    /// Base URL of the API host, e.g. `https://api.anthropic.com`,
    /// `https://api.moonshot.ai/v1`, `http://localhost:11434/v1`.
    public var baseURL: URL
    /// Model identifier sent on the wire, e.g. `claude-sonnet-5`, `glm-5.2`, `kimi-k3`.
    public var model: String
    /// Name of the secret holding the API key (Keychain item or environment
    /// variable). `nil` for endpoints that need no key (local servers).
    public var apiKeyRef: String?
    /// Whether the endpoint accepts image content parts. Gates the
    /// screenshot-fallback tool.
    public var supportsVision: Bool
    public var maxOutputTokens: Int
    public var temperature: Double?

    public init(
        id: String,
        displayName: String,
        apiStyle: LLMAPIStyle,
        baseURL: URL,
        model: String,
        apiKeyRef: String? = nil,
        supportsVision: Bool = false,
        maxOutputTokens: Int = 1024,
        temperature: Double? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.apiStyle = apiStyle
        self.baseURL = baseURL
        self.model = model
        self.apiKeyRef = apiKeyRef
        self.supportsVision = supportsVision
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
    }
}

/// Streamed events from a provider.
public enum LLMStreamEvent: Sendable, Equatable {
    case textDelta(String)
    /// Terminal event. Usage is reported when the API provides it.
    case done(LLMUsage?)
}

public struct LLMUsage: Sendable, Equatable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public init(inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public enum LLMProviderError: Error, Sendable, Equatable {
    case missingAPIKey(ref: String)
    case httpError(status: Int, body: String)
    case malformedResponse(String)
    case network(String)
    case cancelled
}

/// A chat backend. Implementations must be safe to call from any actor and
/// must deliver `.done` exactly once on success.
public protocol LLMProvider: Sendable {
    var profile: LLMModelProfile { get }
    /// Streams the assistant's reply. Throwing terminates the stream.
    func streamChat(_ request: LLMChatRequest) -> AsyncThrowingStream<LLMStreamEvent, Error>
}

/// Resolves an API key for a profile. Implemented by `SecretsStore` in the
/// app; injected so providers stay testable.
public protocol APIKeyResolving: Sendable {
    /// Returns the key for `ref`, or nil if not stored yet.
    func apiKey(for ref: String) -> String?
}
