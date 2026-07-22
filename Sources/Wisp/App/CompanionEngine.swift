import AppKit
import Foundation
import SwiftUI
import WispKit

enum EngineState: Equatable {
    case idle
    case listening
    case thinking
    case responding
    case speaking
}

/// Central state machine: owns the push-to-talk pipeline from hotkey press
/// through snapshot capture, transcription, model streaming, tag handling,
/// voice replies, and memory writes. All UI observes this object.
@MainActor
final class CompanionEngine: ObservableObject {

    // MARK: - Published state

    @Published private(set) var state: EngineState = .idle
    @Published private(set) var partialTranscript = ""
    @Published private(set) var bubbleText = ""
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var sessionInputTokens = 0
    @Published private(set) var sessionOutputTokens = 0
    /// Number of turns in the current conversation; drives the menu panel's
    /// "New conversation" affordance.
    @Published private(set) var conversationTurnCount = 0
    @Published private(set) var activeProfileID: String
    @Published var voiceRepliesEnabled: Bool {
        didSet { persistConfigChanges() }
    }
    @Published var orbAlwaysVisible: Bool {
        didSet { persistConfigChanges() }
    }

    // MARK: - Collaborators

    /// Set by the app delegate after the overlay exists.
    weak var overlay: OverlayController?

    private(set) var config: WispConfig
    private let configStore: WispConfigStore
    private let secrets = SecretsStore()
    private let memory = MemoryStore()
    private let axCapture = AXTreeCapture()
    private let screenshotCapture = ScreenshotCapture()
    private var speechToText: SpeechToTextEngine
    private var textToSpeech: TextToSpeechEngine
    /// Tests inject fixed engines; skip factory re-resolution for those.
    private let voiceEnginesInjected: Bool

    // MARK: - Conversation state

    private var history: [ChatMessage] = []
    private var previousSnapshot: ScreenSnapshot?
    private var currentSnapshot: ScreenSnapshot?
    private var snapshotBlockForTurn: String?
    private var currentTurnTask: Task<Void, Never>?
    private var bubbleFadeTask: Task<Void, Never>?
    private var pendingTranscriptForScreenshotRetry: String?
    private var idleDistillationTask: Task<Void, Never>?
    private var distilledMessageCount = 0
    /// One provider instance per profile, reused across turns so the
    /// warmup throttle and connection pool actually help.
    private var cachedProvider: (profileID: String, provider: LLMProvider)?

    var profiles: [LLMModelProfile] { config.profiles }

    var activeProfile: LLMModelProfile? { config.activeProfile }

    init(
        configStore: WispConfigStore = WispConfigStore(),
        speechToText: SpeechToTextEngine? = nil,
        textToSpeech: TextToSpeechEngine? = nil
    ) {
        self.configStore = configStore
        let loadedConfig = configStore.load()
        self.config = loadedConfig
        let secretsStore = SecretsStore()
        // Voice engines resolve via the factory: ElevenLabs when its key is
        // present (state-of-the-art path), local Apple engines otherwise.
        self.voiceEnginesInjected = speechToText != nil || textToSpeech != nil
        self.speechToText = speechToText
            ?? VoiceEngineFactory.makeSpeechToText(config: loadedConfig, secrets: secretsStore)
        self.textToSpeech = textToSpeech
            ?? VoiceEngineFactory.makeTextToSpeech(config: loadedConfig, secrets: secretsStore)
        self.activeProfileID = config.activeProfileID
        self.voiceRepliesEnabled = config.voiceRepliesEnabled
        self.orbAlwaysVisible = config.orbAlwaysVisible

        attachTextToSpeechCallback()
    }

    private func attachTextToSpeechCallback() {
        textToSpeech.onFinished = { [weak self] in
            Task { @MainActor in
                guard let self, self.state == .speaking else { return }
                self.finishInteraction()
            }
        }
    }

    /// Re-runs the voice factory when idle so a newly added ELEVENLABS_API_KEY
    /// upgrades the voice on the very next interaction — no restart needed.
    /// Engines are only swapped when the resolved implementation changes.
    private func refreshVoiceEnginesIfNeeded() {
        guard !voiceEnginesInjected, state == .idle else { return }
        let resolvedSTT = VoiceEngineFactory.makeSpeechToText(config: config, secrets: secrets)
        if type(of: resolvedSTT) != type(of: speechToText) {
            speechToText = resolvedSTT
        }
        let resolvedTTS = VoiceEngineFactory.makeTextToSpeech(config: config, secrets: secrets)
        if type(of: resolvedTTS) != type(of: textToSpeech) {
            textToSpeech.stop()
            textToSpeech = resolvedTTS
            attachTextToSpeechCallback()
        }
    }

    private func provider(for profile: LLMModelProfile) -> LLMProvider {
        if let cached = cachedProvider, cached.profileID == profile.id {
            return cached.provider
        }
        let created = ProviderFactory.makeProvider(profile: profile, keyResolver: secrets)
        cachedProvider = (profile.id, created)
        return created
    }

    /// Pre-establish the provider connection while the user is speaking so
    /// the first token lands sooner.
    private func warmupActiveProvider() {
        guard let profile = config.activeProfile else { return }
        provider(for: profile).warmup()
    }

    // MARK: - Hotkey entry points

    func hotkeyPressed() {
        guard state == .idle else { return }
        refreshVoiceEnginesIfNeeded()
        warmupActiveProvider()
        cancelBubbleFade()
        state = .listening
        partialTranscript = ""
        bubbleText = ""
        overlay?.interactionStarted()

        captureSnapshotForTurn()

        speechToText.onPartialTranscript = { [weak self] transcript in
            Task { @MainActor in self?.partialTranscript = transcript }
        }
        speechToText.onAudioLevel = { [weak self] level in
            Task { @MainActor in self?.audioLevel = level }
        }
        do {
            try speechToText.startListening()
        } catch SpeechToTextError.permissionDenied {
            presentTransientMessage("I need microphone and speech permissions — open the menu bar panel to grant them.")
        } catch {
            presentTransientMessage("The microphone is unavailable right now.")
        }
    }

    func hotkeyReleased() {
        guard state == .listening else { return }
        currentTurnTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let transcript = await self.speechToText.stopListening()
            self.audioLevel = 0
            guard !transcript.isEmpty else {
                self.presentTransientMessage("I didn't catch that.")
                return
            }
            self.partialTranscript = transcript
            await self.runTurn(transcript: transcript, images: [], isScreenshotRetry: false)
        }
    }

    /// Text-driven entry point (menu panel, future integrations).
    func ask(_ text: String) {
        guard state == .idle, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        refreshVoiceEnginesIfNeeded()
        warmupActiveProvider()
        cancelBubbleFade()
        bubbleText = ""
        overlay?.interactionStarted()
        captureSnapshotForTurn()
        currentTurnTask = Task { @MainActor [weak self] in
            await self?.runTurn(transcript: text, images: [], isScreenshotRetry: false)
        }
    }

    func cancelInteraction() {
        currentTurnTask?.cancel()
        currentTurnTask = nil
        speechToText.cancelListening()
        textToSpeech.stop()
        audioLevel = 0
        partialTranscript = ""
        finishInteraction()
    }

    // MARK: - Settings

    func setProfile(id: String) {
        guard config.profiles.contains(where: { $0.id == id }) else { return }
        config.activeProfileID = id
        activeProfileID = id
        persistConfigChanges()
    }

    func persistSession() {
        guard !history.isEmpty else { return }
        try? memory.recordSession(messages: history)
    }

    /// Clears the conversation and session counters, logging the finished
    /// transcript first so nothing is lost.
    func resetConversation() {
        persistSession()
        idleDistillationTask?.cancel()
        idleDistillationTask = nil
        history = []
        previousSnapshot = nil
        currentSnapshot = nil
        snapshotBlockForTurn = nil
        distilledMessageCount = 0
        conversationTurnCount = 0
        sessionInputTokens = 0
        sessionOutputTokens = 0
        presentTransientMessage("Fresh start.")
    }

    // MARK: - Turn pipeline

    private func captureSnapshotForTurn() {
        guard AXTreeCapture.isAccessibilityTrusted() else {
            snapshotBlockForTurn = nil
            currentSnapshot = nil
            return
        }
        do {
            let snapshot = try axCapture.captureSnapshot()
            let serializer = SnapshotSerializer(tokenBudget: config.snapshotTokenBudget)
            if let previous = previousSnapshot,
               previous.appName == snapshot.appName,
               previous.windowTitle == snapshot.windowTitle {
                snapshotBlockForTurn = serializer.serializeDelta(from: previous, to: snapshot)
            } else {
                snapshotBlockForTurn = serializer.serialize(snapshot)
            }
            currentSnapshot = snapshot
            previousSnapshot = snapshot
        } catch {
            snapshotBlockForTurn = nil
            currentSnapshot = nil
        }
    }

    private func runTurn(transcript: String, images: [AttachedImage], isScreenshotRetry: Bool) async {
        guard let profile = config.activeProfile else {
            presentTransientMessage("No model profile selected — pick one in the menu bar panel.")
            return
        }

        state = .thinking
        let provider = provider(for: profile)
        let promptBuilder = PromptBuilder(config: config)

        // Screen context per the configured mode: hybrid (default) sends the
        // structured snapshot AND a downscaled screenshot every turn for
        // reliability; auto adds the screenshot only for sparse trees;
        // structure stays text-only. Non-vision profiles degrade to
        // structure automatically via effectiveScreenContextMode.
        let contextMode = config.effectiveScreenContextMode(for: profile)
        var turnImages = images
        if turnImages.isEmpty, ScreenshotCapture.hasScreenRecordingPermission() {
            let shouldAttachScreenshot: Bool
            switch contextMode {
            case .hybrid, .screenshot:
                shouldAttachScreenshot = true
            case .auto:
                // Sparse accessibility tree → the snapshot alone is probably
                // not enough (canvas apps, video, games).
                shouldAttachScreenshot = (currentSnapshot?.elements.count ?? 0) < 8
            case .structure:
                shouldAttachScreenshot = false
            }
            if shouldAttachScreenshot {
                let capturedImage = try? await screenshotCapture.captureDisplayJPEG(
                    displayIndex: focusedDisplayIndex(),
                    maxDimension: config.screenshotMaxDimension
                )
                if let capturedImage {
                    turnImages = [capturedImage]
                }
            }
        }

        // OCR fallback: a sparse accessibility tree with pixels available
        // usually means canvas/video/game content. Recognize its text
        // locally so any model — including text-only open models — can read
        // and point at it (t-prefixed element IDs).
        if config.ocrEnabled,
           let snapshot = currentSnapshot,
           snapshot.elements.count < 12,
           !snapshot.elements.contains(where: { $0.role == .ocrText }),
           ScreenshotCapture.hasScreenRecordingPermission() {
            let displayIndex = focusedDisplayIndex()
            var jpegForOCR = turnImages.first?.jpegData
            if jpegForOCR == nil {
                // Text-only profiles never attach a screenshot; capture one
                // solely for local recognition — it is never sent anywhere.
                jpegForOCR = (try? await screenshotCapture.captureDisplayJPEG(
                    displayIndex: displayIndex,
                    maxDimension: config.screenshotMaxDimension
                ))?.jpegData
            }
            if let jpegForOCR,
               snapshot.displays.indices.contains(displayIndex),
               var ocrElements = try? await OCRCapture().recognizeText(
                   inJPEG: jpegForOCR,
                   displayFrame: snapshot.displays[displayIndex].frame
               ),
               !ocrElements.isEmpty {
                for index in ocrElements.indices {
                    ocrElements[index].displayIndex = displayIndex
                }
                let merged = OCRCapture.merge(ocrElements: ocrElements, into: snapshot)
                currentSnapshot = merged
                previousSnapshot = merged
                snapshotBlockForTurn = SnapshotSerializer(tokenBudget: config.snapshotTokenBudget)
                    .serialize(merged)
            }
        }

        let request = promptBuilder.buildRequest(
            transcript: transcript,
            snapshotBlock: contextMode == .screenshot
                ? nil
                : (snapshotBlockForTurn ?? "(screen context unavailable)"),
            history: history,
            memoryProfile: memory.profile(tokenBudget: config.memoryTokenBudget),
            supportsVision: profile.supportsVision,
            images: turnImages
        )

        var tagParser = ResponseTagParser()
        var sentenceChunker = SentenceChunker()
        var displayedText = ""
        var wantsScreenshot = false
        var reportedUsage: LLMUsage?

        do {
            for try await event in provider.streamChat(request) {
                if Task.isCancelled { return }
                switch event {
                case .textDelta(let delta):
                    for chunk in tagParser.consume(delta) {
                        handleChunk(
                            chunk,
                            displayedText: &displayedText,
                            sentenceChunker: &sentenceChunker,
                            wantsScreenshot: &wantsScreenshot
                        )
                    }
                case .done(let usage):
                    reportedUsage = usage
                }
            }
        } catch {
            if Task.isCancelled { return }
            presentTransientMessage(Self.friendlyMessage(for: error, profile: profile))
            return
        }
        if Task.isCancelled { return }

        for chunk in tagParser.finish() {
            handleChunk(
                chunk,
                displayedText: &displayedText,
                sentenceChunker: &sentenceChunker,
                wantsScreenshot: &wantsScreenshot
            )
        }

        if let usage = reportedUsage {
            sessionInputTokens += usage.inputTokens ?? 0
            sessionOutputTokens += usage.outputTokens ?? 0
        } else {
            // Providers that do not report usage still count against the
            // session estimate so the token line stays honest-ish.
            sessionInputTokens += TokenEstimator.estimate(request.systemPrompt)
                + request.messages.reduce(0) { $0 + TokenEstimator.estimate($1.text) }
            sessionOutputTokens += TokenEstimator.estimate(displayedText)
        }

        // Screenshot fallback: the model asked to see pixels and this turn
        // didn't already include them. Re-send the same transcript once.
        if wantsScreenshot,
           !isScreenshotRetry,
           turnImages.isEmpty,
           profile.supportsVision,
           ScreenshotCapture.hasScreenRecordingPermission() {
            let displayIndex = focusedDisplayIndex()
            do {
                let image = try await screenshotCapture.captureDisplayJPEG(displayIndex: displayIndex, maxDimension: 1024)
                bubbleText = ""
                await runTurn(transcript: transcript, images: [image], isScreenshotRetry: true)
                return
            } catch {
                // Fall through and keep whatever text the model produced.
            }
        }

        let trimmedReply = displayedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedReply.isEmpty {
            history.append(request.messages.last ?? ChatMessage(role: .user, text: transcript))
            history.append(ChatMessage(role: .assistant, text: trimmedReply))
            history = PromptBuilder.compactHistory(history, turnLimit: config.historyTurnLimit)
            conversationTurnCount = history.count / 2
        }

        if voiceRepliesEnabled {
            for sentence in sentenceChunker.finish() {
                textToSpeech.enqueue(sentence)
            }
            textToSpeech.finishReply()
            if textToSpeech.isSpeaking {
                state = .speaking
            } else {
                finishInteraction()
            }
        } else {
            finishInteraction()
        }
    }

    private func handleChunk(
        _ chunk: ResponseChunk,
        displayedText: inout String,
        sentenceChunker: inout SentenceChunker,
        wantsScreenshot: inout Bool
    ) {
        switch chunk {
        case .text(let text):
            if state == .thinking { state = .responding }
            displayedText += text
            bubbleText = displayedText
            if voiceRepliesEnabled {
                for sentence in sentenceChunker.consume(text) {
                    textToSpeech.enqueue(sentence)
                }
            }
        case .tag(.point(let elementID)):
            pointAtElement(id: elementID)
        case .tag(.pointCoordinate(let x, let y, let displayIndex)):
            pointAtCoordinate(x: x, y: y, displayIndex: displayIndex)
        case .tag(.remember(let fact)):
            try? memory.appendFact(fact, source: "model")
        case .tag(.screenshotRequest):
            wantsScreenshot = true
        }
    }

    // MARK: - Pointing

    private func pointAtElement(id: String) {
        guard let snapshot = currentSnapshot,
              let element = snapshot.elements.first(where: { $0.id == id })
        else { return }
        let display = snapshot.displays.indices.contains(element.displayIndex)
            ? snapshot.displays[element.displayIndex]
            : snapshot.displays.first
        guard let display else { return }
        overlay?.point(atQuartzFrame: element.frame, on: display, label: element.title)
    }

    private func pointAtCoordinate(x: Double, y: Double, displayIndex: Int) {
        guard let snapshot = currentSnapshot else { return }
        let display = snapshot.displays.indices.contains(displayIndex)
            ? snapshot.displays[displayIndex]
            : snapshot.displays.first
        guard let display else { return }
        let frame = CGRect(x: x - 8, y: y - 8, width: 16, height: 16)
        overlay?.point(atQuartzFrame: frame, on: display, label: nil)
    }

    private func focusedDisplayIndex() -> Int {
        guard let snapshot = currentSnapshot else { return 0 }
        if let focusedID = snapshot.focusedElementID,
           let focused = snapshot.elements.first(where: { $0.id == focusedID }) {
            return focused.displayIndex
        }
        return 0
    }

    // MARK: - Interaction lifecycle

    private func finishInteraction() {
        state = .idle
        overlay?.interactionEnded()
        scheduleBubbleFade()
        scheduleIdleDistillation()
    }

    /// Continual learning: three quiet minutes after a conversation, distill
    /// durable user facts from the new turns into the memory store. Cheap
    /// housekeeping call; skipped for the demo profile and rescheduled
    /// whenever activity resumes.
    private func scheduleIdleDistillation() {
        idleDistillationTask?.cancel()
        guard history.count > distilledMessageCount,
              let profile = config.activeProfile,
              profile.model != "mock"
        else { return }
        idleDistillationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000_000)
            guard !Task.isCancelled, let self, self.state == .idle else { return }
            let startIndex = min(self.distilledMessageCount, self.history.count)
            let newMessages = Array(self.history.suffix(from: startIndex))
            guard !newMessages.isEmpty else { return }
            self.distilledMessageCount = self.history.count
            await MemoryDistiller(store: self.memory)
                .distill(messages: newMessages, using: self.provider(for: profile))
        }
    }

    /// Shows a short informational message in the bubble and returns to idle.
    private func presentTransientMessage(_ message: String) {
        bubbleText = message
        finishInteraction()
    }

    private func scheduleBubbleFade() {
        cancelBubbleFade()
        guard !bubbleText.isEmpty else { return }
        bubbleFadeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            self?.bubbleText = ""
            self?.partialTranscript = ""
        }
    }

    private func cancelBubbleFade() {
        bubbleFadeTask?.cancel()
        bubbleFadeTask = nil
    }

    private func persistConfigChanges() {
        config.voiceRepliesEnabled = voiceRepliesEnabled
        config.orbAlwaysVisible = orbAlwaysVisible
        try? configStore.save(config)
    }

    // MARK: - Errors

    static func friendlyMessage(for error: Error, profile: LLMModelProfile) -> String {
        switch error {
        case LLMProviderError.missingAPIKey(let ref):
            return "No API key for \(profile.displayName). Run: wisp key set \(ref)"
        case LLMProviderError.httpError(let status, _):
            return "\(profile.displayName) returned HTTP \(status)."
        case LLMProviderError.network:
            return "Couldn't reach \(profile.displayName) — check your connection."
        case LLMProviderError.malformedResponse:
            return "\(profile.displayName) sent a response I couldn't read."
        case LLMProviderError.cancelled:
            return ""
        default:
            return "Something went wrong talking to \(profile.displayName)."
        }
    }
}
