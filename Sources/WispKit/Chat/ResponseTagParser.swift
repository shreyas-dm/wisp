import Foundation

/// Tags the model can embed in its reply. See `SystemPrompt` for the
/// contract the model is taught.
public enum ResponseTag: Equatable, Sendable {
    /// `[[point:e12]]` — point at a snapshot element by ID.
    case point(elementID: String)
    /// `[[point:640,360,0]]` — rare raw-coordinate fallback (x, y, display).
    case pointCoordinate(x: Double, y: Double, displayIndex: Int)
    /// `[[screenshot]]` — the model wants a screenshot re-send.
    case screenshotRequest
    /// `[[remember:fact]]` — durable fact for the memory store.
    case remember(fact: String)
}

public enum ResponseChunk: Equatable, Sendable {
    case text(String)
    case tag(ResponseTag)
}

/// Incremental parser that splits a streamed reply into displayable text and
/// tags. Must be robust to tags split across arbitrary delta boundaries
/// (e.g. "[[po" + "int:e4]]"), and must never hold back plain text longer
/// than necessary (buffer only when a prefix of "[[" is pending). Unknown or
/// malformed tags are emitted verbatim as text.
public struct ResponseTagParser: Sendable {
    public init() {}

    /// Feed a streamed delta; returns chunks that became unambiguous.
    public mutating func consume(_ delta: String) -> [ResponseChunk] {
        // TODO(fork-providers): implement streaming-safe parsing.
        return [.text(delta)]
    }

    /// Flush any buffered tail at end of stream.
    public mutating func finish() -> [ResponseChunk] {
        return []
    }
}
