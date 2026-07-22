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
        let userText: String
        if let snapshotBlock, !snapshotBlock.isEmpty {
            // Snapshot above the words, clearly separated, so the model
            // reads context before the question.
            userText = snapshotBlock + "\n\nUser said: " + transcript
        } else {
            userText = transcript
        }
        var messages = history
        messages.append(ChatMessage(role: .user, text: userText, images: images))
        return LLMChatRequest(
            systemPrompt: SystemPrompt.build(
                memoryProfile: memoryProfile,
                supportsVision: supportsVision,
                screenshotIncluded: !images.isEmpty
            ),
            messages: messages,
            maxOutputTokens: config.activeProfile?.maxOutputTokens ?? 1024,
            temperature: config.activeProfile?.temperature
        )
    }

    /// Keeps the last `turnLimit` turns; strips `<screen>…</screen>` blocks
    /// (full and delta) and images from all but the most recent user turn so
    /// long sessions stay cheap.
    public static func compactHistory(_ messages: [ChatMessage], turnLimit: Int) -> [ChatMessage] {
        var kept = Array(messages.suffix(max(1, turnLimit) * 2))
        let lastUserIndex = kept.lastIndex { $0.role == .user }
        for index in kept.indices where index != lastUserIndex && kept[index].role == .user {
            kept[index].text = stripScreenBlocks(from: kept[index].text)
            kept[index].images = []
        }
        return kept
    }

    /// Removes `<screen …>…</screen>` blocks and tidies leftover whitespace.
    static func stripScreenBlocks(from text: String) -> String {
        var result = text.replacingOccurrences(
            of: "<screen[^>]*>[\\s\\S]*?</screen>",
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "\\n{3,}",
            with: "\n\n",
            options: .regularExpression
        )
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
