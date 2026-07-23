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
    /// Guided walkthrough in progress (1-based step index).
    case walkthrough(stepIndex: Int, total: Int)
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
    /// Instruction of the walkthrough step currently presented, for the
    /// step chip.
    @Published private(set) var currentWalkthroughStep: WalkthroughStep?
    /// Last turn's latency breakdown, for the menu panel.
    @Published private(set) var lastTurnSummary: String?
    @Published var voiceRepliesEnabled: Bool {
        didSet { persistConfigChanges() }
    }
    @Published var orbAlwaysVisible: Bool {
        didSet { persistConfigChanges() }
    }
    @Published var activityLogEnabled: Bool {
        didSet {
            persistConfigChanges()
            onActivityLogToggled?(activityLogEnabled)
        }
    }
    /// AppDelegate hook: starts/stops the activity tracker on toggle.
    var onActivityLogToggled: ((Bool) -> Void)?

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

    // MARK: - Walkthrough state

    /// Steps collected from the current stream.
    private var streamingStepPlan = StepPlanBuilder()
    /// The active plan and the snapshot it was planned against (element
    /// re-resolution matches role+title from this snapshot).
    private var walkthroughPlan: [WalkthroughStep] = []
    private var walkthroughPlanTargets: [Int: (role: ElementRole, title: String?)] = [:]
    /// Snapshot at the moment the current step was presented — the
    /// "previous" side of the completion heuristic.
    private var walkthroughBaseline: ScreenSnapshot?
    private var walkthroughPollTask: Task<Void, Never>?

    // MARK: - Recall & metrics state

    /// Set when the model emits [[recall:…]]; consumed once per question.
    private var pendingRecallQuery: String?
    private let metricsLog = MetricsLog()
    private var metrics: TurnMetrics?
    private var lastCaptureMs: Double?
    private var speechStartedMidStream = false

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
        self.activityLogEnabled = config.activityLogEnabled

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
        // A fresh push-to-talk during a walkthrough abandons it first.
        if case .walkthrough = state { exitWalkthrough(showDone: false) }
        guard state == .idle else { return }
        refreshVoiceEnginesIfNeeded()
        warmupActiveProvider()
        cancelBubbleFade()
        state = .listening
        partialTranscript = ""
        bubbleText = ""
        overlay?.interactionStarted()
        metrics = TurnMetrics(profileID: config.activeProfileID)

        captureSnapshotForTurn()
        metrics?.captureMs = lastCaptureMs

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
            let sttStartedAt = Date()
            let transcript = await self.speechToText.stopListening()
            self.metrics?.sttMs = Date().timeIntervalSince(sttStartedAt) * 1000
            self.audioLevel = 0
            guard !transcript.isEmpty else {
                self.presentTransientMessage("I didn't catch that.")
                return
            }
            self.partialTranscript = transcript
            await self.runTurn(transcript: transcript, images: [])
        }
    }

    /// Text-driven entry point (menu panel, future integrations).
    func ask(_ text: String) {
        if case .walkthrough = state { exitWalkthrough(showDone: false) }
        guard state == .idle, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        refreshVoiceEnginesIfNeeded()
        warmupActiveProvider()
        cancelBubbleFade()
        bubbleText = ""
        overlay?.interactionStarted()
        metrics = TurnMetrics(profileID: config.activeProfileID)
        captureSnapshotForTurn()
        metrics?.captureMs = lastCaptureMs
        currentTurnTask = Task { @MainActor [weak self] in
            await self?.runTurn(transcript: text, images: [])
        }
    }

    func cancelInteraction() {
        if case .walkthrough = state {
            exitWalkthrough(showDone: false)
            return
        }
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
        let captureStartedAt = Date()
        defer { lastCaptureMs = Date().timeIntervalSince(captureStartedAt) * 1000 }
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

    private func runTurn(
        transcript: String,
        images: [AttachedImage],
        isScreenshotRetry: Bool = false,
        isRecallRetry: Bool = false
    ) async {
        guard let profile = config.activeProfile else {
            presentTransientMessage("No model profile selected — pick one in the menu bar panel.")
            return
        }

        state = .thinking
        let provider = provider(for: profile)
        let promptBuilder = PromptBuilder(config: config)
        streamingStepPlan = StepPlanBuilder()
        if !isRecallRetry { pendingRecallQuery = nil }
        speechStartedMidStream = false

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
            let ocrStartedAt = Date()
            defer { metrics?.ocrMs = Date().timeIntervalSince(ocrStartedAt) * 1000 }
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
        let requestSentAt = Date()
        var firstTokenAt: Date?

        do {
            for try await event in provider.streamChat(request) {
                if Task.isCancelled { return }
                switch event {
                case .textDelta(let delta):
                    if firstTokenAt == nil {
                        firstTokenAt = Date()
                        metrics?.firstTokenMs = firstTokenAt!.timeIntervalSince(requestSentAt) * 1000
                    }
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
                    metrics?.streamMs = Date().timeIntervalSince(requestSentAt) * 1000
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
        metrics?.inputTokens = reportedUsage?.inputTokens
        metrics?.outputTokens = reportedUsage?.outputTokens
        metrics?.snapshotTokens = snapshotBlockForTurn.map { TokenEstimator.estimate($0) }

        // Recall: the model asked to search local memory. Search, then
        // re-send the same question once with what was found.
        if let recallQuery = pendingRecallQuery, !isRecallRetry {
            pendingRecallQuery = nil
            bubbleText = "remembering…"
            textToSpeech.stop()
            let hits = MemorySearch(store: memory).search(query: recallQuery)
            let recalledBlock = MemorySearch.renderHits(hits, query: recallQuery)
            await runTurn(
                transcript: "[Recalled context]\n\(recalledBlock)\n\n\(transcript)",
                images: turnImages,
                isScreenshotRetry: isScreenshotRetry,
                isRecallRetry: true
            )
            return
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

        let plannedSteps = streamingStepPlan.steps
        let trimmedReply = displayedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedReply.isEmpty || !plannedSteps.isEmpty {
            // Steps go into history in tag form so follow-up questions see
            // the plan the model committed to.
            let historyReply = trimmedReply
                + plannedSteps.map { "\n[[step:\($0.elementID):\($0.instruction)]]" }.joined()
            history.append(request.messages.last ?? ChatMessage(role: .user, text: transcript))
            history.append(ChatMessage(role: .assistant, text: historyReply))
            history = PromptBuilder.compactHistory(history, turnLimit: config.historyTurnLimit)
            conversationTurnCount = history.count / 2
        }

        if voiceRepliesEnabled {
            let speechStartAt = Date()
            for sentence in sentenceChunker.finish() {
                textToSpeech.enqueue(sentence)
            }
            textToSpeech.finishReply()
            metrics?.ttsStartMs = speechStartedMidStream ? 0 : Date().timeIntervalSince(speechStartAt) * 1000
        }
        finalizeMetrics()

        if !plannedSteps.isEmpty {
            startWalkthrough(plannedSteps)
            return
        }

        if voiceRepliesEnabled, textToSpeech.isSpeaking {
            state = .speaking
        } else {
            finishInteraction()
        }
    }

    private func finalizeMetrics() {
        guard let finished = metrics else { return }
        metricsLog.append(finished)
        lastTurnSummary = finished.summaryLine
        metrics = nil
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
                    speechStartedMidStream = true
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
        case .tag(.step(let elementID, let instruction)):
            // Steps are collected silently and presented one at a time
            // after the stream ends — not spoken as they arrive.
            streamingStepPlan.addStep(elementID: elementID, instruction: instruction)
        case .tag(.recall(let query)):
            if pendingRecallQuery == nil {
                pendingRecallQuery = query
            }
        }
    }

    // MARK: - Guided walkthrough

    private func startWalkthrough(_ steps: [WalkthroughStep]) {
        walkthroughPlan = steps
        // Remember each target's identity from the planning snapshot so a
        // step can be re-found after the screen changes and IDs shift.
        walkthroughPlanTargets = [:]
        if let snapshot = currentSnapshot {
            for step in steps {
                if let element = snapshot.elements.first(where: { $0.id == step.elementID }) {
                    walkthroughPlanTargets[step.index] = (element.role, element.title)
                }
            }
        }
        presentWalkthroughStep(index: 1)
        startWalkthroughPolling()
    }

    func walkthroughNext() {
        guard case .walkthrough(let stepIndex, let total) = state else { return }
        if stepIndex >= total {
            exitWalkthrough(showDone: true)
        } else {
            presentWalkthroughStep(index: stepIndex + 1)
        }
    }

    func walkthroughBack() {
        guard case .walkthrough(let stepIndex, _) = state, stepIndex > 1 else { return }
        presentWalkthroughStep(index: stepIndex - 1)
    }

    func exitWalkthrough(showDone: Bool) {
        walkthroughPollTask?.cancel()
        walkthroughPollTask = nil
        walkthroughPlan = []
        walkthroughPlanTargets = [:]
        walkthroughBaseline = nil
        currentWalkthroughStep = nil
        textToSpeech.stop()
        if showDone {
            presentTransientMessage("Done ✓")
        } else {
            state = .idle
            overlay?.interactionEnded()
            scheduleBubbleFade()
        }
    }

    private func presentWalkthroughStep(index: Int) {
        guard let step = walkthroughPlan.first(where: { $0.index == index }) else {
            exitWalkthrough(showDone: true)
            return
        }
        state = .walkthrough(stepIndex: index, total: walkthroughPlan.count)
        currentWalkthroughStep = step
        bubbleText = ""
        // Re-snapshot so both pointing and the completion baseline reflect
        // the screen as the step begins.
        if AXTreeCapture.isAccessibilityTrusted(), let fresh = try? axCapture.captureSnapshot() {
            currentSnapshot = fresh
            previousSnapshot = fresh
        }
        walkthroughBaseline = currentSnapshot

        if let element = resolveWalkthroughTarget(step: step, in: currentSnapshot) {
            let display = currentSnapshot?.displays.indices.contains(element.displayIndex) == true
                ? currentSnapshot!.displays[element.displayIndex]
                : currentSnapshot?.displays.first
            if let display {
                overlay?.point(atQuartzFrame: element.frame, on: display, label: element.title)
            }
        }

        if voiceRepliesEnabled {
            textToSpeech.enqueue("Step \(index). \(step.instruction)")
            textToSpeech.finishReply()
        }
    }

    /// Finds the step's target in a snapshot: by ID when it still resolves,
    /// otherwise by the role+title recorded at planning time (IDs shift as
    /// the screen changes).
    private func resolveWalkthroughTarget(step: WalkthroughStep, in snapshot: ScreenSnapshot?) -> SnapshotElement? {
        guard let snapshot else { return nil }
        if let byID = snapshot.elements.first(where: { $0.id == step.elementID }) {
            if let original = walkthroughPlanTargets[step.index] {
                if byID.role == original.role && byID.title == original.title {
                    return byID
                }
            } else {
                return byID
            }
        }
        if let original = walkthroughPlanTargets[step.index] {
            return snapshot.elements.first {
                $0.role == original.role && $0.title == original.title
            }
        }
        return nil
    }

    /// Watches the screen while a walkthrough is active and advances when
    /// the current step looks completed.
    private func startWalkthroughPolling() {
        walkthroughPollTask?.cancel()
        guard AXTreeCapture.isAccessibilityTrusted() else { return }
        walkthroughPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard !Task.isCancelled, let self else { return }
                guard case .walkthrough = self.state,
                      let step = self.currentWalkthroughStep,
                      let baseline = self.walkthroughBaseline,
                      let fresh = try? self.axCapture.captureSnapshot()
                else { continue }
                if StepPlanBuilder.looksCompleted(step: step, previous: baseline, current: fresh) {
                    self.currentSnapshot = fresh
                    self.previousSnapshot = fresh
                    self.walkthroughNext()
                } else {
                    // Keep the baseline fresh enough that slow drifts (live
                    // content, clocks) don't accumulate into a false advance,
                    // but never replace it mid-gesture: only adopt the fresh
                    // snapshot as baseline when nothing about the step's
                    // target changed.
                    self.walkthroughBaseline = baseline
                }
            }
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
        config.activityLogEnabled = activityLogEnabled
        try? configStore.save(config)
    }

    var customInstructions: String? { config.customInstructions }

    func setCustomInstructions(_ text: String?) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        config.customInstructions = (trimmed?.isEmpty ?? true) ? nil : trimmed
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
