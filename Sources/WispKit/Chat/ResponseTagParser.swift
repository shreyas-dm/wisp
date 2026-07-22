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
/// tags. Robust to tags split across arbitrary delta boundaries
/// (e.g. "[[po" + "int:e4]]"); never holds back plain text longer than
/// necessary (only a pending "[["-candidate tail is buffered). Malformed or
/// unknown tags are emitted verbatim as text. An unterminated tag candidate
/// longer than `maxTagContentLength` is released as literal text so a stray
/// "[[" cannot hold the stream hostage.
public struct ResponseTagParser: Sendable {
    private var pending = ""
    private let maxTagContentLength = 200

    public init() {}

    /// Feed a streamed delta; returns chunks that became unambiguous.
    public mutating func consume(_ delta: String) -> [ResponseChunk] {
        var chunks: [ResponseChunk] = []
        var work = pending + delta
        pending = ""

        while !work.isEmpty {
            guard let openRange = work.range(of: "[[") else {
                // No tag opener. Hold back a single trailing "[" — the next
                // delta could turn it into "[[".
                if work.hasSuffix("[") {
                    let safeEnd = work.index(before: work.endIndex)
                    appendText(String(work[..<safeEnd]), to: &chunks)
                    pending = "["
                } else {
                    appendText(work, to: &chunks)
                }
                break
            }

            appendText(String(work[..<openRange.lowerBound]), to: &chunks)
            let rest = String(work[openRange.lowerBound...])

            if let closeRange = rest.range(of: "]]") {
                let innerStart = rest.index(rest.startIndex, offsetBy: 2)
                let inner = String(rest[innerStart..<closeRange.lowerBound])
                if inner.contains("[[") || inner.count > maxTagContentLength {
                    // The candidate swallowed a nested "[[" (or is absurdly
                    // long) — this "[[" is literal text; rescan after it so
                    // the nested tag still parses.
                    appendText("[[", to: &chunks)
                    work = String(rest.dropFirst(2))
                    continue
                }
                if let tag = Self.parseTag(inner) {
                    chunks.append(.tag(tag))
                } else {
                    appendText(String(rest[..<closeRange.upperBound]), to: &chunks)
                }
                work = String(rest[closeRange.upperBound...])
            } else if rest.count > maxTagContentLength + 4 {
                // Overlong unterminated candidate: release the "[[" as text
                // and rescan the remainder (it may contain a real tag).
                appendText("[[", to: &chunks)
                work = String(rest.dropFirst(2))
            } else {
                pending = rest
                break
            }
        }
        return chunks
    }

    /// Flush any buffered tail at end of stream.
    public mutating func finish() -> [ResponseChunk] {
        defer { pending = "" }
        return pending.isEmpty ? [] : [.text(pending)]
    }

    private func appendText(_ text: String, to chunks: inout [ResponseChunk]) {
        guard !text.isEmpty else { return }
        if case .text(let existing)? = chunks.last {
            chunks[chunks.count - 1] = .text(existing + text)
        } else {
            chunks.append(.text(text))
        }
    }

    static func parseTag(_ inner: String) -> ResponseTag? {
        if inner == "screenshot" {
            return .screenshotRequest
        }
        if inner.hasPrefix("point:") {
            let payload = String(inner.dropFirst("point:".count)).trimmingCharacters(in: .whitespaces)
            if payload.range(of: "^e\\d+$", options: .regularExpression) != nil {
                return .point(elementID: payload)
            }
            let parts = payload.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 || parts.count == 3,
               let x = Double(parts[0]),
               let y = Double(parts[1]) {
                let displayIndex = parts.count == 3 ? (Int(parts[2]) ?? 0) : 0
                return .pointCoordinate(x: x, y: y, displayIndex: displayIndex)
            }
            return nil
        }
        if inner.hasPrefix("remember:") {
            let fact = String(inner.dropFirst("remember:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return fact.isEmpty ? nil : .remember(fact: fact)
        }
        return nil
    }
}
