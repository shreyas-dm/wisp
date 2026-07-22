import Foundation

/// Serializes a `ScreenSnapshot` into the compact `<screen>` text block the
/// model reads, and computes token-cheap deltas between snapshots.
///
/// Full format:
/// ```
/// <screen> app=Safari window="Invoice – Stripe" display=1/2 1512x982
/// * e18 field "Amount" val="420.00" (612,388 220x28)
///   e19 btn "Send invoice" (612,440 120x32)
/// </screen>
/// ```
/// Delta format (against the previous snapshot):
/// ```
/// <screen delta> app=Safari window="Invoice – Stripe"
/// + e21 btn "Confirm" (700,500 90x30)
/// ~ e18 val="500.00"
/// - e7
/// unchanged: 38 elements
/// </screen>
/// ```
/// Budgeting: focused element first, then interactive elements, then static
/// text, dropping deepest/most-decorative lines first until the estimate
/// fits `tokenBudget`.
public struct SnapshotSerializer: Sendable {
    public var tokenBudget: Int

    public init(tokenBudget: Int = 1200) {
        self.tokenBudget = tokenBudget
    }

    public func serialize(_ snapshot: ScreenSnapshot) -> String {
        // TODO(fork-screen): implement.
        return "<screen> app=\(snapshot.appName) </screen>"
    }

    /// Serializes only what changed between `previous` and `current`. Falls
    /// back to full serialization when the app/window changed or the delta
    /// would not be meaningfully smaller.
    public func serializeDelta(from previous: ScreenSnapshot, to current: ScreenSnapshot) -> String {
        // TODO(fork-screen): implement.
        return serialize(current)
    }
}
