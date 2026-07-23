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
        // TODO(fork-core): implement.
    }

    /// The day's log lines, newest last (for recall search and debugging).
    public func lines(on day: Date = Date()) -> [String] {
        // TODO(fork-core): implement.
        []
    }

    /// Compact one-paragraph summary of a day ("mostly Xcode (2h10m) and
    /// Safari (40m); notable windows …") for distillation.
    public func daySummary(_ day: Date = Date()) -> String? {
        // TODO(fork-core): implement.
        nil
    }
}
