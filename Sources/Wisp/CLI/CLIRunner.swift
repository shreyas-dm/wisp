import Darwin
import Foundation
import WispKit

/// Headless subcommands: everything Wisp can do without its UI, usable over
/// SSH and in scripts. Runs on the main actor (AX capture requires it).
@MainActor
enum CLIRunner {
    static func run(arguments: [String]) async -> Int32 {
        guard let command = arguments.first else {
            printUsage()
            return 64
        }
        let rest = Array(arguments.dropFirst())

        switch command {
        case "version", "--version", "-v":
            print("wisp 0.1.0")
            return 0
        case "snapshot":
            return await runSnapshot(rest)
        case "ask":
            return await runAsk(rest)
        case "doctor":
            return await runDoctor()
        case "key":
            return runKey(rest)
        case "memory":
            return runMemory(rest)
        case "help", "--help", "-h":
            printUsage()
            return 0
        default:
            fputs("wisp: unknown command '\(command)'\n\n", stderr)
            printUsage()
            return 64
        }
    }

    private static func printUsage() {
        print(
            """
            wisp — an AI companion for your screen

            USAGE
              wisp                     launch the menu bar app
              wisp snapshot [--budget N] [--delta] [--json]
                                       print the semantic snapshot of the frontmost app
              wisp ask "question" [--voice] [--profile ID]
                                       one-shot question with screen context
              wisp doctor              check permissions, config, and connectivity
              wisp key set|list|delete [REF]
                                       manage API keys (stored in the Keychain)
              wisp memory list|clear   inspect or reset what Wisp remembers
              wisp version             print the version
            """
        )
    }

    // MARK: - snapshot

    private static func runSnapshot(_ arguments: [String]) async -> Int32 {
        guard AXTreeCapture.isAccessibilityTrusted() else {
            fputs(
                """
                wisp: Accessibility permission is required for snapshots.
                Grant it in System Settings › Privacy & Security › Accessibility
                (add your terminal, or Wisp.app if you launched the app), then rerun.
                """ + "\n",
                stderr
            )
            return 1
        }

        var tokenBudget = 1200
        if let budgetIndex = arguments.firstIndex(of: "--budget"),
           budgetIndex + 1 < arguments.count,
           let parsed = Int(arguments[budgetIndex + 1]) {
            tokenBudget = parsed
        }
        let wantsDelta = arguments.contains("--delta")
        let wantsJSON = arguments.contains("--json")

        let capture = AXTreeCapture()
        let serializer = SnapshotSerializer(tokenBudget: tokenBudget)
        do {
            let snapshot = try capture.captureSnapshot()
            if wantsJSON {
                print(try renderSnapshotJSON(snapshot))
                return 0
            }
            let block: String
            if wantsDelta {
                print("(capturing again in 2s for the delta — change something on screen…)")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let second = try capture.captureSnapshot()
                block = serializer.serializeDelta(from: snapshot, to: second)
            } else {
                block = serializer.serialize(snapshot)
            }
            print(block)
            let tokenEstimate = TokenEstimator.estimate(block)
            print("≈ \(tokenEstimate) tokens, \(snapshot.elements.count) elements captured")
            return 0
        } catch {
            fputs("wisp: snapshot failed: \(error)\n", stderr)
            return 1
        }
    }

    /// Machine-readable snapshot for scripting and debugging.
    private static func renderSnapshotJSON(_ snapshot: ScreenSnapshot) throws -> String {
        var root: [String: Any] = [
            "app": snapshot.appName,
            "capturedAt": ISO8601DateFormatter().string(from: snapshot.capturedAt),
            "displays": snapshot.displays.map { display in
                [
                    "index": display.index,
                    "isMain": display.isMain,
                    "frame": ["x": display.frame.origin.x, "y": display.frame.origin.y,
                              "w": display.frame.width, "h": display.frame.height],
                ] as [String: Any]
            },
            "elements": snapshot.elements.map { element in
                var entry: [String: Any] = [
                    "id": element.id,
                    "role": element.role.rawValue,
                    "frame": ["x": element.frame.origin.x, "y": element.frame.origin.y,
                              "w": element.frame.width, "h": element.frame.height],
                    "depth": element.depth,
                    "interactive": element.isInteractive,
                    "display": element.displayIndex,
                ]
                if let title = element.title { entry["title"] = title }
                if let value = element.value { entry["value"] = value }
                if element.isFocused { entry["focused"] = true }
                return entry
            },
        ]
        if let bundleID = snapshot.appBundleID { root["bundleID"] = bundleID }
        if let windowTitle = snapshot.windowTitle { root["window"] = windowTitle }
        if let focusedElementID = snapshot.focusedElementID { root["focused"] = focusedElementID }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: - ask

    private static func runAsk(_ arguments: [String]) async -> Int32 {
        var wantsVoice = false
        var profileOverride: String?
        var questionParts: [String] = []
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--voice":
                wantsVoice = true
            case "--profile":
                if index + 1 < arguments.count {
                    profileOverride = arguments[index + 1]
                    index += 1
                }
            default:
                questionParts.append(arguments[index])
            }
            index += 1
        }
        let question = questionParts.joined(separator: " ")
        guard !question.isEmpty else {
            fputs("wisp: usage: wisp ask \"question\" [--voice] [--profile ID]\n", stderr)
            return 64
        }

        let configStore = WispConfigStore()
        let config = configStore.load()
        let selectedProfile = profileOverride.flatMap { override in
            config.profiles.first { $0.id == override }
        } ?? config.activeProfile
        guard let profile = selectedProfile else {
            if let profileOverride {
                let available = config.profiles.map(\.id).joined(separator: ", ")
                fputs("wisp: profile '\(profileOverride)' not found — available: \(available)\n", stderr)
            } else {
                fputs("wisp: active profile '\(config.activeProfileID)' not found — check ~/.wisp/config.json\n", stderr)
            }
            return 1
        }
        // Keep prompt building consistent with the selected profile even
        // when --profile overrides the configured active one.
        var effectiveConfig = config
        effectiveConfig.activeProfileID = profile.id

        let secrets = SecretsStore()
        let memory = MemoryStore()

        // Screen context (best effort — CLI works without it).
        var snapshotBlock: String?
        var snapshot: ScreenSnapshot?
        if AXTreeCapture.isAccessibilityTrusted() {
            let capture = AXTreeCapture()
            if let captured = try? capture.captureSnapshot() {
                snapshot = captured
                snapshotBlock = SnapshotSerializer(tokenBudget: config.snapshotTokenBudget).serialize(captured)
            }
        }

        // Screenshot per screen-context mode, same policy as the app.
        var images: [AttachedImage] = []
        let contextMode = config.effectiveScreenContextMode(for: profile)
        let shouldAttachScreenshot: Bool
        switch contextMode {
        case .hybrid, .screenshot: shouldAttachScreenshot = true
        case .auto: shouldAttachScreenshot = (snapshot?.elements.count ?? 0) < 8
        case .structure: shouldAttachScreenshot = false
        }
        if shouldAttachScreenshot, ScreenshotCapture.hasScreenRecordingPermission() {
            if let image = try? await ScreenshotCapture().captureDisplayJPEG(
                displayIndex: 0,
                maxDimension: config.screenshotMaxDimension
            ) {
                images = [image]
            }
        }

        let request = PromptBuilder(config: effectiveConfig).buildRequest(
            transcript: question,
            snapshotBlock: contextMode == .screenshot ? nil : snapshotBlock,
            history: [],
            memoryProfile: memory.profile(tokenBudget: config.memoryTokenBudget),
            supportsVision: profile.supportsVision,
            images: images
        )

        let provider = ProviderFactory.makeProvider(profile: profile, keyResolver: secrets)
        var tagParser = ResponseTagParser()
        var sentenceChunker = SentenceChunker()
        let speaker: TextToSpeechEngine? = wantsVoice
            ? VoiceEngineFactory.makeTextToSpeech(config: config, secrets: secrets)
            : nil

        do {
            for try await event in provider.streamChat(request) {
                switch event {
                case .textDelta(let delta):
                    for chunk in tagParser.consume(delta) {
                        renderChunk(chunk, memory: memory, snapshot: snapshot, speaker: speaker, chunker: &sentenceChunker)
                    }
                case .done:
                    break
                }
            }
            for chunk in tagParser.finish() {
                renderChunk(chunk, memory: memory, snapshot: snapshot, speaker: speaker, chunker: &sentenceChunker)
            }
            print("")
            if let speaker {
                for sentence in sentenceChunker.finish() {
                    speaker.enqueue(sentence)
                }
                speaker.finishReply()
                while speaker.isSpeaking {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                }
            }
            return 0
        } catch let error as LLMProviderError {
            fputs("wisp: \(describeProviderError(error, profile: profile))\n", stderr)
            return 1
        } catch {
            fputs("wisp: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    private static func renderChunk(
        _ chunk: ResponseChunk,
        memory: MemoryStore,
        snapshot: ScreenSnapshot?,
        speaker: TextToSpeechEngine?,
        chunker: inout SentenceChunker
    ) {
        switch chunk {
        case .text(let text):
            print(text, terminator: "")
            fflush(stdout)
            if let speaker {
                for sentence in chunker.consume(text) {
                    speaker.enqueue(sentence)
                }
            }
        case .tag(.point(let elementID)):
            let label = snapshot?.elements.first { $0.id == elementID }?.title
            if let label {
                print(" [→ \(elementID) \"\(label)\"]", terminator: "")
            } else {
                print(" [→ \(elementID)]", terminator: "")
            }
            fflush(stdout)
        case .tag(.pointCoordinate(let x, let y, let displayIndex)):
            print(" [→ \(Int(x)),\(Int(y)) on display \(displayIndex + 1)]", terminator: "")
            fflush(stdout)
        case .tag(.remember(let fact)):
            try? memory.appendFact(fact, source: "model")
            print(" [remembered]", terminator: "")
            fflush(stdout)
        case .tag(.screenshotRequest):
            print(" [screenshot requested — skipped in CLI]", terminator: "")
            fflush(stdout)
        }
    }

    private static func describeProviderError(_ error: LLMProviderError, profile: LLMModelProfile) -> String {
        switch error {
        case .missingAPIKey(let ref):
            return "No API key for \(profile.displayName). Run: wisp key set \(ref)"
        case .httpError(let status, let body):
            let trimmedBody = body.prefix(200)
            return "\(profile.displayName) returned HTTP \(status)\(trimmedBody.isEmpty ? "" : ": \(trimmedBody)")"
        case .malformedResponse(let detail):
            return "unreadable response from \(profile.displayName): \(detail)"
        case .network(let detail):
            return "network error talking to \(profile.displayName): \(detail)"
        case .cancelled:
            return "cancelled"
        }
    }

    // MARK: - doctor

    private static func runDoctor() async -> Int32 {
        let checks = await DoctorChecks.runAll()
        print(DoctorChecks.renderReport(checks))
        return DoctorChecks.allCriticalChecksPass(checks) ? 0 : 1
    }

    // MARK: - key

    private static func runKey(_ arguments: [String]) -> Int32 {
        let secrets = SecretsStore()
        let config = WispConfigStore().load()

        switch arguments.first {
        case "set":
            guard arguments.count >= 2 else {
                fputs("wisp: usage: wisp key set REF   (e.g. wisp key set ANTHROPIC_API_KEY)\n", stderr)
                return 64
            }
            let ref = arguments[1]
            let key: String?
            if isatty(fileno(stdin)) != 0 {
                key = readSecret(prompt: "Paste key for \(ref): ")
            } else {
                key = readLine(strippingNewline: true)
            }
            guard let key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                fputs("wisp: no key provided\n", stderr)
                return 1
            }
            do {
                try secrets.setAPIKey(key, for: ref)
                print("Stored \(ref) in the Keychain.")
                return 0
            } catch {
                fputs("wisp: failed to store key: \(error)\n", stderr)
                return 1
            }

        case "list":
            var refs = Set(config.profiles.compactMap { $0.apiKeyRef })
            refs.insert(elevenLabsAPIKeyRef)
            if refs.isEmpty {
                print("No key refs referenced by any profile.")
                return 0
            }
            for ref in refs.sorted() {
                let resolves = secrets.apiKey(for: ref) != nil
                print("  \(resolves ? "✓" : "✗") \(ref)\(resolves ? "" : "  (not set — wisp key set \(ref))")")
            }
            return 0

        case "delete":
            guard arguments.count >= 2 else {
                fputs("wisp: usage: wisp key delete REF\n", stderr)
                return 64
            }
            do {
                try secrets.deleteAPIKey(for: arguments[1])
                print("Deleted \(arguments[1]) from the Keychain.")
                return 0
            } catch {
                fputs("wisp: failed to delete key: \(error)\n", stderr)
                return 1
            }

        default:
            fputs("wisp: usage: wisp key set|list|delete [REF]\n", stderr)
            return 64
        }
    }

    /// Reads a secret from the terminal without echoing it.
    private static func readSecret(prompt: String) -> String? {
        guard let raw = getpass(prompt) else { return nil }
        return String(cString: raw)
    }

    // MARK: - memory

    private static func runMemory(_ arguments: [String]) -> Int32 {
        let memory = MemoryStore()

        switch arguments.first {
        case "list", nil:
            let facts = memory.allFacts()
            if facts.isEmpty {
                print("Wisp hasn't remembered anything yet.")
                return 0
            }
            for fact in facts {
                print("  \(fact.id.prefix(8))  \(fact.text)  (\(fact.source))")
            }
            return 0

        case "clear":
            print("Delete all \(memory.allFacts().count) remembered facts? [y/N] ", terminator: "")
            let answer = readLine(strippingNewline: true)?.lowercased()
            guard answer == "y" || answer == "yes" else {
                print("Cancelled.")
                return 0
            }
            for fact in memory.allFacts() {
                try? memory.deleteFact(id: fact.id)
            }
            print("Cleared.")
            return 0

        default:
            fputs("wisp: usage: wisp memory list|clear\n", stderr)
            return 64
        }
    }
}
