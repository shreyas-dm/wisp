import Foundation
import CoreGraphics

/// Screenshot fallback for content the Accessibility tree cannot describe
/// (canvases, video, games). Only used when the model explicitly requests it
/// via `[[screenshot]]` and the active profile supports vision.
public final class ScreenshotCapture: Sendable {
    public init() {}

    public static func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    public static func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Captures the given display (0 = main), downscaled so the longest side
    /// is `maxDimension`, encoded as JPEG.
    public func captureDisplayJPEG(displayIndex: Int, maxDimension: Int = 1024) async throws -> AttachedImage {
        // TODO(fork-screen): implement with ScreenCaptureKit.
        throw ScreenContextError.captureFailed("not implemented")
    }
}
