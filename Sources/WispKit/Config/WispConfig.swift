import Foundation

/// What screen context each turn carries.
public enum ScreenContextMode: String, Codable, Sendable, CaseIterable {
    /// Semantic snapshot + downscaled screenshot every turn (default —
    /// maximum reliability; requires a vision-capable profile for the
    /// screenshot part, otherwise degrades to `structure`).
    case hybrid
    /// Snapshot always; screenshot only when the accessibility tree looks
    /// sparse (canvas apps, video, games).
    case auto
    /// Semantic snapshot only — cheapest, works with any model.
    case structure
    /// Screenshot only.
    case screenshot
}

/// Which STT/TTS engine to use. `.auto` picks ElevenLabs when its API key
/// resolves, falling back to the local Apple engines.
public enum VoiceEngineChoice: String, Codable, Sendable, CaseIterable {
    case auto
    case apple
    case elevenlabs
}

/// User configuration, stored as JSON at `~/.wisp/config.json`.
/// Everything has a sensible default so Wisp boots with no setup. Unknown
/// keys in the file are ignored; missing keys take defaults, so configs
/// survive upgrades in both directions.
public struct WispConfig: Codable, Sendable, Equatable {
    public var activeProfileID: String
    public var profiles: [LLMModelProfile]
    /// Speak replies aloud with TTS.
    public var voiceRepliesEnabled: Bool
    /// Keep the companion orb visible when idle (vs. appear only during use).
    public var orbAlwaysVisible: Bool
    /// Screen context sent with each turn.
    public var screenContextMode: ScreenContextMode
    /// Longest side of the screenshot sent to vision models, in pixels.
    public var screenshotMaxDimension: Int
    /// Token budget for the serialized screen snapshot per turn.
    public var snapshotTokenBudget: Int
    /// Token budget for the memory profile injected into the system prompt.
    public var memoryTokenBudget: Int
    /// Maximum past turns kept verbatim; older turns are compacted.
    public var historyTurnLimit: Int
    /// Speech-to-text engine selection.
    public var sttEngine: VoiceEngineChoice
    /// Text-to-speech engine selection.
    public var ttsEngine: VoiceEngineChoice
    /// ElevenLabs voice used for TTS.
    public var elevenLabsVoiceID: String
    /// ElevenLabs model ids.
    public var elevenLabsTTSModel: String
    public var elevenLabsSTTModel: String

    public init(
        activeProfileID: String,
        profiles: [LLMModelProfile],
        voiceRepliesEnabled: Bool = true,
        orbAlwaysVisible: Bool = true,
        screenContextMode: ScreenContextMode = .hybrid,
        screenshotMaxDimension: Int = 1024,
        snapshotTokenBudget: Int = 1200,
        memoryTokenBudget: Int = 500,
        historyTurnLimit: Int = 12,
        sttEngine: VoiceEngineChoice = .auto,
        ttsEngine: VoiceEngineChoice = .auto,
        elevenLabsVoiceID: String = "21m00Tcm4TlvDq8ikWAM",
        elevenLabsTTSModel: String = "eleven_flash_v2_5",
        elevenLabsSTTModel: String = "scribe_v1"
    ) {
        self.activeProfileID = activeProfileID
        self.profiles = profiles
        self.voiceRepliesEnabled = voiceRepliesEnabled
        self.orbAlwaysVisible = orbAlwaysVisible
        self.screenContextMode = screenContextMode
        self.screenshotMaxDimension = screenshotMaxDimension
        self.snapshotTokenBudget = snapshotTokenBudget
        self.memoryTokenBudget = memoryTokenBudget
        self.historyTurnLimit = historyTurnLimit
        self.sttEngine = sttEngine
        self.ttsEngine = ttsEngine
        self.elevenLabsVoiceID = elevenLabsVoiceID
        self.elevenLabsTTSModel = elevenLabsTTSModel
        self.elevenLabsSTTModel = elevenLabsSTTModel
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = WispConfig(activeProfileID: "", profiles: [])
        activeProfileID = try container.decode(String.self, forKey: .activeProfileID)
        profiles = try container.decode([LLMModelProfile].self, forKey: .profiles)
        voiceRepliesEnabled = try container.decodeIfPresent(Bool.self, forKey: .voiceRepliesEnabled) ?? defaults.voiceRepliesEnabled
        orbAlwaysVisible = try container.decodeIfPresent(Bool.self, forKey: .orbAlwaysVisible) ?? defaults.orbAlwaysVisible
        screenContextMode = try container.decodeIfPresent(ScreenContextMode.self, forKey: .screenContextMode) ?? defaults.screenContextMode
        screenshotMaxDimension = try container.decodeIfPresent(Int.self, forKey: .screenshotMaxDimension) ?? defaults.screenshotMaxDimension
        snapshotTokenBudget = try container.decodeIfPresent(Int.self, forKey: .snapshotTokenBudget) ?? defaults.snapshotTokenBudget
        memoryTokenBudget = try container.decodeIfPresent(Int.self, forKey: .memoryTokenBudget) ?? defaults.memoryTokenBudget
        historyTurnLimit = try container.decodeIfPresent(Int.self, forKey: .historyTurnLimit) ?? defaults.historyTurnLimit
        sttEngine = try container.decodeIfPresent(VoiceEngineChoice.self, forKey: .sttEngine) ?? defaults.sttEngine
        ttsEngine = try container.decodeIfPresent(VoiceEngineChoice.self, forKey: .ttsEngine) ?? defaults.ttsEngine
        elevenLabsVoiceID = try container.decodeIfPresent(String.self, forKey: .elevenLabsVoiceID) ?? defaults.elevenLabsVoiceID
        elevenLabsTTSModel = try container.decodeIfPresent(String.self, forKey: .elevenLabsTTSModel) ?? defaults.elevenLabsTTSModel
        elevenLabsSTTModel = try container.decodeIfPresent(String.self, forKey: .elevenLabsSTTModel) ?? defaults.elevenLabsSTTModel
    }

    public var activeProfile: LLMModelProfile? {
        profiles.first { $0.id == activeProfileID }
    }

    /// The screen-context mode that is actually usable with a profile:
    /// screenshot-carrying modes require vision support.
    public func effectiveScreenContextMode(for profile: LLMModelProfile?) -> ScreenContextMode {
        guard let profile, !profile.supportsVision else { return screenContextMode }
        switch screenContextMode {
        case .hybrid, .auto, .screenshot: return .structure
        case .structure: return .structure
        }
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
