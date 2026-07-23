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
        // TODO(fork-eval): implement.
        "\(results.count) tasks"
    }
}

/// Runs the built-in task suite against any provider — the measuring stick
/// for "works with open models": pointing accuracy, hallucinated element
/// IDs, comprehension, latency, and output size, model vs model.
public struct EvalRunner: Sendable {
    public init() {}

    /// The built-in fixture suite (~10 tasks over synthetic browser, mail,
    /// settings, code-editor, and OCR-style screens).
    public static func builtInTasks() -> [EvalTask] {
        // TODO(fork-eval): implement fixtures.
        []
    }

    public func run(
        tasks: [EvalTask],
        provider: LLMProvider,
        config: WispConfig,
        progress: (@Sendable (String) -> Void)? = nil
    ) async -> EvalReport {
        // TODO(fork-eval): implement (serialize snapshot per task, one
        // turn each, parse tags from the reply, score, time).
        EvalReport(profileID: provider.profile.id, results: [])
    }
}
