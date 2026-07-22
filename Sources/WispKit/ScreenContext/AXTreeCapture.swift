import Foundation
import ApplicationServices
import AppKit

public enum ScreenContextError: Error, Sendable, Equatable {
    case accessibilityNotTrusted
    case noFrontmostApp
    case captureFailed(String)
}

/// Captures a `ScreenSnapshot` from the Accessibility tree of the frontmost
/// application. Must run on the main actor because it talks to AppKit for
/// display and app information.
@MainActor
public final class AXTreeCapture {
    public init() {}

    /// Whether the app has Accessibility trust (System Settings › Privacy &
    /// Security › Accessibility). Pass `promptIfNeeded` to show the system
    /// prompt on first ask.
    public static func isAccessibilityTrusted(promptIfNeeded: Bool = false) -> Bool {
        if promptIfNeeded {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
        return AXIsProcessTrusted()
    }

    /// Walks the frontmost app's AX tree and returns a flattened snapshot.
    /// Implementation notes (for the module owner):
    /// - Cap traversal (element count + depth + wall time) so pathological
    ///   trees (Electron apps) stay fast.
    /// - Skip zero-sized/offscreen elements; truncate long values; mark
    ///   focus; assign IDs in visit order ("e1", "e2", …).
    public func captureSnapshot() throws -> ScreenSnapshot {
        // TODO(fork-screen): implement AX traversal.
        throw ScreenContextError.captureFailed("not implemented")
    }
}
