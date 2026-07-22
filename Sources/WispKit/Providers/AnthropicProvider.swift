import Foundation

/// Anthropic Messages API (`POST {base}/v1/messages`) with SSE streaming.
public final class AnthropicProvider: LLMProvider {
    public let profile: LLMModelProfile
    let keyResolver: APIKeyResolving
    let session: URLSession
    private let warmupThrottle = WarmupThrottle()

    public init(profile: LLMModelProfile, keyResolver: APIKeyResolving, session: URLSession = .shared) {
        self.profile = profile
        self.keyResolver = keyResolver
        self.session = session
    }

    /// Establishes DNS+TCP+TLS to the API host ahead of the first token,
    /// at most once a minute. Fire-and-forget; any response is a success.
    public func warmup() {
        guard warmupThrottle.shouldWarmup() else { return }
        WarmupThrottle.fireWarmupRequest(to: profile.baseURL, session: session)
    }

    public func streamChat(_ request: LLMChatRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let urlRequest = try self.makeURLRequest(request)
                    let (bytes, response) = try await self.session.bytes(for: urlRequest)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw LLMProviderError.malformedResponse("non-HTTP response")
                    }
                    guard (200..<300).contains(httpResponse.statusCode) else {
                        var errorBody = ""
                        for try await line in bytes.lines {
                            errorBody += line + "\n"
                            if errorBody.count > 4000 { break }
                        }
                        throw LLMProviderError.httpError(
                            status: httpResponse.statusCode,
                            body: errorBody.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    }

                    var parser = SSEParser()
                    var usage = LLMUsage()
                    var finished = false
                    byteLoop: for try await byte in bytes {
                        guard let sseEvent = parser.consumeByte(byte) else { continue }
                        for streamEvent in try Self.handleEvent(sseEvent, usage: &usage) {
                            continuation.yield(streamEvent)
                            if case .done = streamEvent {
                                finished = true
                                break byteLoop
                            }
                        }
                    }
                    if !finished {
                        let hasUsage = usage.inputTokens != nil || usage.outputTokens != nil
                        continuation.yield(.done(hasUsage ? usage : nil))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: LLMProviderError.cancelled)
                } catch let error as LLMProviderError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: LLMProviderError.network(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Builds the full URLRequest (endpoint, headers, body). Internal for
    /// testability; throws `.missingAPIKey` when the profile references a
    /// key that does not resolve.
    func makeURLRequest(_ request: LLMChatRequest) throws -> URLRequest {
        var urlRequest = URLRequest(url: Self.endpointURL(baseURL: profile.baseURL))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 120
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if let keyRef = profile.apiKeyRef {
            guard let apiKey = keyResolver.apiKey(for: keyRef) else {
                throw LLMProviderError.missingAPIKey(ref: keyRef)
            }
            urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        }
        urlRequest.httpBody = try Self.makeRequestBody(profile: profile, request: request)
        return urlRequest
    }

    static func endpointURL(baseURL: URL) -> URL {
        let path = baseURL.path
        if path.hasSuffix("/v1/messages") { return baseURL }
        if path.hasSuffix("/v1") { return baseURL.appendingPathComponent("messages") }
        return baseURL.appendingPathComponent("v1/messages")
    }

    static func makeRequestBody(profile: LLMModelProfile, request: LLMChatRequest) throws -> Data {
        var body: [String: Any] = [
            "model": profile.model,
            "max_tokens": request.maxOutputTokens,
            "stream": true,
        ]
        if !request.systemPrompt.isEmpty {
            body["system"] = request.systemPrompt
        }
        if let temperature = request.temperature {
            body["temperature"] = temperature
        }
        body["messages"] = request.messages.map { message -> [String: Any] in
            if message.images.isEmpty {
                return ["role": message.role.rawValue, "content": message.text]
            }
            // Image blocks first, then the text block, per Anthropic's
            // recommended ordering for vision requests.
            var contentBlocks: [[String: Any]] = message.images.map { image in
                [
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": "image/jpeg",
                        "data": image.jpegData.base64EncodedString(),
                    ],
                ]
            }
            contentBlocks.append(["type": "text", "text": message.text])
            return ["role": message.role.rawValue, "content": contentBlocks]
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// Maps one SSE event to zero or more stream events, accumulating usage.
    static func handleEvent(_ event: SSEEvent, usage: inout LLMUsage) throws -> [LLMStreamEvent] {
        guard
            let json = try? JSONSerialization.jsonObject(with: Data(event.data.utf8)) as? [String: Any],
            let type = json["type"] as? String
        else {
            return []
        }
        switch type {
        case "message_start":
            if let message = json["message"] as? [String: Any],
               let startUsage = message["usage"] as? [String: Any] {
                if let inputTokens = startUsage["input_tokens"] as? Int {
                    usage.inputTokens = inputTokens
                }
                if let outputTokens = startUsage["output_tokens"] as? Int {
                    usage.outputTokens = outputTokens
                }
            }
            return []
        case "content_block_delta":
            if let delta = json["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String,
               !text.isEmpty {
                return [.textDelta(text)]
            }
            return []
        case "message_delta":
            if let deltaUsage = json["usage"] as? [String: Any],
               let outputTokens = deltaUsage["output_tokens"] as? Int {
                usage.outputTokens = outputTokens
            }
            return []
        case "message_stop":
            let hasUsage = usage.inputTokens != nil || usage.outputTokens != nil
            return [.done(hasUsage ? usage : nil)]
        case "error":
            let message = ((json["error"] as? [String: Any])?["message"] as? String) ?? event.data
            throw LLMProviderError.malformedResponse("API error: \(message)")
        default:
            return []
        }
    }
}
