import Foundation

/// A single evaluation task: a fixture screen, a question, and what a good
/// answer looks like.
public struct EvalTask: Sendable, Identifiable {
    public var id: String
    /// The fixture snapshot the model "sees".
    public var snapshot: ScreenSnapshot
    public var question: String
    /// Element IDs that count as a correct point (any match scores).
    /// Empty when the task is comprehension-only.
    public var acceptablePointIDs: Set<String>
    /// Case-insensitive keywords; the reply must contain at least
    /// `requiredKeywordCount` of them to count as comprehending.
    public var keywords: [String]
    public var requiredKeywordCount: Int

    public init(
        id: String,
        snapshot: ScreenSnapshot,
        question: String,
        acceptablePointIDs: Set<String> = [],
        keywords: [String] = [],
        requiredKeywordCount: Int = 1
    ) {
        self.id = id
        self.snapshot = snapshot
        self.question = question
        self.acceptablePointIDs = acceptablePointIDs
        self.keywords = keywords
        self.requiredKeywordCount = requiredKeywordCount
    }
}

public struct EvalTaskResult: Sendable {
    public var taskID: String
    public var pointedCorrectly: Bool?   // nil when the task has no point target
    public var comprehended: Bool?       // nil when the task has no keywords
    public var inventedElementIDs: [String]
    public var latencyMs: Double
    public var outputTokens: Int?
    public var replyExcerpt: String

    public init(
        taskID: String,
        pointedCorrectly: Bool?,
        comprehended: Bool?,
        inventedElementIDs: [String],
        latencyMs: Double,
        outputTokens: Int?,
        replyExcerpt: String
    ) {
        self.taskID = taskID
        self.pointedCorrectly = pointedCorrectly
        self.comprehended = comprehended
        self.inventedElementIDs = inventedElementIDs
        self.latencyMs = latencyMs
        self.outputTokens = outputTokens
        self.replyExcerpt = replyExcerpt
    }
}

public struct EvalReport: Sendable {
    public var profileID: String
    public var results: [EvalTaskResult]

    public init(profileID: String, results: [EvalTaskResult]) {
        self.profileID = profileID
        self.results = results
    }

    public var pointingAccuracy: Double? {
        let scored = results.compactMap(\.pointedCorrectly)
        guard !scored.isEmpty else { return nil }
        return Double(scored.filter { $0 }.count) / Double(scored.count)
    }

    public var comprehensionAccuracy: Double? {
        let scored = results.compactMap(\.comprehended)
        guard !scored.isEmpty else { return nil }
        return Double(scored.filter { $0 }.count) / Double(scored.count)
    }

    public var meanLatencyMs: Double {
        guard !results.isEmpty else { return 0 }
        return results.map(\.latencyMs).reduce(0, +) / Double(results.count)
    }

    /// Terminal-friendly table for `wisp eval`.
    public func render() -> String {
        func mark(_ value: Bool?) -> String {
            guard let value else { return "–" }
            return value ? "✓" : "✗"
        }

        let idWidth = max(4, results.map { $0.taskID.count }.max() ?? 4) + 2
        func pad(_ text: String, _ width: Int) -> String {
            text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
        }

        var lines: [String] = []
        lines.append("Eval — profile \(profileID)")
        lines.append(pad("task", idWidth) + "point  comp  invented  latency  out-tok")
        for result in results {
            var line = pad(result.taskID, idWidth)
            line += pad(mark(result.pointedCorrectly), 7)
            line += pad(mark(result.comprehended), 6)
            line += pad("\(result.inventedElementIDs.count)", 10)
            line += pad("\(Int(result.latencyMs.rounded()))ms", 9)
            line += result.outputTokens.map(String.init) ?? "–"
            lines.append(line)
        }

        var summary: [String] = []
        let pointScored = results.compactMap(\.pointedCorrectly)
        if !pointScored.isEmpty {
            let correct = pointScored.filter { $0 }.count
            let percent = Int((Double(correct) / Double(pointScored.count) * 100).rounded())
            summary.append("pointing \(correct)/\(pointScored.count) (\(percent)%)")
        }
        let comprehensionScored = results.compactMap(\.comprehended)
        if !comprehensionScored.isEmpty {
            summary.append("comprehension \(comprehensionScored.filter { $0 }.count)/\(comprehensionScored.count)")
        }
        summary.append("invented \(results.map(\.inventedElementIDs.count).reduce(0, +))")
        summary.append("mean latency \(Int(meanLatencyMs.rounded()))ms")
        lines.append("")
        lines.append(summary.joined(separator: " · "))
        return lines.joined(separator: "\n")
    }
}

/// Runs the built-in task suite against any provider — the measuring stick
/// for "works with open models": pointing accuracy, hallucinated element
/// IDs, comprehension, latency, and output size, model vs model.
public struct EvalRunner: Sendable {
    public init() {}

    /// The built-in fixture suite: 10 tasks over synthetic storefront,
    /// mail, settings, code-editor, and OCR video-player screens.
    public static func builtInTasks() -> [EvalTask] {
        let storefront = EvalFixtures.storefront()
        let mail = EvalFixtures.mail()
        let settings = EvalFixtures.settings()
        let editor = EvalFixtures.codeEditor()
        let video = EvalFixtures.videoPlayer()
        return [
            EvalTask(
                id: "storefront-cart",
                snapshot: storefront,
                question: "Where do I click to see what's in my cart?",
                acceptablePointIDs: ["e8"]
            ),
            EvalTask(
                id: "storefront-total",
                snapshot: storefront,
                question: "What's the subtotal of my cart right now?",
                keywords: ["149"]
            ),
            EvalTask(
                id: "storefront-checkout",
                snapshot: storefront,
                question: "I'm done shopping — how do I pay?",
                acceptablePointIDs: ["e22"],
                keywords: ["check out", "checkout", "pay"]
            ),
            EvalTask(
                id: "mail-compose",
                snapshot: mail,
                question: "Where do I click to compose a new email?",
                acceptablePointIDs: ["e3"]
            ),
            EvalTask(
                id: "mail-reply-sarah",
                snapshot: mail,
                question: "I want to open Sarah's email about the invoice — where do I click?",
                acceptablePointIDs: ["e9"]
            ),
            EvalTask(
                id: "settings-bluetooth",
                snapshot: settings,
                question: "How do I turn off Bluetooth from here?",
                acceptablePointIDs: ["e12", "e4"]
            ),
            EvalTask(
                id: "settings-brightness",
                snapshot: settings,
                question: "What's the current brightness level?",
                keywords: ["75"]
            ),
            EvalTask(
                id: "editor-open-app",
                snapshot: editor,
                question: "Open the App.swift file for me.",
                acceptablePointIDs: ["e7"]
            ),
            EvalTask(
                id: "editor-error",
                snapshot: editor,
                question: "My build is failing — what's wrong and where do I rerun it?",
                acceptablePointIDs: ["e3"],
                keywords: ["delegate", "scope"]
            ),
            EvalTask(
                id: "video-subscribe",
                snapshot: video,
                question: "Point at the subscribe button on the video.",
                acceptablePointIDs: ["t2"]
            ),
        ]
    }

    public func run(
        tasks: [EvalTask],
        provider: LLMProvider,
        config: WispConfig,
        progress: (@Sendable (String) -> Void)? = nil
    ) async -> EvalReport {
        let serializer = SnapshotSerializer(tokenBudget: config.snapshotTokenBudget)
        let promptBuilder = PromptBuilder(config: config)
        var results: [EvalTaskResult] = []

        for (index, task) in tasks.enumerated() {
            progress?("[\(index + 1)/\(tasks.count)] \(task.id) …")

            let request = promptBuilder.buildRequest(
                transcript: task.question,
                snapshotBlock: serializer.serialize(task.snapshot),
                history: [],
                memoryProfile: nil,
                supportsVision: false,
                images: []
            )

            let started = Date()
            var rawReply = ""
            var outputTokens: Int?
            var providerFailure: String?
            do {
                for try await event in provider.streamChat(request) {
                    switch event {
                    case .textDelta(let delta):
                        rawReply += delta
                    case .done(let usage):
                        outputTokens = usage?.outputTokens
                    }
                }
            } catch {
                providerFailure = "\(error)"
            }
            let latencyMs = Date().timeIntervalSince(started) * 1000

            if let providerFailure {
                results.append(EvalTaskResult(
                    taskID: task.id,
                    pointedCorrectly: task.acceptablePointIDs.isEmpty ? nil : false,
                    comprehended: task.keywords.isEmpty ? nil : false,
                    inventedElementIDs: [],
                    latencyMs: latencyMs,
                    outputTokens: nil,
                    replyExcerpt: "ERROR: \(providerFailure)".prefix(120).description
                ))
                continue
            }

            results.append(Self.score(
                task: task,
                rawReply: rawReply,
                latencyMs: latencyMs,
                outputTokens: outputTokens
            ))
        }

        return EvalReport(profileID: provider.profile.id, results: results)
    }

    /// Parses the complete reply and scores it against the task. Step tags
    /// count as pointing attempts too — models legitimately answer how-to
    /// questions with a walkthrough plan.
    static func score(
        task: EvalTask,
        rawReply: String,
        latencyMs: Double,
        outputTokens: Int?
    ) -> EvalTaskResult {
        var parser = ResponseTagParser()
        var detaggedText = ""
        var referencedIDs: [String] = []
        for chunk in parser.consume(rawReply) + parser.finish() {
            switch chunk {
            case .text(let text):
                detaggedText += text
            case .tag(.point(let elementID)):
                referencedIDs.append(elementID)
            case .tag(.step(let elementID, _)):
                referencedIDs.append(elementID)
            case .tag:
                break
            }
        }

        let knownIDs = Set(task.snapshot.elements.map(\.id))
        let inventedIDs = referencedIDs.filter { !knownIDs.contains($0) }

        let pointedCorrectly: Bool? = task.acceptablePointIDs.isEmpty
            ? nil
            : referencedIDs.contains { task.acceptablePointIDs.contains($0) }

        let comprehended: Bool?
        if task.keywords.isEmpty {
            comprehended = nil
        } else {
            let haystack = detaggedText.lowercased()
            let hitCount = task.keywords.filter { haystack.contains($0.lowercased()) }.count
            comprehended = hitCount >= task.requiredKeywordCount
        }

        let excerpt = detaggedText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(120)
            .description

        return EvalTaskResult(
            taskID: task.id,
            pointedCorrectly: pointedCorrectly,
            comprehended: comprehended,
            inventedElementIDs: inventedIDs,
            latencyMs: latencyMs,
            outputTokens: outputTokens,
            replyExcerpt: excerpt
        )
    }
}
