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

    /// Sibling of the sessions directory, written by `ActivityLog`.
    var activityDirectory: URL {
        store.sessionsDirectory.deletingLastPathComponent().appendingPathComponent("activity")
    }

    /// Case-insensitive tokenized search; returns the best `limit` hits,
    /// newest-first among equal scores. Total snippet budget ~`tokenBudget`
    /// estimated tokens.
    public func search(query: String, limit: Int = 6, tokenBudget: Int = 700) -> [MemorySearchHit] {
        let queryTokens = Self.tokenize(query)
        guard !queryTokens.isEmpty else { return [] }

        var candidates: [MemorySearchHit] = []

        for fact in store.allFacts() {
            let date = fact.createdAt == .distantPast ? nil : fact.createdAt
            appendScored(&candidates, source: .fact, snippet: fact.text, date: date, queryTokens: queryTokens)
        }
        for (date, snippet) in sessionSections() {
            appendScored(&candidates, source: .session, snippet: snippet, date: date, queryTokens: queryTokens)
        }
        for (date, snippet) in activityLines() {
            appendScored(&candidates, source: .activity, snippet: snippet, date: date, queryTokens: queryTokens)
        }

        candidates.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return (lhs.date ?? .distantPast) > (rhs.date ?? .distantPast)
        }

        var hits: [MemorySearchHit] = []
        var spentTokens = 0
        for candidate in candidates.prefix(limit) {
            let cost = TokenEstimator.estimate(candidate.snippet)
            if !hits.isEmpty && spentTokens + cost > tokenBudget { break }
            hits.append(candidate)
            spentTokens += cost
        }
        return hits
    }

    /// Renders hits as the block injected into the recall re-prompt.
    public static func renderHits(_ hits: [MemorySearchHit], query: String) -> String {
        guard !hits.isEmpty else {
            return "Local memory has nothing relevant to \"\(query)\"."
        }
        var lines = ["Local memory results for \"\(query)\":"]
        for hit in hits {
            let dateSuffix = hit.date.map { " · \(Self.dayFormatter.string(from: $0))" } ?? ""
            lines.append("- [\(hit.source.rawValue)\(dateSuffix)] \(hit.snippet)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Scoring

    private func appendScored(
        _ candidates: inout [MemorySearchHit],
        source: MemorySearchHit.Source,
        snippet: String,
        date: Date?,
        queryTokens: [String]
    ) {
        let documentTokens = Self.tokenize(snippet)
        guard !documentTokens.isEmpty else { return }
        let documentSet = Set(documentTokens)

        let matched = queryTokens.filter { documentSet.contains($0) }
        guard !matched.isEmpty else { return }

        let termFrequency = documentTokens.filter { matched.contains($0) }.count
        var score = Double(matched.count) / Double(queryTokens.count)
            + 0.15 * log(1 + Double(termFrequency))
        if let date {
            let age = Date().timeIntervalSince(date)
            if age < 86_400 { score += 0.3 }
            else if age < 7 * 86_400 { score += 0.2 }
            else if age < 30 * 86_400 { score += 0.1 }
        }
        candidates.append(MemorySearchHit(source: source, snippet: snippet, date: date, score: score))
    }

    static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    // MARK: - Source readers

    /// Parses `sessions/YYYY-MM-DD.md` files into one hit per `## HH:MM`
    /// section: "on DATE: user: … / wisp: …" trimmed to ~400 chars.
    private func sessionSections() -> [(Date?, String)] {
        markdownFiles(in: store.sessionsDirectory).flatMap { fileURL -> [(Date?, String)] in
            let dayString = fileURL.deletingPathExtension().lastPathComponent
            let dayDate = Self.dayFormatter.date(from: dayString)
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }

            var sections: [(Date?, String)] = []
            for rawSection in content.components(separatedBy: "\n## ") {
                let lines = rawSection.components(separatedBy: "\n")
                guard let headerLine = lines.first else { continue }
                let timeString = headerLine
                    .replacingOccurrences(of: "## ", with: "")
                    .trimmingCharacters(in: .whitespaces)
                let exchanges = lines.dropFirst()
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { $0.hasPrefix("user:") || $0.hasPrefix("wisp:") }
                guard !exchanges.isEmpty else { continue }

                var date = dayDate
                if let dayDate,
                   timeString.count == 5,
                   let sectionDate = Self.combine(day: dayDate, time: timeString) {
                    date = sectionDate
                }

                var snippet = "on \(dayString): " + exchanges.joined(separator: " / ")
                if snippet.count > 400 {
                    snippet = String(snippet.prefix(399)) + "…"
                }
                sections.append((date, snippet))
            }
            return sections
        }
    }

    /// One hit per activity line, dated by the file's day.
    private func activityLines() -> [(Date?, String)] {
        markdownFiles(in: activityDirectory).flatMap { fileURL -> [(Date?, String)] in
            let dayString = fileURL.deletingPathExtension().lastPathComponent
            let dayDate = Self.dayFormatter.date(from: dayString)
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
            return content.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("- ") }
                .map { (dayDate, "on \(dayString): " + String($0.dropFirst(2))) }
        }
    }

    private func markdownFiles(in directory: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "md" } ?? []
    }

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static func combine(day: Date, time: String) -> Date? {
        let parts = time.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
        var components = Calendar.current.dateComponents([.year, .month, .day], from: day)
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components)
    }
}
