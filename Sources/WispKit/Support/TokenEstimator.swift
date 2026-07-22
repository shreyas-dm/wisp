import Foundation

/// Cheap token estimation used for prompt budgeting. Providers report real
/// usage after the fact; this only needs to be good enough to keep prompts
/// inside their budgets before sending.
public enum TokenEstimator {
    /// ~4 characters per token is a reasonable cross-tokenizer estimate for
    /// English text and UI strings.
    public static func estimate(_ text: String) -> Int {
        max(1, text.count / 4)
    }
}
