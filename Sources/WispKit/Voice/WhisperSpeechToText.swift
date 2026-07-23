import Foundation
import AVFoundation

/// Upload-based STT against any OpenAI-compatible `/audio/transcriptions`
/// endpoint — local whisper.cpp servers, Groq's hosted Whisper, LM Studio,
/// or OpenAI itself. Same push-to-talk recording path as the ElevenLabs
/// engine; the server just speaks a different protocol. No streaming
/// partials — `onPartialTranscript` is unused.
public final class WhisperSpeechToText: SpeechToTextEngine {
    public var onPartialTranscript: ((String) -> Void)?
    public var onAudioLevel: ((Float) -> Void)?

    let baseURL: URL
    let model: String
    let apiKey: String?
    let session: URLSession
    private let recorder = MicRecorder()

    /// Clips shorter than this are treated as accidental taps.
    private let minimumClipSeconds = 0.3

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
        recorder.onLevel = { [weak self] level in self?.onAudioLevel?(level) }
        try recorder.start()
    }

    public func stopListening() async -> String {
        let seconds = recorder.capturedSeconds
        let wav = recorder.stop()
        guard seconds >= minimumClipSeconds else { return "" }
        do {
            return try await transcribe(wav: wav)
        } catch {
            return ""
        }
    }

    public func cancelListening() {
        recorder.abort()
    }

    /// The endpoint URL: appends `/audio/transcriptions` unless the base
    /// already ends with it (users paste both styles).
    var endpointURL: URL {
        if baseURL.path.hasSuffix("/audio/transcriptions") {
            return baseURL
        }
        return baseURL
            .appendingPathComponent("audio")
            .appendingPathComponent("transcriptions")
    }

    func transcribe(wav: Data) async throws -> String {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let boundary = "wisp-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(model)\r\n".utf8))
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SpeechToTextError.audioEngineFailed("transcription HTTP error")
        }
        struct TranscriptionResponse: Decodable { let text: String }
        let decoded = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        return decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
