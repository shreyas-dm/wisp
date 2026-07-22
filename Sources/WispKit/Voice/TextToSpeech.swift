import Foundation

/// Streaming-friendly TTS: the engine accepts sentence fragments as the
/// reply streams in and speaks them in order, so speech starts before the
/// full reply has arrived.
public protocol TextToSpeechEngine: AnyObject {
    var isSpeaking: Bool { get }
    /// Fired when the queue drains.
    var onFinished: (() -> Void)? { get set }

    /// Queue a complete sentence (or clause) for speech.
    func enqueue(_ sentence: String)
    /// Signal that no more fragments are coming for this reply.
    func finishReply()
    /// Stop immediately and clear the queue.
    func stop()
}

/// Local, key-free TTS via AVSpeechSynthesizer, tuned for a pleasant
/// system voice (prefers premium/enhanced voices when installed).
public final class AppleTextToSpeech: TextToSpeechEngine {
    public var onFinished: (() -> Void)?

    public init() {}

    public var isSpeaking: Bool {
        // TODO(fork-voice-memory): implement.
        false
    }

    public func enqueue(_ sentence: String) {
        // TODO(fork-voice-memory): implement.
    }

    public func finishReply() {
        // TODO(fork-voice-memory): implement.
    }

    public func stop() {
        // TODO(fork-voice-memory): implement.
    }
}

/// Splits streamed text deltas into speakable sentences for the TTS queue.
/// Buffers until a sentence boundary (. ! ? … or newline) is seen, with a
/// minimum length so abbreviations don't cut sentences short.
public struct SentenceChunker: Sendable {
    public init() {}

    public mutating func consume(_ delta: String) -> [String] {
        // TODO(fork-voice-memory): implement.
        return []
    }

    public mutating func finish() -> [String] {
        // TODO(fork-voice-memory): implement.
        return []
    }
}
