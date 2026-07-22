import Foundation

/// Post-session continual learning: after a conversation ends, ask the
/// active model to extract durable user facts from the transcript and fold
/// them into the memory store. Skipped silently when the provider is
/// unreachable — `[[remember:]]` tags still capture facts inline during the
/// session, so distillation is a bonus, never a requirement.
public final class MemoryDistiller: @unchecked Sendable {
    let store: MemoryStore

    /// Keep the transcript sent for distillation small — this is a
    /// housekeeping call, not a conversation.
    private let transcriptTokenCap = 4000

    public init(store: MemoryStore) {
        self.store = store
    }

    public func distill(messages: [ChatMessage], using provider: LLMProvider) async {
        var transcript = messages
            .map { message -> String in
                let speaker = message.role == .user ? "user" : "assistant"
                let cleaned = MemoryStore.stripScreenBlocks(message.text)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return "\(speaker): \(cleaned)"
            }
            .filter { !$0.hasSuffix(": ") }
            .joined(separator: "\n")

        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // Cap from the front — the end of the conversation is the part most
        // likely to contain corrections and conclusions.
        let characterCap = transcriptTokenCap * 4
        if transcript.count > characterCap {
            transcript = String(transcript.suffix(characterCap))
        }

        let request = LLMChatRequest(
            systemPrompt: """
            Extract durable facts about the user from this conversation. \
            Output one short factual sentence per line, no bullets, only \
            facts worth remembering across sessions (identity, preferences, \
            skill level, tools, projects). Output NOTHING if there are none.
            """,
            messages: [ChatMessage(role: .user, text: transcript)],
            maxOutputTokens: 300,
            temperature: 0
        )

        var reply = ""
        do {
            for try await event in provider.streamChat(request) {
                if case .textDelta(let delta) = event {
                    reply += delta
                }
            }
        } catch {
            return  // Offline or misconfigured — completely fine.
        }

        for line in reply.components(separatedBy: "\n") {
            var fact = line.trimmingCharacters(in: .whitespacesAndNewlines)
            // Tolerate models that bullet anyway.
            if fact.hasPrefix("- ") { fact = String(fact.dropFirst(2)) }
            if fact.hasPrefix("• ") { fact = String(fact.dropFirst(2)) }
            guard !fact.isEmpty, fact.count <= 200 else { continue }
            try? store.appendFact(fact, source: "distilled")
        }
    }
}
