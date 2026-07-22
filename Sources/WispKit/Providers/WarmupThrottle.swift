import Foundation

/// Thread-safe once-per-interval gate for connection warmups, so holding the
/// push-to-talk key repeatedly doesn't spam the provider host.
final class WarmupThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastWarmupAt: Date?
    private let interval: TimeInterval

    init(interval: TimeInterval = 60) {
        self.interval = interval
    }

    /// Returns true when a warmup should proceed now (and records it).
    func shouldWarmup(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let lastWarmupAt, now.timeIntervalSince(lastWarmupAt) < interval {
            return false
        }
        lastWarmupAt = now
        return true
    }
}

extension WarmupThrottle {
    /// Fires a tiny fire-and-forget GET whose only purpose is to put a warm
    /// DNS+TCP+TLS connection into the session's pool. Any HTTP status is a
    /// success; all errors are swallowed.
    static func fireWarmupRequest(to url: URL, session: URLSession) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 3
        Task {
            _ = try? await session.data(for: request)
        }
    }
}
