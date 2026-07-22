import Foundation
@testable import WispKit

/// URLProtocol test double that serves scripted responses with chunked
/// bodies, so provider streaming is exercised through the real URLSession
/// loading pipeline (chunk boundaries and all) without any network.
///
/// Script and log are global; the test harness runs cases sequentially, so
/// call `reset(script:)` at the top of each test.
final class StubHTTPProtocol: URLProtocol {
    struct ScriptedResponse {
        var status: Int
        var headers: [String: String] = ["Content-Type": "text/event-stream"]
        /// Body pieces delivered one at a time with a small delay between,
        /// simulating network chunking.
        var chunks: [Data]
        var chunkDelayNanoseconds: UInt64 = 1_000_000
    }

    struct LoggedRequest {
        var request: URLRequest
        var body: Data?
    }

    private static let lock = NSLock()
    private static var script: [ScriptedResponse] = []
    private static var log: [LoggedRequest] = []

    static func reset(script: [ScriptedResponse]) {
        lock.lock()
        defer { lock.unlock() }
        self.script = script
        log = []
    }

    static var loggedRequests: [LoggedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    /// Waits (polling) until `count` requests have been logged, or the
    /// timeout passes. Returns the reached count.
    static func waitForRequestCount(_ count: Int, timeoutSeconds: Double = 2) async -> Int {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if loggedRequests.count >= count { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return loggedRequests.count
    }

    /// URLSession converts httpBody to a stream before the protocol sees the
    /// request, so drain whichever representation is present.
    private static func drainBody(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.log.append(LoggedRequest(request: request, body: Self.drainBody(of: request)))
        let scripted = Self.script.isEmpty ? nil : Self.script.removeFirst()
        Self.lock.unlock()

        guard let scripted else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://stub.invalid")!,
            statusCode: scripted.status,
            httpVersion: "HTTP/1.1",
            headerFields: scripted.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        Task { [weak self] in
            guard let self else { return }
            for chunk in scripted.chunks {
                try? await Task.sleep(nanoseconds: scripted.chunkDelayNanoseconds)
                self.client?.urlProtocol(self, didLoad: chunk)
            }
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

/// A URLSession whose every request is answered by `StubHTTPProtocol`.
func makeStubbedSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubHTTPProtocol.self]
    return URLSession(configuration: configuration)
}

/// Splits a string into fixed-size byte chunks — guarantees SSE events are
/// severed mid-line/mid-event to exercise incremental parsing.
func chunked(_ text: String, size: Int) -> [Data] {
    let bytes = Array(text.utf8)
    return stride(from: 0, to: bytes.count, by: size).map { start in
        Data(bytes[start..<min(start + size, bytes.count)])
    }
}

/// Collects a provider stream into (events, thrown error).
func collectStream(
    _ stream: AsyncThrowingStream<LLMStreamEvent, Error>
) async -> (events: [LLMStreamEvent], error: Error?) {
    var events: [LLMStreamEvent] = []
    do {
        for try await event in stream {
            events.append(event)
        }
        return (events, nil)
    } catch {
        return (events, error)
    }
}
