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
