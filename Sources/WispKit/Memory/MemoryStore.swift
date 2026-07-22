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
/// `~/.wisp/memory/facts.md` — one line each:
///
///     - The user prefers Vim keybindings.  <!-- id:1a2b3c4d src:model at:2026-07-23T10:00:00Z -->
///
/// so the user can read and edit them freely; lines added by hand (without
/// the metadata comment) are picked up as facts too. Session transcripts go
/// to `~/.wisp/memory/sessions/`. Nothing ever leaves the machine except
/// inside prompts.
public final class MemoryStore: @unchecked Sendable {
    public let directory: URL

    private let fileLock = NSLock()
    private static let fileHeader = "# Wisp memory\n\nFacts Wisp has learned. Edit freely — one `- fact` per line.\n\n"

    public init(directory: URL? = nil) {
        self.directory = directory
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".wisp/memory")
    }

    public var factsURL: URL { directory.appendingPathComponent("facts.md") }
    public var sessionsDirectory: URL { directory.appendingPathComponent("sessions") }

    public func appendFact(_ text: String, source: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        fileLock.lock()
        defer { fileLock.unlock() }

        let existingFacts = parseFacts(from: readFactsFile())
        let isDuplicate = existingFacts.contains {
            $0.text.lowercased() == trimmed.lowercased()
        }
        if isDuplicate { return }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let shortID = String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8))
        let line = "- \(trimmed)  <!-- id:\(shortID) src:\(source) at:\(timestamp) -->\n"

        var content = readFactsFile() ?? Self.fileHeader
        if !content.hasSuffix("\n") { content += "\n" }
        content += line
        try writeFactsFile(content)
    }

    public func allFacts() -> [MemoryFact] {
        fileLock.lock()
        defer { fileLock.unlock() }
        return parseFacts(from: readFactsFile())
    }

    public func deleteFact(id: String) throws {
        fileLock.lock()
        defer { fileLock.unlock() }

        guard let content = readFactsFile() else { return }
        let keptLines = content.components(separatedBy: "\n").filter { line in
            guard let fact = Self.parseFactLine(line) else { return true }
            return fact.id != id
        }
        try writeFactsFile(keptLines.joined(separator: "\n"))
    }

    /// Token-budgeted digest injected into the system prompt: newest facts
    /// first, trimmed to fit.
    public func profile(tokenBudget: Int) -> String? {
        let facts = allFacts().sorted { $0.createdAt > $1.createdAt }
        guard !facts.isEmpty else { return nil }

        var lines: [String] = []
        var spentTokens = 0
        for fact in facts {
            let line = "- \(fact.text)"
            let cost = TokenEstimator.estimate(line)
            if spentTokens + cost > tokenBudget { break }
            lines.append(line)
            spentTokens += cost
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Appends a finished conversation to today's session log for later
    /// distillation. Screen blocks and images are stripped — only the
    /// spoken conversation is kept.
    public func recordSession(messages: [ChatMessage]) throws {
        guard !messages.isEmpty else { return }

        fileLock.lock()
        defer { fileLock.unlock() }

        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)

        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")

        let now = Date()
        let fileURL = sessionsDirectory.appendingPathComponent("\(dayFormatter.string(from: now)).md")

        var section = "## \(timeFormatter.string(from: now))\n\n"
        for message in messages {
            let speaker = message.role == .user ? "user" : "wisp"
            let cleaned = Self.stripScreenBlocks(message.text)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            section += "\(speaker): \(cleaned)\n"
        }
        section += "\n"

        var content = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        content += section
        try content.data(using: .utf8)?.write(to: fileURL, options: .atomic)
    }

    /// Removes `<screen>…</screen>` and `<screen delta>…</screen>` blocks.
    public static func stripScreenBlocks(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "<screen[^>]*>.*?</screen>",
            options: [.dotMatchesLineSeparators]
        ) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }

    // MARK: - File primitives (callers hold fileLock)

    private func readFactsFile() -> String? {
        try? String(contentsOf: factsURL, encoding: .utf8)
    }

    private func writeFactsFile(_ content: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try content.data(using: .utf8)?.write(to: factsURL, options: .atomic)
    }

    private func parseFacts(from content: String?) -> [MemoryFact] {
        guard let content else { return [] }
        return content.components(separatedBy: "\n").compactMap(Self.parseFactLine)
    }

    /// Parses one `- fact  <!-- id:… src:… at:… -->` line. Hand-edited
    /// lines without the comment become facts with a stable derived ID so
    /// they can still be deleted programmatically.
    static func parseFactLine(_ line: String) -> MemoryFact? {
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
        guard trimmedLine.hasPrefix("- ") else { return nil }
        let body = String(trimmedLine.dropFirst(2))

        guard let commentStart = body.range(of: "<!--"),
              let commentEnd = body.range(of: "-->", range: commentStart.upperBound..<body.endIndex)
        else {
            // Hand-edited line: no metadata.
            let text = body.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return MemoryFact(
                id: Self.stableID(for: text),
                text: text,
                source: "user",
                createdAt: .distantPast
            )
        }

        let text = String(body[..<commentStart.lowerBound]).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        let meta = String(body[commentStart.upperBound..<commentEnd.lowerBound])
        var id = Self.stableID(for: text)
        var source = "user"
        var createdAt = Date.distantPast
        for token in meta.split(whereSeparator: { $0.isWhitespace }) {
            if token.hasPrefix("id:") {
                id = String(token.dropFirst(3))
            } else if token.hasPrefix("src:") {
                source = String(token.dropFirst(4))
            } else if token.hasPrefix("at:"),
                      let parsed = ISO8601DateFormatter().date(from: String(token.dropFirst(3))) {
                createdAt = parsed
            }
        }
        return MemoryFact(id: id, text: text, source: source, createdAt: createdAt)
    }

    /// djb2 hash rendered as hex — stable across runs (unlike hashValue).
    static func stableID(for text: String) -> String {
        var hash: UInt64 = 5381
        for byte in text.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        return String(format: "h%08x", UInt32(truncatingIfNeeded: hash))
    }
}
