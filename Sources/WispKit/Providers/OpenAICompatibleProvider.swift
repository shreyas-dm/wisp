import Foundation

/// OpenAI-compatible Chat Completions (`POST {base}/chat/completions`,
/// `stream: true`). One implementation covers OpenAI, Ollama, vLLM,
/// LM Studio, OpenRouter, Groq, Zhipu GLM, Moonshot Kimi, DeepSeek, and
/// most other open-model hosts.
public final class OpenAICompatibleProvider: LLMProvider {
    public let profile: LLMModelProfile
    let keyResolver: APIKeyResolving

    public init(profile: LLMModelProfile, keyResolver: APIKeyResolving) {
        self.profile = profile
        self.keyResolver = keyResolver
    }

    public func streamChat(_ request: LLMChatRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    do {
                        try await self.runStream(request, includeStreamUsage: true, continuation: continuation)
                    } catch let LLMProviderError.httpError(status, body)
                        where (400..<500).contains(status) && body.contains("stream_options") {
                        // Some servers reject stream_options — retry without.
                        try await self.runStream(request, includeStreamUsage: false, continuation: continuation)
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

    private func runStream(
        _ request: LLMChatRequest,
        includeStreamUsage: Bool,
        continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
    ) async throws {
        let urlRequest = try makeURLRequest(request, includeStreamUsage: includeStreamUsage)
        let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
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
        var usage: LLMUsage?
        var finished = false
        byteLoop: for try await byte in bytes {
            guard let sseEvent = parser.consumeByte(byte) else { continue }
            if sseEvent.data == "[DONE]" {
                continuation.yield(.done(usage))
                finished = true
                break byteLoop
            }
            for streamEvent in Self.handleEventData(sseEvent.data, usage: &usage) {
                continuation.yield(streamEvent)
            }
        }
        if !finished {
            continuation.yield(.done(usage))
        }
    }

    /// Builds the full URLRequest. Internal for testability; throws
    /// `.missingAPIKey` when the profile references a key that does not
    /// resolve. The Authorization header is omitted entirely for keyless
    /// profiles (local servers).
    func makeURLRequest(_ request: LLMChatRequest, includeStreamUsage: Bool) throws -> URLRequest {
        var urlRequest = URLRequest(url: Self.endpointURL(baseURL: profile.baseURL))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 120
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let keyRef = profile.apiKeyRef {
            guard let apiKey = keyResolver.apiKey(for: keyRef) else {
                throw LLMProviderError.missingAPIKey(ref: keyRef)
            }
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.httpBody = try Self.makeRequestBody(
            profile: profile,
            request: request,
            includeStreamUsage: includeStreamUsage
        )
        return urlRequest
    }

    static func endpointURL(baseURL: URL) -> URL {
        if baseURL.path.hasSuffix("/chat/completions") { return baseURL }
        return baseURL.appendingPathComponent("chat/completions")
    }

    static func makeRequestBody(
        profile: LLMModelProfile,
        request: LLMChatRequest,
        includeStreamUsage: Bool
    ) throws -> Data {
        var messages: [[String: Any]] = []
        if !request.systemPrompt.isEmpty {
            messages.append(["role": "system", "content": request.systemPrompt])
        }
        for message in request.messages {
            if message.images.isEmpty {
                messages.append(["role": message.role.rawValue, "content": message.text])
            } else {
                var contentParts: [[String: Any]] = [["type": "text", "text": message.text]]
                for image in message.images {
                    contentParts.append([
                        "type": "image_url",
                        "image_url": [
                            "url": "data:image/jpeg;base64,\(image.jpegData.base64EncodedString())"
                        ],
                    ])
                }
                messages.append(["role": message.role.rawValue, "content": contentParts])
            }
        }

        var body: [String: Any] = [
            "model": profile.model,
            "messages": messages,
            "stream": true,
            "max_tokens": request.maxOutputTokens,
        ]
        if includeStreamUsage {
            body["stream_options"] = ["include_usage": true]
        }
        if let temperature = request.temperature {
            body["temperature"] = temperature
        }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// Maps one SSE data payload to stream events, accumulating usage.
    /// `reasoning_content` deltas (reasoning models) are ignored.
    static func handleEventData(_ data: String, usage: inout LLMUsage?) -> [LLMStreamEvent] {
        guard let json = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] else {
            return []
        }
        if let usageObject = json["usage"] as? [String: Any] {
            var updated = usage ?? LLMUsage()
            if let promptTokens = usageObject["prompt_tokens"] as? Int {
                updated.inputTokens = promptTokens
            }
            if let completionTokens = usageObject["completion_tokens"] as? Int {
                updated.outputTokens = completionTokens
            }
            usage = updated
        }
        guard
            let choices = json["choices"] as? [[String: Any]],
            let firstChoice = choices.first,
            let delta = firstChoice["delta"] as? [String: Any],
            let content = delta["content"] as? String,
            !content.isEmpty
        else {
            return []
        }
        return [.textDelta(content)]
    }
}
