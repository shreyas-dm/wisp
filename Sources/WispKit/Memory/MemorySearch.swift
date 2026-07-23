import Foundation

/// A scored hit from local memory search.
public struct MemorySearchHit: Equatable, Sendable {
    public enum Source: String, Sendable {
        case fact
        case session
        case activity
    }

    public var source: Source
    /// Human-readable snippet (a fact line, a session exchange, an
    /// activity summary line) — what gets injected back into the prompt.
    public var snippet: String
    /// When the underlying content was written.
    public var date: Date?
    public var score: Double

    public init(source: Source, snippet: String, date: Date?, score: Double) {
        self.source = source
        self.snippet = snippet
        self.date = date
        self.score = score
    }
}

/// Local, dependency-free search over everything Wisp remembers: facts,
/// session transcripts, and the activity log. TF-scored with recency
/// boost — good enough to answer "what was I doing yesterday" without any
/// embeddings or network. Powers the `[[recall:…]]` tag and
/// `wisp memory search`.
public struct MemorySearch: Sendable {
    let store: MemoryStore

    public init(store: MemoryStore) {
        self.store = store
    }

    /// Case-insensitive tokenized search; returns the best `limit` hits,
    /// newest-first among equal scores. Total snippet budget ~`tokenBudget`
    /// estimated tokens.
    public func search(query: String, limit: Int = 6, tokenBudget: Int = 700) -> [MemorySearchHit] {
        // TODO(fork-core): implement.
        []
    }

    /// Renders hits as the block injected into the recall re-prompt.
    public static func renderHits(_ hits: [MemorySearchHit], query: String) -> String {
        // TODO(fork-core): implement.
        hits.map { "- \($0.snippet)" }.joined(separator: "\n")
    }
}
