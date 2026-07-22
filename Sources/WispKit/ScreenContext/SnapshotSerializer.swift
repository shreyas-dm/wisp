import Foundation
import CoreGraphics

/// Serializes a `ScreenSnapshot` into the compact `<screen>` text block the
/// model reads, and computes token-cheap deltas between snapshots.
///
/// Full format:
/// ```
/// <screen> app=Safari window="Invoice – Stripe" url="https://…" display=1/2 1512x982
/// also-open: "Mail — Inbox", "Xcode — wisp"
/// selected: "the text the user highlighted"
/// e1 window "Invoice – Stripe" (0,25)
/// * e18 field "Amount" val="420.00" (612,388 220x28)
///   e19 btn "Send invoice" (612,440 120x32)
/// </screen>
/// ```
/// `url=` appears only for browsers; `also-open:`/`selected:` only when
/// present. Under budget pressure those two lines are dropped before any
/// element line — also-open first, selection second.
/// The focused element's line starts with `* ` (no indentation) so it is
/// always easy to spot. All other lines are indented two spaces per tree
/// level (capped at six levels). Sizes are only included for interactive
/// elements — position alone is enough for text.
///
/// Delta format (against the previous snapshot):
/// ```
/// <screen delta> app=Safari window="Invoice – Stripe"
/// ~ selected: "new selection"
/// + e21 btn "Confirm" (700,500 90x30)
/// ~ e18 val="500.00"
/// - e7
/// unchanged: 38 elements
/// </screen>
/// ```
/// A selection change emits `~ selected: "…"` (or `- selected` when it
/// vanished); the also-open list never appears in deltas.
/// Budgeting: if the block exceeds `tokenBudget`, lines are dropped in
/// priority order — deepest static text first, then decorative
/// images/groups, then other non-interactive elements, and interactive
/// elements only as a last resort. The focused element and its ancestor
/// chain are never dropped. A trailing `… N more elements omitted` line
/// reports what was cut.
public struct SnapshotSerializer: Sendable {
    public var tokenBudget: Int

    public init(tokenBudget: Int = 1200) {
        self.tokenBudget = tokenBudget
    }

    // MARK: - Full serialization

    public func serialize(_ snapshot: ScreenSnapshot) -> String {
        let header = Self.header(for: snapshot)
        let protectedIndices = Self.protectedIndices(in: snapshot)

        // Order in which elements may be dropped when over budget.
        let dropQueue: [Int] = snapshot.elements.indices
            .filter { !protectedIndices.contains($0) }
            .sorted { lhs, rhs in
                let l = Self.dropRank(snapshot.elements[lhs])
                let r = Self.dropRank(snapshot.elements[rhs])
                if l != r { return l < r }
                let ld = snapshot.elements[lhs].depth
                let rd = snapshot.elements[rhs].depth
                if ld != rd { return ld > rd }
                return lhs > rhs
            }

        var droppedIndices = Set<Int>()
        var includeAlsoOpen = !snapshot.openWindows.isEmpty
        var includeSelected = snapshot.selectedText != nil

        func assemble() -> String {
            var lines: [String] = [header]
            if includeAlsoOpen {
                lines.append(Self.alsoOpenLine(snapshot.openWindows))
            }
            if includeSelected, let selectedText = snapshot.selectedText {
                lines.append(Self.selectedLine(selectedText))
            }
            for (index, element) in snapshot.elements.enumerated() where !droppedIndices.contains(index) {
                lines.append(Self.elementLine(element, isFocused: element.id == snapshot.focusedElementID))
            }
            if !droppedIndices.isEmpty {
                lines.append("… \(droppedIndices.count) more elements omitted")
            }
            lines.append("</screen>")
            return lines.joined(separator: "\n")
        }

        var block = assemble()
        // Context lines go before any element is sacrificed: also-open is
        // the most expendable, the user's selection the next.
        if TokenEstimator.estimate(block) > tokenBudget, includeAlsoOpen {
            includeAlsoOpen = false
            block = assemble()
        }
        if TokenEstimator.estimate(block) > tokenBudget, includeSelected {
            includeSelected = false
            block = assemble()
        }
        var queuePosition = 0
        while TokenEstimator.estimate(block) > tokenBudget && queuePosition < dropQueue.count {
            droppedIndices.insert(dropQueue[queuePosition])
            queuePosition += 1
            block = assemble()
        }
        return block
    }

    // MARK: - Delta serialization

    /// Serializes only what changed between `previous` and `current`. Falls
    /// back to full serialization when the app/window changed or the delta
    /// would not be meaningfully smaller (≥70% of the full block's lines).
    public func serializeDelta(from previous: ScreenSnapshot, to current: ScreenSnapshot) -> String {
        guard previous.appName == current.appName, previous.windowTitle == current.windowTitle else {
            return serialize(current)
        }

        let diff = SnapshotDiff.diff(previous: previous.elements, current: current.elements)

        var deltaLines: [String] = []
        // Selection changes ride along with element deltas; the also-open
        // list is ambient context and never repeated in deltas.
        if previous.selectedText != current.selectedText {
            if let selectedText = current.selectedText {
                deltaLines.append("~ " + Self.selectedLine(selectedText))
            } else {
                deltaLines.append("- selected")
            }
        }
        for element in diff.added {
            deltaLines.append("+ " + Self.elementBody(element))
        }
        for match in diff.changed {
            var line = "~ \(match.current.id)"
            if match.valueChanged, let value = match.current.value {
                line += " val=\"\(Self.escape(value))\""
            }
            if match.positionChanged {
                line += " " + Self.position(of: match.current)
            }
            deltaLines.append(line)
        }
        for element in diff.removed {
            deltaLines.append("- \(element.id)")
        }

        let fullBlock = serialize(current)
        // Element lines of the full block (total lines minus header/footer).
        let fullElementLineCount = max(1, fullBlock.split(separator: "\n").count - 2)
        let threshold = Int(ceil(0.7 * Double(fullElementLineCount)))
        if deltaLines.count >= threshold {
            return fullBlock
        }

        var header = "<screen delta> app=\(current.appName)"
        if let windowTitle = current.windowTitle {
            header += " window=\"\(Self.escape(windowTitle))\""
        }
        if let browserURL = current.browserURL {
            header += " url=\"\(Self.escape(browserURL))\""
        }

        var lines = [header]
        lines.append(contentsOf: deltaLines)
        lines.append("unchanged: \(diff.unchangedCount) elements")
        lines.append("</screen>")
        return lines.joined(separator: "\n")
    }

    // MARK: - Line building

    static func header(for snapshot: ScreenSnapshot) -> String {
        var header = "<screen> app=\(snapshot.appName)"
        if let windowTitle = snapshot.windowTitle {
            header += " window=\"\(escape(windowTitle))\""
        }
        if let browserURL = snapshot.browserURL {
            header += " url=\"\(escape(browserURL))\""
        }
        if !snapshot.displays.isEmpty {
            let anchor = snapshot.elements.first { $0.role == .window } ?? snapshot.elements.first
            let displayIndex = anchor?.displayIndex ?? 0
            if displayIndex < snapshot.displays.count {
                let frame = snapshot.displays[displayIndex].frame
                header += " display=\(displayIndex + 1)/\(snapshot.displays.count)"
                header += " \(Int(frame.width.rounded()))x\(Int(frame.height.rounded()))"
            }
        }
        return header
    }

    /// `also-open: "Mail — Inbox", "Xcode — wisp"` — ambient context.
    static func alsoOpenLine(_ openWindows: [String]) -> String {
        "also-open: " + openWindows.map { "\"\(escape($0))\"" }.joined(separator: ", ")
    }

    /// `selected: "…"` — what the user has highlighted. The raw text is
    /// capped again here so this stays a single reasonable line even if a
    /// capturer ever passes something longer.
    static func selectedLine(_ selectedText: String) -> String {
        var capped = selectedText
        if capped.count > 380 {
            capped = String(capped.prefix(379)) + "…"
        }
        return "selected: \"\(escape(capped))\""
    }

    /// One serialized element line including focus marker / indentation.
    static func elementLine(_ element: SnapshotElement, isFocused: Bool) -> String {
        if isFocused {
            return "* " + elementBody(element)
        }
        return String(repeating: "  ", count: min(element.depth, 6)) + elementBody(element)
    }

    /// `eID role "title" val="value" (x,y WxH)` without indentation.
    static func elementBody(_ element: SnapshotElement) -> String {
        var parts: [String] = [element.id, element.role.rawValue]
        if let title = element.title, !title.isEmpty {
            parts.append("\"\(escape(title))\"")
        }
        if let value = element.value {
            parts.append("val=\"\(escape(value))\"")
        }
        parts.append(position(of: element))
        return parts.joined(separator: " ")
    }

    /// `(x,y)` for passive elements, `(x,y WxH)` for interactive ones.
    static func position(of element: SnapshotElement) -> String {
        let x = Int(element.frame.origin.x.rounded())
        let y = Int(element.frame.origin.y.rounded())
        guard element.isInteractive else { return "(\(x),\(y))" }
        let width = Int(element.frame.width.rounded())
        let height = Int(element.frame.height.rounded())
        return "(\(x),\(y) \(width)x\(height))"
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
            .replacingOccurrences(of: "\t", with: " ")
    }

    // MARK: - Budget support

    /// Lower rank ⇒ dropped earlier.
    private static func dropRank(_ element: SnapshotElement) -> Int {
        if element.isInteractive { return 3 }
        switch element.role {
        case .staticText: return 0
        case .image, .group: return 1
        default: return 2
        }
    }

    /// Indices of the focused element and its ancestor chain, derived from
    /// the flattened depth-first order: walking backwards from the focused
    /// element, an ancestor is each element with a strictly smaller depth
    /// than any seen so far.
    private static func protectedIndices(in snapshot: ScreenSnapshot) -> Set<Int> {
        guard let focusedID = snapshot.focusedElementID,
              let focusedIndex = snapshot.elements.firstIndex(where: { $0.id == focusedID })
        else { return [] }

        var protected: Set<Int> = [focusedIndex]
        var currentDepth = snapshot.elements[focusedIndex].depth
        var index = focusedIndex - 1
        while index >= 0 && currentDepth > 0 {
            if snapshot.elements[index].depth < currentDepth {
                protected.insert(index)
                currentDepth = snapshot.elements[index].depth
            }
            index -= 1
        }
        return protected
    }
}
