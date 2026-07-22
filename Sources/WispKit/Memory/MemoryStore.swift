import Foundation

public struct MemoryFact: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var text: String
    /// Where the fact came from: "model" (a [[remember:]] tag), "distilled"
    /// (post-session summarization), or "user" (edited by hand).
    public var source: String
    public var createdAt: Date

    public init(id: String = UUID().uuidString, text: String, source: String, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.source = source
        self.createdAt = createdAt
    }
}

/// Wisp's continual-learning store. Facts live in plain Markdown at
/// `~/.wisp/memory/facts.md` (one `- fact  <!--meta-->` line each) so the
/// user can read and edit them; session transcripts go to
/// `~/.wisp/memory/sessions/`. Nothing ever leaves the machine except
/// inside prompts.
public final class MemoryStore: @unchecked Sendable {
    public let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".wisp/memory")
    }

    public func appendFact(_ text: String, source: String) throws {
        // TODO(fork-voice-memory): implement.
    }

    public func allFacts() -> [MemoryFact] {
        // TODO(fork-voice-memory): implement.
        return []
    }

    public func deleteFact(id: String) throws {
        // TODO(fork-voice-memory): implement.
    }

    /// Token-budgeted digest injected into the system prompt: newest facts
    /// first, deduplicated, trimmed to fit.
    public func profile(tokenBudget: Int) -> String? {
        // TODO(fork-voice-memory): implement.
        return nil
    }

    /// Appends a finished conversation to the session log for later
    /// distillation.
    public func recordSession(messages: [ChatMessage]) throws {
        // TODO(fork-voice-memory): implement.
    }
}
