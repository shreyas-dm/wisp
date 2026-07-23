import Foundation

/// One step of a guided walkthrough.
public struct WalkthroughStep: Equatable, Sendable, Identifiable {
    /// 1-based position in the plan.
    public var index: Int
    /// Snapshot element the step targets ("e12" or OCR "t3").
    public var elementID: String
    /// Short imperative instruction shown in the step chip and spoken.
    public var instruction: String

    public var id: Int { index }

    public init(index: Int, elementID: String, instruction: String) {
        self.index = index
        self.elementID = elementID
        self.instruction = instruction
    }
}

/// Collects `[[step:…]]` tags streamed during a reply into an ordered plan
/// and decides, from snapshot diffs, when a step looks completed so the
/// walkthrough can auto-advance.
public struct StepPlanBuilder: Sendable {
    public private(set) var steps: [WalkthroughStep] = []

    public init() {}

    /// Append a streamed step tag. Steps keep arrival order; duplicate
    /// element IDs are allowed (e.g. "click it again").
    public mutating func addStep(elementID: String, instruction: String) {
        steps.append(WalkthroughStep(index: steps.count + 1, elementID: elementID, instruction: instruction))
    }

    public var isEmpty: Bool { steps.isEmpty }

    /// Heuristic: does the change from `previous` to `current` suggest the
    /// user performed `step`? True when the target element disappeared, its
    /// value changed, the focused element moved to/past it, or the window
    /// title changed (navigation).
    public static func looksCompleted(
        step: WalkthroughStep,
        previous: ScreenSnapshot,
        current: ScreenSnapshot
    ) -> Bool {
        // TODO(fork-core): implement the diff heuristic.
        false
    }
}
