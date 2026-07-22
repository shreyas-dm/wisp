import Foundation

/// Assembles the request for a turn: system prompt (with memory), compacted
/// history, and the user's transcript with its screen-context block.
public struct PromptBuilder: Sendable {
    public var config: WispConfig

    public init(config: WispConfig) {
        self.config = config
    }

    /// - Parameters:
    ///   - snapshotBlock: serialized `<screen>` block (full or delta) for
    ///     this turn; nil when screen context was unavailable.
    ///   - history: prior turns, already compacted.
    ///   - images: screenshot attachments for the vision fallback re-send.
    public func buildRequest(
        transcript: String,
        snapshotBlock: String?,
        history: [ChatMessage],
        memoryProfile: String?,
        supportsVision: Bool,
        images: [AttachedImage] = []
    ) -> LLMChatRequest {
        // TODO(fork-providers): implement (transcript + snapshot composition).
        let userText = [snapshotBlock, transcript].compactMap { $0 }.joined(separator: "\n\n")
        var messages = history
        messages.append(ChatMessage(role: .user, text: userText, images: images))
        return LLMChatRequest(
            systemPrompt: SystemPrompt.build(memoryProfile: memoryProfile, supportsVision: supportsVision),
            messages: messages,
            maxOutputTokens: config.activeProfile?.maxOutputTokens ?? 1024,
            temperature: config.activeProfile?.temperature
        )
    }

    /// Keeps the last `turnLimit` turns; strips `<screen>…</screen>` blocks
    /// and images from all but the most recent user turn so long sessions
    /// stay cheap.
    public static func compactHistory(_ messages: [ChatMessage], turnLimit: Int) -> [ChatMessage] {
        // TODO(fork-providers): implement.
        return Array(messages.suffix(turnLimit * 2))
    }
}
