import Foundation
import AVFoundation

/// Upload-based STT via the ElevenLabs Speech-to-Text API (Scribe).
/// Push-to-talk records locally (with live levels for the waveform); the
/// bounded clip is uploaded on release and the final transcript returned.
/// No streaming partials — `onPartialTranscript` is unused.
public final class ElevenLabsSpeechToText: SpeechToTextEngine {
    public var onPartialTranscript: ((String) -> Void)?
    public var onAudioLevel: ((Float) -> Void)?

    private let apiKey: String
    private let modelID: String
    private let session: URLSession
    private let recorder = MicRecorder()

    /// Clips shorter than this are treated as accidental taps.
    private let minimumClipSeconds = 0.3

    public init(apiKey: String, modelID: String = "scribe_v1", session: URLSession = .shared) {
        self.apiKey = apiKey
        self.modelID = modelID
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

    private func transcribe(wav: Data) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        let boundary = "wisp-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        appendField("model_id", modelID)
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
