import Foundation
import AVFoundation

/// Upload-based STT against any OpenAI-compatible `/audio/transcriptions`
/// endpoint — local whisper.cpp servers, Groq's hosted Whisper, LM Studio,
/// or OpenAI itself. Same push-to-talk recording path as the ElevenLabs
/// engine; the server just speaks a different protocol.
public final class WhisperSpeechToText: SpeechToTextEngine {
    public var onPartialTranscript: ((String) -> Void)?
    public var onAudioLevel: ((Float) -> Void)?

    let baseURL: URL
    let model: String
    let apiKey: String?
    let session: URLSession
    private let recorder = MicRecorder()

    public init(baseURL: URL, model: String = "whisper-1", apiKey: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.session = session
    }

    public func requestPermissions() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    public func startListening() throws {
        // TODO(fork-eval): implement (mirror ElevenLabsSpeechToText).
        throw SpeechToTextError.recognizerUnavailable
    }

    public func stopListening() async -> String {
        // TODO(fork-eval): implement (multipart file+model upload,
        // JSON {text} response, 15s timeout, "" on failure).
        ""
    }

    public func cancelListening() {
        recorder.abort()
    }
}
