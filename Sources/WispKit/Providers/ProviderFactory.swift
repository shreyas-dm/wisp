import Foundation

/// Creates the right `LLMProvider` for a profile.
public enum ProviderFactory {
    public static func makeProvider(profile: LLMModelProfile, keyResolver: APIKeyResolving) -> LLMProvider {
        if profile.model == "mock" {
            return MockProvider(profile: profile)
        }
        switch profile.apiStyle {
        case .anthropic:
            return AnthropicProvider(profile: profile, keyResolver: keyResolver)
        case .openaiCompatible:
            return OpenAICompatibleProvider(profile: profile, keyResolver: keyResolver)
        }
    }
}

/// Anthropic Messages API (`POST {base}/v1/messages`) with SSE streaming.
/// Sends `system` top-level, images as base64 content blocks, and reads
/// `content_block_delta` text events.
public final class AnthropicProvider: LLMProvider {
    public let profile: LLMModelProfile
    let keyResolver: APIKeyResolving

    public init(profile: LLMModelProfile, keyResolver: APIKeyResolving) {
        self.profile = profile
        self.keyResolver = keyResolver
    }

    public func streamChat(_ request: LLMChatRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        // TODO(fork-providers): implement.
        AsyncThrowingStream { $0.finish(throwing: LLMProviderError.network("not implemented")) }
    }
}

/// OpenAI-compatible Chat Completions (`POST {base}/chat/completions`,
/// `stream: true`). Covers OpenAI, Ollama, vLLM, LM Studio, OpenRouter,
/// Groq, Zhipu GLM, Moonshot Kimi, DeepSeek.
public final class OpenAICompatibleProvider: LLMProvider {
    public let profile: LLMModelProfile
    let keyResolver: APIKeyResolving

    public init(profile: LLMModelProfile, keyResolver: APIKeyResolving) {
        self.profile = profile
        self.keyResolver = keyResolver
    }

    public func streamChat(_ request: LLMChatRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        // TODO(fork-providers): implement.
        AsyncThrowingStream { $0.finish(throwing: LLMProviderError.network("not implemented")) }
    }
}

/// Key-free demo provider: streams canned, situation-aware replies with
/// realistic pacing so the entire experience (bubble, TTS, pointing) can be
/// exercised before any API key exists. Uses the snapshot block in the last
/// user message to pick a plausible element to point at.
public final class MockProvider: LLMProvider {
    public let profile: LLMModelProfile

    public init(profile: LLMModelProfile) {
        self.profile = profile
    }

    public func streamChat(_ request: LLMChatRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        // TODO(fork-providers): implement.
        AsyncThrowingStream { $0.finish(throwing: LLMProviderError.network("not implemented")) }
    }
}
