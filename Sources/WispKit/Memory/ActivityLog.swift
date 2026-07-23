import Foundation

/// Local-only log of which app/window the user was in and for how long.
/// Lives at `~/.wisp/memory/activity/YYYY-MM-DD.md`, one line per focus
/// span. Feeds recall search and memory distillation so Wisp knows what
/// you have been working on. Never leaves the machine; disable with
/// `"activityLogEnabled": false`.
///
/// Line format:
///     - 14:03–14:21 Xcode — "wisp — CompanionEngine.swift" (18m)
public final class ActivityLog: @unchecked Sendable {
    public let directory: URL
    private let fileLock = NSLock()

    public init(directory: URL? = nil) {
        self.directory = directory
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".wisp/memory/activity")
    }

    /// Record a completed focus span. Spans shorter than `minimumSeconds`
    /// (default 15) are dropped as noise.
    public func recordSpan(
        appName: String,
        windowTitle: String?,
        start: Date,
        end: Date,
        minimumSeconds: TimeInterval = 15
    ) throws {
        let duration = end.timeIntervalSince(start)
        guard duration >= minimumSeconds else { return }

        var line = "- \(Self.timeFormatter.string(from: start))–\(Self.timeFormatter.string(from: end)) \(appName)"
        if let windowTitle, !windowTitle.isEmpty {
            line += " — \"\(windowTitle)\""
        }
        line += " (\(Self.formatDuration(duration)))\n"

        fileLock.lock()
        defer { fileLock.unlock() }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dayString = Self.dayFormatter.string(from: start)
        let fileURL = directory.appendingPathComponent("\(dayString).md")
        var content = (try? String(contentsOf: fileURL, encoding: .utf8))
            ?? "# Activity \(dayString)\n\n"
        if !content.hasSuffix("\n") { content += "\n" }
        content += line
        try content.data(using: .utf8)?.write(to: fileURL, options: .atomic)
    }

    /// The day's log lines, newest last (for recall search and debugging).
    public func lines(on day: Date = Date()) -> [String] {
        fileLock.lock()
        defer { fileLock.unlock() }
        let fileURL = directory.appendingPathComponent("\(Self.dayFormatter.string(from: day)).md")
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return content.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") }
    }

    /// Compact one-paragraph summary of a day ("Xcode 2h10m, Safari 40m —
    /// windows: …") for distillation and recall.
    public func daySummary(_ day: Date = Date()) -> String? {
        let parsed = lines(on: day).compactMap(Self.parseLine)
        guard !parsed.isEmpty else { return nil }

        var secondsPerApp: [String: TimeInterval] = [:]
        var appOrder: [String] = []
        var windowTitles: [String] = []
        for span in parsed {
            if secondsPerApp[span.appName] == nil { appOrder.append(span.appName) }
            secondsPerApp[span.appName, default: 0] += span.seconds
            if let title = span.windowTitle, !title.isEmpty, !windowTitles.contains(title) {
                windowTitles.append(title)
            }
        }

        let rankedApps = secondsPerApp.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return (appOrder.firstIndex(of: $0.key) ?? 0) < (appOrder.firstIndex(of: $1.key) ?? 0)
        }
        var summary = rankedApps.prefix(3)
            .map { "\($0.key) \(Self.formatDuration($0.value))" }
            .joined(separator: ", ")
        if !windowTitles.isEmpty {
            summary += " — windows: " + windowTitles.prefix(3).map { "\"\($0)\"" }.joined(separator: ", ")
        }
        return summary
    }

    // MARK: - Parsing and formatting

    struct Span {
        var appName: String
        var windowTitle: String?
        var seconds: TimeInterval
    }

    /// Parses `- HH:mm–HH:mm App — "Title" (Nm)` back into a span.
    static func parseLine(_ line: String) -> Span? {
        guard line.hasPrefix("- ") else { return nil }
        var body = String(line.dropFirst(2))

        // Duration suffix "(…)"
        guard let durationOpen = body.range(of: " (", options: .backwards),
              body.hasSuffix(")")
        else { return nil }
        let durationText = String(body[durationOpen.upperBound..<body.index(before: body.endIndex)])
        guard let seconds = parseDuration(durationText) else { return nil }
        body = String(body[..<durationOpen.lowerBound])

        // Leading "HH:mm–HH:mm "
        guard let firstSpace = body.firstIndex(of: " ") else { return nil }
        body = String(body[body.index(after: firstSpace)...])

        // Optional « — "Title" » tail.
        var windowTitle: String?
        if let titleMarker = body.range(of: " — \"", options: .backwards), body.hasSuffix("\"") {
            windowTitle = String(body[titleMarker.upperBound..<body.index(before: body.endIndex)])
            body = String(body[..<titleMarker.lowerBound])
        }

        let appName = body.trimmingCharacters(in: .whitespaces)
        guard !appName.isEmpty else { return nil }
        return Span(appName: appName, windowTitle: windowTitle, seconds: seconds)
    }

    /// "45s", "18m", "2h10m".
    static func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds.rounded()))s" }
        let totalMinutes = Int((seconds / 60).rounded())
        if totalMinutes < 60 { return "\(totalMinutes)m" }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return minutes == 0 ? "\(hours)h" : "\(hours)h\(minutes)m"
    }

    static func parseDuration(_ text: String) -> TimeInterval? {
        if text.hasSuffix("s"), let seconds = Int(text.dropLast()) {
            return TimeInterval(seconds)
        }
        if let hourMarker = text.firstIndex(of: "h") {
            guard let hours = Int(text[..<hourMarker]) else { return nil }
            let rest = text[text.index(after: hourMarker)...]
            if rest.isEmpty { return TimeInterval(hours * 3600) }
            guard rest.hasSuffix("m"), let minutes = Int(rest.dropLast()) else { return nil }
            return TimeInterval(hours * 3600 + minutes * 60)
        }
        if text.hasSuffix("m"), let minutes = Int(text.dropLast()) {
            return TimeInterval(minutes * 60)
        }
        return nil
    }

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
