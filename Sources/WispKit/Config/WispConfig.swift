import Foundation

/// User configuration, stored as JSON at `~/.wisp/config.json`.
/// Everything has a sensible default so Wisp boots with no setup.
public struct WispConfig: Codable, Sendable, Equatable {
    public var activeProfileID: String
    public var profiles: [LLMModelProfile]
    /// Speak replies aloud with TTS.
    public var voiceRepliesEnabled: Bool
    /// Keep the companion orb visible when idle (vs. appear only during use).
    public var orbAlwaysVisible: Bool
    /// Token budget for the serialized screen snapshot per turn.
    public var snapshotTokenBudget: Int
    /// Token budget for the memory profile injected into the system prompt.
    public var memoryTokenBudget: Int
    /// Maximum past turns kept verbatim; older turns are compacted.
    public var historyTurnLimit: Int

    public init(
        activeProfileID: String,
        profiles: [LLMModelProfile],
        voiceRepliesEnabled: Bool = true,
        orbAlwaysVisible: Bool = true,
        snapshotTokenBudget: Int = 1200,
        memoryTokenBudget: Int = 500,
        historyTurnLimit: Int = 12
    ) {
        self.activeProfileID = activeProfileID
        self.profiles = profiles
        self.voiceRepliesEnabled = voiceRepliesEnabled
        self.orbAlwaysVisible = orbAlwaysVisible
        self.snapshotTokenBudget = snapshotTokenBudget
        self.memoryTokenBudget = memoryTokenBudget
        self.historyTurnLimit = historyTurnLimit
    }

    public var activeProfile: LLMModelProfile? {
        profiles.first { $0.id == activeProfileID }
    }

    /// Ships with ready-to-fill profiles for the major hosts. The user only
    /// pastes an API key (via `wisp key set <ref>`) and picks a profile.
    public static func makeDefault() -> WispConfig {
        WispConfig(
            activeProfileID: "claude",
            profiles: [
                LLMModelProfile(
                    id: "claude",
                    displayName: "Claude Sonnet",
                    apiStyle: .anthropic,
                    baseURL: URL(string: "https://api.anthropic.com")!,
                    model: "claude-sonnet-5",
                    apiKeyRef: "ANTHROPIC_API_KEY",
                    supportsVision: true
                ),
                LLMModelProfile(
                    id: "glm",
                    displayName: "GLM (Zhipu)",
                    apiStyle: .openaiCompatible,
                    baseURL: URL(string: "https://open.bigmodel.cn/api/paas/v4")!,
                    model: "glm-5.2",
                    apiKeyRef: "ZHIPU_API_KEY",
                    supportsVision: false
                ),
                LLMModelProfile(
                    id: "kimi",
                    displayName: "Kimi (Moonshot)",
                    apiStyle: .openaiCompatible,
                    baseURL: URL(string: "https://api.moonshot.ai/v1")!,
                    model: "kimi-k3",
                    apiKeyRef: "MOONSHOT_API_KEY",
                    supportsVision: false
                ),
                LLMModelProfile(
                    id: "openrouter",
                    displayName: "OpenRouter",
                    apiStyle: .openaiCompatible,
                    baseURL: URL(string: "https://openrouter.ai/api/v1")!,
                    model: "anthropic/claude-sonnet-5",
                    apiKeyRef: "OPENROUTER_API_KEY",
                    supportsVision: true
                ),
                LLMModelProfile(
                    id: "local",
                    displayName: "Local (Ollama)",
                    apiStyle: .openaiCompatible,
                    baseURL: URL(string: "http://localhost:11434/v1")!,
                    model: "qwen3:8b",
                    apiKeyRef: nil,
                    supportsVision: false
                ),
                LLMModelProfile(
                    id: "mock",
                    displayName: "Demo (no API key)",
                    apiStyle: .openaiCompatible,
                    baseURL: URL(string: "http://localhost:0")!,
                    model: "mock",
                    apiKeyRef: nil,
                    supportsVision: false
                ),
            ]
        )
    }
}

/// Loads and saves `WispConfig` at `~/.wisp/config.json`, creating the
/// default on first run.
public struct WispConfigStore: Sendable {
    public let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".wisp")
    }

    public var configURL: URL { directory.appendingPathComponent("config.json") }

    public func load() -> WispConfig {
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(WispConfig.self, from: data)
        else {
            let config = WispConfig.makeDefault()
            try? save(config)
            return config
        }
        return config
    }

    public func save(_ config: WispConfig) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: configURL, options: .atomic)
    }
}
