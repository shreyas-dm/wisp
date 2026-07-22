import Foundation
import AVFoundation

/// Records push-to-talk audio to an in-memory 16 kHz mono PCM16 buffer for
/// upload-based STT engines, reporting live levels for the waveform.
/// Never triggers a permission prompt — callers guard authorization.
final class MicRecorder {
    var onLevel: ((Float) -> Void)?

    private var audioEngine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var pcmData = Data()
    private let lock = NSLock()

    static let sampleRate: Double = 16000

    private static var targetFormat: AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        )!
    }

    var isRecording: Bool { audioEngine != nil }

    func start() throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw SpeechToTextError.permissionDenied
        }
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw SpeechToTextError.audioEngineFailed("no input device")
        }
        let converter = AVAudioConverter(from: inputFormat, to: Self.targetFormat)

        lock.lock()
        pcmData.removeAll()
        lock.unlock()

        inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.reportLevel(of: buffer)
            self.appendConverted(buffer, using: converter)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw SpeechToTextError.audioEngineFailed(error.localizedDescription)
        }
        self.audioEngine = engine
        self.converter = converter
    }

    /// Stops and returns the captured audio as a WAV file payload.
    func stop() -> Data {
        teardown()
        lock.lock()
        defer { lock.unlock() }
        return Self.wavData(fromPCM16: pcmData, sampleRate: Int(Self.sampleRate), channels: 1)
    }

    func abort() {
        teardown()
        lock.lock()
        pcmData.removeAll()
        lock.unlock()
    }

    var capturedSeconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(pcmData.count) / 2.0 / Self.sampleRate
    }

    private func teardown() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        converter = nil
    }

    private func reportLevel(of buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) {
            sum += channel[i] * channel[i]
        }
        let rms = sqrt(sum / Float(buffer.frameLength))
        // Map roughly -50 dB…0 dB to 0…1.
        let db = 20 * log10(max(rms, 1e-7))
        let level = max(0, min(1, (db + 50) / 50))
        let callback = onLevel
        DispatchQueue.main.async { callback?(level) }
    }

    private func appendConverted(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter?) {
        guard let converter else { return }
        let ratio = Self.targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: Self.targetFormat, frameCapacity: capacity) else { return }

        var fed = false
        converter.convert(to: output, error: nil) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard output.frameLength > 0, let int16Channel = output.int16ChannelData?[0] else { return }
        let byteCount = Int(output.frameLength) * 2
        lock.lock()
        pcmData.append(Data(bytes: int16Channel, count: byteCount))
        lock.unlock()
    }

    /// Builds a RIFF/WAVE payload around raw little-endian PCM16 samples.
    static func wavData(fromPCM16 pcm: Data, sampleRate: Int, channels: Int) -> Data {
        let bytesPerSample = 2
        let byteRate = sampleRate * channels * bytesPerSample
        let blockAlign = channels * bytesPerSample

        var data = Data()
        func appendUInt32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func appendUInt16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: Array("RIFF".utf8))
        appendUInt32(UInt32(36 + pcm.count))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendUInt32(16)
        appendUInt16(1) // PCM
        appendUInt16(UInt16(channels))
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(byteRate))
        appendUInt16(UInt16(blockAlign))
        appendUInt16(16) // bits per sample
        data.append(contentsOf: Array("data".utf8))
        appendUInt32(UInt32(pcm.count))
        data.append(pcm)
        return data
    }
}
