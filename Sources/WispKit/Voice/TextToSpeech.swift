import Foundation
import AVFoundation

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

/// Local, key-free TTS via AVSpeechSynthesizer, tuned for the most pleasant
/// system voice installed (premium > enhanced > default quality).
public final class AppleTextToSpeech: NSObject, TextToSpeechEngine, AVSpeechSynthesizerDelegate {
    public var onFinished: (() -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?

    private let stateLock = NSLock()
    private var outstandingUtteranceCount = 0
    private var replyFinished = false

    public override init() {
        voice = Self.pickBestEnglishVoice()
        super.init()
        synthesizer.delegate = self
    }

    public var isSpeaking: Bool {
        stateLock.lock()
        let queued = outstandingUtteranceCount > 0
        stateLock.unlock()
        return queued || synthesizer.isSpeaking
    }

    public func enqueue(_ sentence: String) {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = voice
        utterance.rate = 0.52
        utterance.pitchMultiplier = 1.0

        stateLock.lock()
        outstandingUtteranceCount += 1
        replyFinished = false
        stateLock.unlock()

        // AVSpeechSynthesizer queues utterances natively, in order.
        synthesizer.speak(utterance)
    }

    public func finishReply() {
        stateLock.lock()
        replyFinished = true
        let drained = outstandingUtteranceCount == 0
        stateLock.unlock()
        if drained {
            DispatchQueue.main.async { self.onFinished?() }
        }
    }

    public func stop() {
        stateLock.lock()
        outstandingUtteranceCount = 0
        replyFinished = false
        stateLock.unlock()
        synthesizer.stopSpeaking(at: .immediate)
    }

    // MARK: - AVSpeechSynthesizerDelegate

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        utteranceCompleted()
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        utteranceCompleted()
    }

    private func utteranceCompleted() {
        stateLock.lock()
        outstandingUtteranceCount = max(0, outstandingUtteranceCount - 1)
        let drained = outstandingUtteranceCount == 0 && replyFinished
        stateLock.unlock()
        if drained {
            DispatchQueue.main.async { self.onFinished?() }
        }
    }

    /// Highest-quality installed English voice; named favorites break ties.
    private static func pickBestEnglishVoice() -> AVSpeechSynthesisVoice? {
        let englishVoices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
        guard !englishVoices.isEmpty else { return nil }

        let favoriteNames = ["Zoe", "Ava", "Samantha"]
        func rank(_ candidate: AVSpeechSynthesisVoice) -> (Int, Int) {
            let qualityRank: Int
            switch candidate.quality {
            case .premium: qualityRank = 0
            case .enhanced: qualityRank = 1
            default: qualityRank = 2
            }
            let nameRank = favoriteNames.firstIndex {
                candidate.name.contains($0) || candidate.identifier.contains($0)
            } ?? favoriteNames.count
            return (qualityRank, nameRank)
        }
        return englishVoices.min { rank($0) < rank($1) }
    }
}

/// Splits streamed text deltas into speakable sentences for the TTS queue.
/// Buffers until an unambiguous sentence boundary is seen; a boundary
/// character at the very end of the buffer is never cut (the next delta
/// could continue it, e.g. "3." + "14").
public struct SentenceChunker: Sendable {
    private var buffer = ""

    /// Sentences shorter than this wait and ride along with the next one.
    private let minimumSentenceLength = 12
    /// Once the buffer exceeds this without a sentence end, cut at the last
    /// clause boundary so TTS is not starved by run-on sentences.
    private let clauseSpillLength = 160

    private static let abbreviations: Set<String> = [
        "e.g.", "i.e.", "vs.", "etc.", "mr.", "mrs.", "ms.", "dr.", "st.",
        "no.", "approx.", "cf.", "al.",
    ]

    public init() {}

    public mutating func consume(_ delta: String) -> [String] {
        buffer += delta
        var emitted: [String] = []

        while let boundary = nextBoundaryIndex() {
            let cutIndex = buffer.index(after: boundary)
            let sentence = String(buffer[..<cutIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[cutIndex...])
            if !sentence.isEmpty {
                emitted.append(sentence)
            }
        }

        if let spilled = spillLongClauseIfNeeded() {
            emitted.append(spilled)
        }
        return emitted
    }

    public mutating func finish() -> [String] {
        let remainder = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return remainder.isEmpty ? [] : [remainder]
    }

    /// Index of the first character that ends a complete-enough sentence.
    private func nextBoundaryIndex() -> String.Index? {
        var index = buffer.startIndex
        while index < buffer.endIndex {
            let character = buffer[index]
            let isTerminator = character == "." || character == "!" || character == "?" || character == "…"
            let isNewline = character.isNewline

            if isTerminator || isNewline {
                // A terminator at the very end of the buffer may be
                // continued by the next delta — only newline is definitive
                // enough on its own, and even then min length applies.
                let nextIndex = buffer.index(after: index)
                let followedByWhitespace = nextIndex < buffer.endIndex && buffer[nextIndex].isWhitespace
                let candidate = buffer[..<buffer.index(after: index)]
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                let longEnough = candidate.count >= minimumSentenceLength
                if (isNewline || followedByWhitespace) && longEnough && !endsWithNonBoundaryToken(candidate) {
                    return index
                }
            }
            index = buffer.index(after: index)
        }
        return nil
    }

    /// True when the candidate's trailing token is an abbreviation or a
    /// bare number/version ("6.2.", "3.") rather than a sentence end.
    private func endsWithNonBoundaryToken(_ candidate: String) -> Bool {
        guard candidate.hasSuffix(".") else { return false }
        let lastToken = candidate.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? candidate
        if Self.abbreviations.contains(lastToken.lowercased()) {
            return true
        }
        // "6.2." / "3." — digits and dots only.
        let tokenWithoutDots = lastToken.replacingOccurrences(of: ".", with: "")
        if !tokenWithoutDots.isEmpty && tokenWithoutDots.allSatisfy({ $0.isNumber }) {
            return true
        }
        return false
    }

    private mutating func spillLongClauseIfNeeded() -> String? {
        guard buffer.count > clauseSpillLength else { return nil }
        let clauseBoundaries: Set<Character> = [",", ";", ":"]
        guard let lastBoundary = buffer.lastIndex(where: { clauseBoundaries.contains($0) }) else {
            return nil
        }
        let cutIndex = buffer.index(after: lastBoundary)
        let clause = String(buffer[..<cutIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = String(buffer[cutIndex...])
        return clause.isEmpty ? nil : clause
    }
}
