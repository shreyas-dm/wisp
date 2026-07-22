import Foundation
import CoreGraphics

/// Pure element-matching logic between two snapshots of the same window.
/// Elements are matched by (role, title) key; when several share a key the
/// tie is broken by nearest frame distance, which keeps matching stable when
/// content merely shifts a few pixels.
struct SnapshotDiff {
    struct Match: Equatable {
        let previous: SnapshotElement
        let current: SnapshotElement

        var valueChanged: Bool { previous.value != current.value }
        var positionChanged: Bool {
            Int(previous.frame.origin.x.rounded()) != Int(current.frame.origin.x.rounded())
                || Int(previous.frame.origin.y.rounded()) != Int(current.frame.origin.y.rounded())
                || Int(previous.frame.width.rounded()) != Int(current.frame.width.rounded())
                || Int(previous.frame.height.rounded()) != Int(current.frame.height.rounded())
        }
        var isChanged: Bool { valueChanged || positionChanged }
    }

    struct Result {
        var matches: [Match] = []
        var added: [SnapshotElement] = []
        var removed: [SnapshotElement] = []

        var unchangedCount: Int { matches.filter { !$0.isChanged }.count }
        var changed: [Match] { matches.filter { $0.isChanged } }
    }

    private static func matchKey(_ element: SnapshotElement) -> String {
        element.role.rawValue + "\u{1}" + (element.title ?? "")
    }

    private static func centerDistance(_ a: SnapshotElement, _ b: SnapshotElement) -> CGFloat {
        let dx = a.frame.midX - b.frame.midX
        let dy = a.frame.midY - b.frame.midY
        return dx * dx + dy * dy
    }

    /// Matches `current` elements against `previous`. Deterministic: current
    /// elements are processed in document order, each greedily taking the
    /// nearest unused previous element sharing its key.
    static func diff(previous: [SnapshotElement], current: [SnapshotElement]) -> Result {
        var previousByKey: [String: [Int]] = [:]
        for (index, element) in previous.enumerated() {
            previousByKey[matchKey(element), default: []].append(index)
        }

        var result = Result()
        var usedPreviousIndices = Set<Int>()

        for currentElement in current {
            let key = matchKey(currentElement)
            let candidates = (previousByKey[key] ?? []).filter { !usedPreviousIndices.contains($0) }
            guard !candidates.isEmpty else {
                result.added.append(currentElement)
                continue
            }
            let best = candidates.min { lhs, rhs in
                let dl = centerDistance(previous[lhs], currentElement)
                let dr = centerDistance(previous[rhs], currentElement)
                if dl != dr { return dl < dr }
                return lhs < rhs
            }!
            usedPreviousIndices.insert(best)
            result.matches.append(Match(previous: previous[best], current: currentElement))
        }

        for (index, element) in previous.enumerated() where !usedPreviousIndices.contains(index) {
            result.removed.append(element)
        }
        return result
    }
}
