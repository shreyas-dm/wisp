import Foundation
import AVFoundation
import Speech

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
/// + AVAudioEngine). On-device recognition is requested when available so
/// nothing leaves the machine.
public final class AppleSpeechToText: NSObject, SpeechToTextEngine {
    public var onPartialTranscript: ((String) -> Void)?
    public var onAudioLevel: ((Float) -> Void)?

    // A fresh engine per session keeps repeated start/stop cycles reliable;
    // reusing one engine across tap installs is a known source of
    // "required condition is false" crashes.
    private var audioEngine: AVAudioEngine?
    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    // Recognition callbacks arrive on arbitrary queues.
    private let stateLock = NSLock()
    private var latestPartialTranscript = ""
    private var finalTranscript: String?
    private var recognitionEnded = false

    public override init() {
        super.init()
    }

    public func requestPermissions() async -> Bool {
        let microphoneGranted = await AVCaptureDevice.requestAccess(for: .audio)
        let speechGranted = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        return microphoneGranted && speechGranted
    }

    public func startListening() throws {
        // Never prompt from here — permissions are onboarding's job.
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              SFSpeechRecognizer.authorizationStatus() == .authorized
        else {
            throw SpeechToTextError.permissionDenied
        }

        if audioEngine != nil {
            teardown()
        }

        let recognizer = SFSpeechRecognizer(locale: Locale.current)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.isAvailable else {
            throw SpeechToTextError.recognizerUnavailable
        }
        self.recognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        stateLock.lock()
        latestPartialTranscript = ""
        finalTranscript = nil
        recognitionEnded = false
        stateLock.unlock()

        let engine = AVAudioEngine()
        audioEngine = engine
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.recognitionRequest?.append(buffer)
            let level = Self.normalizedLevel(from: buffer)
            DispatchQueue.main.async { self.onAudioLevel?(level) }
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            self.stateLock.lock()
            if let result {
                let transcript = result.bestTranscription.formattedString
                self.latestPartialTranscript = transcript
                if result.isFinal {
                    self.finalTranscript = transcript
                    self.recognitionEnded = true
                }
            }
            if error != nil {
                self.recognitionEnded = true
            }
            let partial = self.latestPartialTranscript
            let ended = self.recognitionEnded
            self.stateLock.unlock()
            if !ended {
                DispatchQueue.main.async { self.onPartialTranscript?(partial) }
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            teardown()
            throw SpeechToTextError.audioEngineFailed(error.localizedDescription)
        }
    }

    public func stopListening() async -> String {
        recognitionRequest?.endAudio()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()

        // Give the recognizer up to ~2s to deliver its final result.
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            stateLock.lock()
            let ended = recognitionEnded
            stateLock.unlock()
            if ended { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        stateLock.lock()
        let transcript = finalTranscript ?? latestPartialTranscript
        stateLock.unlock()
        teardown()
        return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func cancelListening() {
        teardown()
    }

    private func teardown() {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        audioEngine = nil
        recognizer = nil
    }

    /// RMS of the buffer mapped through a dB curve to 0…1 for the waveform.
    private static func normalizedLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let frameCount = Int(buffer.frameLength)
        var sumOfSquares: Float = 0
        for sampleIndex in 0..<frameCount {
            let sample = channelData[sampleIndex]
            sumOfSquares += sample * sample
        }
        let rms = sqrt(sumOfSquares / Float(frameCount))
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        // Map -50 dB…0 dB to 0…1.
        let normalized = (decibels + 50) / 50
        return min(max(normalized, 0), 1)
    }
}
