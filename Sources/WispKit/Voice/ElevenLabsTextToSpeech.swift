import Foundation
import AVFoundation

/// Streaming-friendly TTS via the ElevenLabs API. Sentences are synthesized
/// one at a time on a serial worker; while one plays, the next is already
/// being fetched, so speech flows without gaps. Network failures skip the
/// affected sentence rather than aborting the reply.
public final class ElevenLabsTextToSpeech: NSObject, TextToSpeechEngine {
    public var onFinished: (() -> Void)?

    private let apiKey: String
    private let voiceID: String
    private let modelID: String
    private let session: URLSession

    private var queue: [String] = []
    private var replyFinished = false
    private var worker: Task<Void, Never>?
    private var player: AVAudioPlayer?
    private var playbackContinuation: CheckedContinuation<Void, Never>?
    private var speaking = false
    private let stateLock = NSLock()

    public init(
        apiKey: String,
        voiceID: String = "21m00Tcm4TlvDq8ikWAM",
        modelID: String = "eleven_flash_v2_5",
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.voiceID = voiceID
        self.modelID = modelID
        self.session = session
    }

    public var isSpeaking: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return speaking || !queue.isEmpty
    }

    public func enqueue(_ sentence: String) {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stateLock.lock()
        queue.append(trimmed)
        replyFinished = false
        stateLock.unlock()
        startWorkerIfNeeded()
    }

    public func finishReply() {
        stateLock.lock()
        replyFinished = true
        let idle = queue.isEmpty && !speaking && worker == nil
        stateLock.unlock()
        if idle {
            DispatchQueue.main.async { self.onFinished?() }
        }
    }

    public func stop() {
        stateLock.lock()
        queue.removeAll()
        replyFinished = false
        let runningWorker = worker
        worker = nil
        stateLock.unlock()

        runningWorker?.cancel()
        player?.stop()
        player = nil
        resumePlayback()
        stateLock.lock()
        speaking = false
        stateLock.unlock()
    }

    private func startWorkerIfNeeded() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard worker == nil else { return }
        speaking = true
        worker = Task { [weak self] in
            await self?.drainQueue()
        }
    }

    private func drainQueue() async {
        var prefetch: (sentence: String, task: Task<Data?, Never>)?

        while !Task.isCancelled {
            stateLock.lock()
            let next = queue.isEmpty ? nil : queue.removeFirst()
            stateLock.unlock()

            guard let sentence = next else { break }

            let audio: Data?
            if let ready = prefetch, ready.sentence == sentence {
                audio = await ready.task.value
            } else {
                audio = await fetchAudio(for: sentence)
            }
            prefetch = nil

            // Kick off the fetch for the following sentence before playing.
            stateLock.lock()
            let upcoming = queue.first
            stateLock.unlock()
            if let upcoming {
                let task = Task { await self.fetchAudio(for: upcoming) }
                prefetch = (upcoming, task)
            }

            if let audio, !Task.isCancelled {
                await play(audio)
            }
        }

        prefetch?.task.cancel()

        stateLock.lock()
        speaking = false
        worker = nil
        let done = replyFinished && queue.isEmpty
        stateLock.unlock()
        if done && !Task.isCancelled {
            DispatchQueue.main.async { self.onFinished?() }
        }
    }

    private func fetchAudio(for sentence: String) async -> Data? {
        var request = URLRequest(
            url: URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceID)?output_format=mp3_44100_128")!
        )
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["text": sentence, "model_id": modelID]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }
        return data
    }

    @MainActor
    private func play(_ audio: Data) async {
        guard let audioPlayer = try? AVAudioPlayer(data: audio) else { return }
        player = audioPlayer
        audioPlayer.delegate = self
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            stateLock.lock()
            playbackContinuation = continuation
            stateLock.unlock()
            if !audioPlayer.play() {
                resumePlayback()
            }
        }
        player = nil
    }

    private func resumePlayback() {
        stateLock.lock()
        let continuation = playbackContinuation
        playbackContinuation = nil
        stateLock.unlock()
        continuation?.resume()
    }
}

extension ElevenLabsTextToSpeech: AVAudioPlayerDelegate {
    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        resumePlayback()
    }

    public func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        resumePlayback()
    }
}
