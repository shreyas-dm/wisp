import Foundation
import CoreGraphics
import AppKit
import ScreenCaptureKit

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
    /// is `maxDimension`, encoded as JPEG. Never triggers the permission
    /// prompt — callers check/request permission during onboarding.
    public func captureDisplayJPEG(displayIndex: Int, maxDimension: Int = 1024) async throws -> AttachedImage {
        guard Self.hasScreenRecordingPermission() else {
            throw ScreenContextError.captureFailed("screen recording permission not granted")
        }

        // Map our display index (NSScreen order, 0 = main) to a Core
        // Graphics display ID so we pick the same physical display the
        // snapshot's DisplayInfo refers to.
        let screenDisplayIDs: [CGDirectDisplayID] = await MainActor.run {
            NSScreen.screens.compactMap { screen in
                (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                    .map { CGDirectDisplayID($0.uint32Value) }
            }
        }
        let targetDisplayID: CGDirectDisplayID =
            displayIndex >= 0 && displayIndex < screenDisplayIDs.count
                ? screenDisplayIDs[displayIndex]
                : CGMainDisplayID()

        let shareableContent = try await SCShareableContent.current
        guard let display = shareableContent.displays.first(where: { $0.displayID == targetDisplayID })
            ?? shareableContent.displays.first
        else {
            throw ScreenContextError.captureFailed("no capturable display found")
        }

        let configuration = SCStreamConfiguration()
        let longestSide = max(display.width, display.height)
        let scale = min(1.0, Double(maxDimension) / Double(max(1, longestSide)))
        configuration.width = max(1, Int(Double(display.width) * scale))
        configuration.height = max(1, Int(Double(display.height) * scale))
        configuration.showsCursor = false

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cgImage: CGImage
        do {
            cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        } catch {
            throw ScreenContextError.captureFailed("screenshot failed: \(error.localizedDescription)")
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let jpegData = bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.7]
        ) else {
            throw ScreenContextError.captureFailed("JPEG encoding failed")
        }
        return AttachedImage(jpegData: jpegData)
    }
}
