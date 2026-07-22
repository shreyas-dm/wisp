import Foundation

/// Key-free demo provider: streams a canned, situation-aware reply with
/// realistic pacing so the entire experience (bubble, TTS, pointing) can be
/// exercised before any API key exists. When the last user message carries a
/// `<screen>` block, the reply points at the first interactive element in it.
public final class MockProvider: LLMProvider {
    public let profile: LLMModelProfile
    let wordDelayNanoseconds: UInt64

    public init(profile: LLMModelProfile, wordDelayNanoseconds: UInt64 = 25_000_000) {
        self.profile = profile
        self.wordDelayNanoseconds = wordDelayNanoseconds
    }

    public func streamChat(_ request: LLMChatRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let reply = Self.composeReply(for: request)
        let delay = wordDelayNanoseconds
        return AsyncThrowingStream { continuation in
            let task = Task {
                let words = reply.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
                for (index, word) in words.enumerated() {
                    if Task.isCancelled { break }
                    if delay > 0 {
                        try? await Task.sleep(nanoseconds: delay)
                    }
                    continuation.yield(.textDelta(index == 0 ? word : " " + word))
                }
                let inputText = request.systemPrompt + request.messages.map(\.text).joined(separator: "\n")
                continuation.yield(.done(LLMUsage(
                    inputTokens: TokenEstimator.estimate(inputText),
                    outputTokens: TokenEstimator.estimate(reply)
                )))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func composeReply(for request: LLMChatRequest) -> String {
        let lastUserText = request.messages.last { $0.role == .user }?.text ?? ""
        var reply: String
        if let element = firstInteractiveElement(inSnapshotBlockOf: lastUserText) {
            let label = element.title.isEmpty ? element.id : "“\(element.title)”"
            reply = "This is Wisp's demo voice — I can see your screen. "
                + "For example, I can point right at \(label) [[point:\(element.id)]]. "
                + "Add a real API key with `wisp key set` and pick a model from the menu bar to bring me to life."
        } else {
            reply = "This is Wisp's demo voice. I couldn't read a screen snapshot this time, "
                + "but once you add an API key with `wisp key set` and pick a model from the menu bar, "
                + "I'll see and explain whatever is in front of you."
        }
        if lastUserText.lowercased().contains("remember") {
            reply += " [[remember:The user explored Wisp's demo mode.]]"
        }
        return reply
    }

    private static let elementLineRegex = try! NSRegularExpression(
        pattern: "^\\s*\\*?\\s*(e\\d+)\\s+([a-z]+)\\s+\"([^\"]*)\"",
        options: [.anchorsMatchLines]
    )

    private static let interactiveRoles: Set<String> = [
        "btn", "link", "field", "check", "radio", "popup", "menu", "tab", "slider",
    ]

    static func firstInteractiveElement(inSnapshotBlockOf text: String) -> (id: String, title: String)? {
        guard
            let blockStart = text.range(of: "<screen"),
            let blockEnd = text.range(of: "</screen>"),
            blockStart.lowerBound < blockEnd.lowerBound
        else {
            return nil
        }
        let block = String(text[blockStart.lowerBound..<blockEnd.lowerBound])
        let fullRange = NSRange(block.startIndex..., in: block)
        for match in elementLineRegex.matches(in: block, range: fullRange) {
            guard
                let idRange = Range(match.range(at: 1), in: block),
                let roleRange = Range(match.range(at: 2), in: block),
                let titleRange = Range(match.range(at: 3), in: block)
            else { continue }
            let role = String(block[roleRange])
            if interactiveRoles.contains(role) {
                return (id: String(block[idRange]), title: String(block[titleRange]))
            }
        }
        return nil
    }
}
