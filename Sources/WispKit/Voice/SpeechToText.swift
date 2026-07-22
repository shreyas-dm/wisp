import Foundation

/// Push-to-talk transcription backend. The engine is started when the
/// hotkey goes down and stopped when it is released; `stopListening`
/// resolves with the final transcript.
public protocol SpeechToTextEngine: AnyObject {
    /// Live partial transcript for UI feedback.
    var onPartialTranscript: ((String) -> Void)? { get set }
    /// 0…1 microphone level for the waveform.
    var onAudioLevel: ((Float) -> Void)? { get set }

    /// Requests mic + speech permissions. Returns whether both granted.
    func requestPermissions() async -> Bool
    func startListening() throws
    /// Stops capture and returns the final transcript (empty if none).
    func stopListening() async -> String
    /// Aborts without a transcript.
    func cancelListening()
}

public enum SpeechToTextError: Error, Sendable {
    case permissionDenied
    case audioEngineFailed(String)
    case recognizerUnavailable
}

/// Local, key-free STT built on Apple's Speech framework (SFSpeechRecognizer
/// + AVAudioEngine). On-device recognition is requested when available.
public final class AppleSpeechToText: SpeechToTextEngine {
    public var onPartialTranscript: ((String) -> Void)?
    public var onAudioLevel: ((Float) -> Void)?

    public init() {}

    public func requestPermissions() async -> Bool {
        // TODO(fork-voice-memory): implement.
        false
    }

    public func startListening() throws {
        // TODO(fork-voice-memory): implement.
        throw SpeechToTextError.recognizerUnavailable
    }

    public func stopListening() async -> String {
        // TODO(fork-voice-memory): implement.
        ""
    }

    public func cancelListening() {
        // TODO(fork-voice-memory): implement.
    }
}
