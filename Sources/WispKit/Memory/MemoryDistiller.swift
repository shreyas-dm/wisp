import Foundation

/// Post-session continual learning: after a conversation ends, ask the
/// active model to extract durable user facts from the transcript and fold
/// them into the memory store (deduplicating against existing facts).
/// Skipped silently when no provider is reachable — [[remember:]] tags
/// still capture facts inline during the session.
public final class MemoryDistiller: @unchecked Sendable {
    let store: MemoryStore

    public init(store: MemoryStore) {
        self.store = store
    }

    public func distill(messages: [ChatMessage], using provider: LLMProvider) async {
        // TODO(fork-voice-memory): implement — small non-streamed request,
        // parse one fact per line, dedupe, append with source "distilled".
    }
}
