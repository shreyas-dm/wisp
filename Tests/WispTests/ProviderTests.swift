import Foundation
@testable import WispKit

private struct StubKeys: APIKeyResolving {
    var keys: [String: String] = [:]
    func apiKey(for ref: String) -> String? { keys[ref] }
}

private func makeProfile(
    style: LLMAPIStyle,
    base: String,
    keyRef: String? = nil,
    temperature: Double? = nil,
    model: String = "test-model"
) -> LLMModelProfile {
    LLMModelProfile(
        id: "test",
        displayName: "Test",
        apiStyle: style,
        baseURL: URL(string: base)!,
        model: model,
        apiKeyRef: keyRef,
        supportsVision: true,
        maxOutputTokens: 512,
        temperature: temperature
    )
}

private func jsonObject(_ data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

func providerTests(_ t: TestRunner) -> [TestCase] {
    [
        TestCase("SSE parser: whole-feed and per-byte feeds agree") {
            let raw = "event: alpha\ndata: {\"a\":1}\n\n"
                + ": keepalive comment\n"
                + "data: line1\ndata: line2\r\n\r\n"
                + "data: [DONE]\n\n"
            let expected = [
                SSEEvent(event: "alpha", data: "{\"a\":1}"),
                SSEEvent(event: nil, data: "line1\nline2"),
                SSEEvent(event: nil, data: "[DONE]"),
            ]

            var wholeParser = SSEParser()
            let wholeResult = wholeParser.consume(Data(raw.utf8))
            t.expectEqual(wholeResult, expected, "whole feed")

            var byteParser = SSEParser()
            var byteResult: [SSEEvent] = []
            for byte in Data(raw.utf8) {
                byteResult += byteParser.consume(Data([byte]))
            }
            t.expectEqual(byteResult, expected, "per-byte feed")
        },

        TestCase("anthropic request body shape") {
            let profile = makeProfile(style: .anthropic, base: "https://api.anthropic.com", temperature: 0.5)
            let request = LLMChatRequest(
                systemPrompt: "sys prompt",
                messages: [
                    ChatMessage(role: .user, text: "hi", images: [AttachedImage(jpegData: Data([0xFF, 0xD8]))]),
                    ChatMessage(role: .assistant, text: "yo"),
                ],
                maxOutputTokens: 512,
                temperature: 0.5
            )
            let body = jsonObject(try AnthropicProvider.makeRequestBody(profile: profile, request: request))

            t.expectEqual(body["model"] as? String, "test-model")
            t.expectEqual(body["stream"] as? Bool, true)
            t.expectEqual(body["max_tokens"] as? Int, 512)
            t.expectEqual(body["system"] as? String, "sys prompt")
            t.expectEqual(body["temperature"] as? Double, 0.5)

            let messages = body["messages"] as? [[String: Any]] ?? []
            t.expectEqual(messages.count, 2)
            let firstContent = messages.first?["content"] as? [[String: Any]] ?? []
            t.expectEqual(firstContent.count, 2, "image block + text block")
            t.expectEqual(firstContent.first?["type"] as? String, "image")
            let source = firstContent.first?["source"] as? [String: Any] ?? [:]
            t.expectEqual(source["media_type"] as? String, "image/jpeg")
            t.expectEqual(source["data"] as? String, Data([0xFF, 0xD8]).base64EncodedString())
            t.expectEqual(firstContent.last?["type"] as? String, "text")
            t.expectEqual(firstContent.last?["text"] as? String, "hi")
            t.expectEqual(messages.last?["content"] as? String, "yo")
        },

        TestCase("anthropic endpoint URL variants") {
            func endpoint(_ base: String) -> String {
                AnthropicProvider.endpointURL(baseURL: URL(string: base)!).absoluteString
            }
            t.expectEqual(endpoint("https://api.anthropic.com"), "https://api.anthropic.com/v1/messages")
            t.expectEqual(endpoint("https://proxy.example.com/v1"), "https://proxy.example.com/v1/messages")
            t.expectEqual(endpoint("https://proxy.example.com/v1/messages"), "https://proxy.example.com/v1/messages")
        },

        TestCase("anthropic headers and missing key") {
            let request = LLMChatRequest(systemPrompt: "", messages: [ChatMessage(role: .user, text: "hi")])

            let keyed = AnthropicProvider(
                profile: makeProfile(style: .anthropic, base: "https://api.anthropic.com", keyRef: "K"),
                keyResolver: StubKeys(keys: ["K": "sk-test"])
            )
            let urlRequest = try keyed.makeURLRequest(request)
            t.expectEqual(urlRequest.value(forHTTPHeaderField: "x-api-key"), "sk-test")
            t.expectEqual(urlRequest.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")

            let unkeyed = AnthropicProvider(
                profile: makeProfile(style: .anthropic, base: "https://api.anthropic.com", keyRef: "MISSING"),
                keyResolver: StubKeys()
            )
            var caught: LLMProviderError?
            do {
                for try await _ in unkeyed.streamChat(request) {}
            } catch let error as LLMProviderError {
                caught = error
            }
            t.expectEqual(caught, .missingAPIKey(ref: "MISSING"))
        },

        TestCase("anthropic SSE event handling") {
            var usage = LLMUsage()
            _ = try AnthropicProvider.handleEvent(
                SSEEvent(data: #"{"type":"message_start","message":{"usage":{"input_tokens":42}}}"#),
                usage: &usage
            )
            t.expectEqual(usage.inputTokens, 42)

            let deltas = try AnthropicProvider.handleEvent(
                SSEEvent(data: #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}"#),
                usage: &usage
            )
            t.expectEqual(deltas, [.textDelta("Hi")])

            _ = try AnthropicProvider.handleEvent(
                SSEEvent(data: #"{"type":"message_delta","usage":{"output_tokens":7}}"#),
                usage: &usage
            )
            let done = try AnthropicProvider.handleEvent(SSEEvent(data: #"{"type":"message_stop"}"#), usage: &usage)
            t.expectEqual(done, [.done(LLMUsage(inputTokens: 42, outputTokens: 7))])

            var threw = false
            do {
                _ = try AnthropicProvider.handleEvent(
                    SSEEvent(data: #"{"type":"error","error":{"message":"overloaded"}}"#),
                    usage: &usage
                )
            } catch { threw = true }
            t.expect(threw, "error event throws")
        },

        TestCase("openai request body shape (plain and vision)") {
            let profile = makeProfile(style: .openaiCompatible, base: "http://localhost:11434/v1")
            let plainRequest = LLMChatRequest(
                systemPrompt: "sys",
                messages: [ChatMessage(role: .user, text: "hello")],
                maxOutputTokens: 512
            )
            let plain = jsonObject(try OpenAICompatibleProvider.makeRequestBody(
                profile: profile, request: plainRequest, includeStreamUsage: true
            ))
            let plainMessages = plain["messages"] as? [[String: Any]] ?? []
            t.expectEqual(plainMessages.first?["role"] as? String, "system")
            t.expectEqual(plainMessages.first?["content"] as? String, "sys")
            t.expectEqual(plainMessages.last?["content"] as? String, "hello", "plain string content when no images")
            t.expectEqual((plain["stream_options"] as? [String: Any])?["include_usage"] as? Bool, true)
            t.expect(plain["temperature"] == nil, "temperature omitted when nil")

            let visionRequest = LLMChatRequest(
                systemPrompt: "",
                messages: [ChatMessage(role: .user, text: "see", images: [AttachedImage(jpegData: Data([0x01]))])]
            )
            let vision = jsonObject(try OpenAICompatibleProvider.makeRequestBody(
                profile: profile, request: visionRequest, includeStreamUsage: false
            ))
            let visionMessages = vision["messages"] as? [[String: Any]] ?? []
            t.expectEqual(visionMessages.count, 1, "no system message when empty")
            let parts = visionMessages.first?["content"] as? [[String: Any]] ?? []
            t.expectEqual(parts.first?["type"] as? String, "text")
            let imageURL = (parts.last?["image_url"] as? [String: Any])?["url"] as? String ?? ""
            t.expect(imageURL.hasPrefix("data:image/jpeg;base64,"), "data URL for image")
            t.expect(vision["stream_options"] == nil, "stream_options omitted on retry")
        },

        TestCase("openai endpoint URL variants and auth header") {
            func endpoint(_ base: String) -> String {
                OpenAICompatibleProvider.endpointURL(baseURL: URL(string: base)!).absoluteString
            }
            t.expectEqual(endpoint("http://localhost:11434/v1"), "http://localhost:11434/v1/chat/completions")
            t.expectEqual(endpoint("https://api.moonshot.ai/v1"), "https://api.moonshot.ai/v1/chat/completions")
            t.expectEqual(
                endpoint("https://example.com/custom/chat/completions"),
                "https://example.com/custom/chat/completions"
            )

            let request = LLMChatRequest(systemPrompt: "", messages: [ChatMessage(role: .user, text: "hi")])
            let keyless = OpenAICompatibleProvider(
                profile: makeProfile(style: .openaiCompatible, base: "http://localhost:11434/v1"),
                keyResolver: StubKeys()
            )
            let keylessRequest = try keyless.makeURLRequest(request, includeStreamUsage: true)
            t.expect(
                keylessRequest.value(forHTTPHeaderField: "Authorization") == nil,
                "no Authorization header for keyless profiles"
            )

            let keyed = OpenAICompatibleProvider(
                profile: makeProfile(style: .openaiCompatible, base: "https://api.moonshot.ai/v1", keyRef: "MK"),
                keyResolver: StubKeys(keys: ["MK": "mk-1"])
            )
            let keyedRequest = try keyed.makeURLRequest(request, includeStreamUsage: true)
            t.expectEqual(keyedRequest.value(forHTTPHeaderField: "Authorization"), "Bearer mk-1")
        },

        TestCase("openai SSE data handling") {
            var usage: LLMUsage?
            let deltas = OpenAICompatibleProvider.handleEventData(
                #"{"choices":[{"delta":{"content":"Hey"}}]}"#, usage: &usage
            )
            t.expectEqual(deltas, [.textDelta("Hey")])

            let reasoning = OpenAICompatibleProvider.handleEventData(
                #"{"choices":[{"delta":{"reasoning_content":"thinking..."}}]}"#, usage: &usage
            )
            t.expectEqual(reasoning, [], "reasoning_content ignored")

            let usageOnly = OpenAICompatibleProvider.handleEventData(
                #"{"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":25}}"#, usage: &usage
            )
            t.expectEqual(usageOnly, [])
            t.expectEqual(usage, LLMUsage(inputTokens: 100, outputTokens: 25))
        },

        TestCase("mock provider points at a snapshot element and reports usage") {
            let snapshotText = """
            <screen> app=TestApp window="W" display=1/1 100x100
              e3 text "Header" (0,0 100x20)
            * e7 btn "Send invoice" (10,40 80x24)
            </screen>

            User said: what do I click?
            """
            let provider = MockProvider(
                profile: makeProfile(style: .openaiCompatible, base: "http://localhost:0", model: "mock"),
                wordDelayNanoseconds: 0
            )
            let request = LLMChatRequest(
                systemPrompt: "sys",
                messages: [ChatMessage(role: .user, text: snapshotText)]
            )
            var text = ""
            var doneUsage: LLMUsage??
            for try await event in provider.streamChat(request) {
                switch event {
                case .textDelta(let delta): text += delta
                case .done(let usage): doneUsage = usage
                }
            }
            t.expect(text.contains("[[point:e7]]"), "points at first interactive element, got: \(text)")
            t.expect(!text.contains("[[point:e3]]"), "does not point at static text")
            t.expect(doneUsage != nil, ".done was emitted")
            t.expect((doneUsage ?? nil)?.outputTokens ?? 0 > 0, "plausible output tokens")
        },

        TestCase("prompt builder composes snapshot above transcript") {
            let builder = PromptBuilder(config: WispConfig.makeDefault())
            let request = builder.buildRequest(
                transcript: "hello there",
                snapshotBlock: "<screen> app=X </screen>",
                history: [],
                memoryProfile: "Knows Swift well.",
                supportsVision: false
            )
            t.expectEqual(request.messages.count, 1)
            let text = request.messages[0].text
            t.expect(text.hasPrefix("<screen>"), "snapshot first")
            t.expect(text.contains("\n\nUser said: hello there"), "transcript labeled below snapshot")
            t.expect(request.systemPrompt.contains("Knows Swift well."), "memory in system prompt")
            t.expect(!request.systemPrompt.contains("SCREENSHOT FALLBACK"), "no screenshot section without vision")

            let bare = builder.buildRequest(
                transcript: "just words",
                snapshotBlock: nil,
                history: [],
                memoryProfile: nil,
                supportsVision: true
            )
            t.expectEqual(bare.messages[0].text, "just words", "raw transcript when no snapshot")
            t.expect(bare.systemPrompt.contains("SCREENSHOT FALLBACK"), "screenshot section with vision")
        },

        TestCase("history compaction strips old screen blocks, keeps latest") {
            let history = [
                ChatMessage(
                    role: .user,
                    text: "<screen> app=A\n e1 btn \"X\" </screen>\n\nUser said: first",
                    images: [AttachedImage(jpegData: Data([0x01]))]
                ),
                ChatMessage(role: .assistant, text: "answer one"),
                ChatMessage(role: .user, text: "<screen delta> app=A\n+ e9 btn \"Y\"\n</screen>\n\nUser said: second"),
                ChatMessage(role: .assistant, text: "answer two"),
            ]
            let compacted = PromptBuilder.compactHistory(history, turnLimit: 12)
            t.expectEqual(compacted.count, 4)
            t.expect(!compacted[0].text.contains("<screen"), "old snapshot stripped")
            t.expect(compacted[0].text.contains("first"), "old words kept")
            t.expect(compacted[0].images.isEmpty, "old images dropped")
            t.expect(compacted[2].text.contains("<screen delta>"), "latest user snapshot kept")

            let trimmed = PromptBuilder.compactHistory(history, turnLimit: 1)
            t.expectEqual(trimmed.count, 2, "turn limit caps messages")
            t.expectEqual(trimmed.last?.text, "answer two")
        },
    ]
}
