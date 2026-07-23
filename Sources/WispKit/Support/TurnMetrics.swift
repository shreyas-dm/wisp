import Foundation

/// Per-turn latency and cost breakdown, the raw material for tuning feel.
/// All values in milliseconds unless noted.
public struct TurnMetrics: Codable, Sendable, Equatable {
    public var startedAt: Date
    public var profileID: String
    /// Snapshot capture + serialization.
    public var captureMs: Double?
    /// OCR, when it ran.
    public var ocrMs: Double?
    /// Release-of-key → final transcript.
    public var sttMs: Double?
    /// Request sent → first text delta.
    public var firstTokenMs: Double?
    /// Request sent → stream complete.
    public var streamMs: Double?
    /// Stream complete → first TTS audio audible.
    public var ttsStartMs: Double?
    public var inputTokens: Int?
    public var outputTokens: Int?
    /// Estimated tokens of the screen-context block for this turn.
    public var snapshotTokens: Int?

    public init(startedAt: Date = Date(), profileID: String) {
        self.startedAt = startedAt
        self.profileID = profileID
    }

    /// One-line human rendering for `--timing` and the menu panel.
    public var summaryLine: String {
        func fmt(_ value: Double?) -> String {
            guard let value else { return "–" }
            return "\(Int(value.rounded()))ms"
        }
        return "capture \(fmt(captureMs)) · stt \(fmt(sttMs)) · first-token \(fmt(firstTokenMs)) · stream \(fmt(streamMs)) · tts \(fmt(ttsStartMs))"
    }
}

/// Appends metrics as JSON lines to `~/.wisp/metrics.jsonl` (local only).
public final class MetricsLog: @unchecked Sendable {
    public let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL? = nil) {
        self.fileURL = fileURL
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".wisp/metrics.jsonl")
    }

    public func append(_ metrics: TurnMetrics) {
        // TODO(fork-core): implement (atomic append, ISO dates, swallow errors).
    }

    /// Recent entries, newest last (for the menu panel and `wisp doctor`).
    public func recent(limit: Int = 50) -> [TurnMetrics] {
        // TODO(fork-core): implement.
        []
    }
}
