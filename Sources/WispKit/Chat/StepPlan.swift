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
    /// value changed, keyboard focus reached it, or the window/app changed
    /// (navigation). OCR-targeted steps ("t…" IDs) only advance on
    /// navigation or when their text left the screen — OCR IDs are not
    /// stable across snapshots, so element-level matching would misfire.
    public static func looksCompleted(
        step: WalkthroughStep,
        previous: ScreenSnapshot,
        current: ScreenSnapshot
    ) -> Bool {
        // Navigation: a new window or app means the previous action landed.
        if current.windowTitle != previous.windowTitle || current.appName != previous.appName {
            return true
        }

        guard let target = previous.elements.first(where: { $0.id == step.elementID }) else {
            // The plan referenced an element the snapshot never had (stale
            // or hallucinated) — nothing further to judge.
            return false
        }

        if target.role == .ocrText {
            let targetText = Self.normalized(target.value ?? "")
            guard !targetText.isEmpty else { return false }
            let stillVisible = current.elements.contains { element in
                element.role == .ocrText && Self.normalized(element.value ?? "").contains(targetText)
            }
            return !stillVisible
        }

        let diff = SnapshotDiff.diff(previous: previous.elements, current: current.elements)

        // Disappeared: menus close, dialogs dismiss, buttons vanish.
        if diff.removed.contains(where: { $0.id == target.id }) {
            return true
        }

        if let match = diff.matches.first(where: { $0.previous.id == target.id }) {
            // Value changed: the user typed/toggled/selected.
            if match.valueChanged { return true }
            // Focus reached the target field.
            if match.current.isFocused { return true }
            if let focusedID = current.focusedElementID, focusedID == match.current.id { return true }
        }
        return false
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
