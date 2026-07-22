import Foundation
import CoreGraphics

public enum OCRError: Error, Sendable {
    case invalidImage
    case recognitionFailed(String)
}

/// Local, key-free text recognition (Apple Vision framework) used when the
/// accessibility tree is sparse — canvases, video, games, remote desktops.
/// Recognized lines become pointable `SnapshotElement`s with role `.ocrText`
/// and IDs "t1", "t2", … so even text-only models can read and point at
/// content accessibility cannot describe. Runs entirely on device.
public struct OCRCapture: Sendable {
    public init() {}

    /// Recognizes text in a screenshot.
    /// - Parameters:
    ///   - jpeg: the downscaled screenshot as produced by `ScreenshotCapture`.
    ///   - displayFrame: global Quartz frame of the display the screenshot
    ///     covers — recognized normalized boxes are mapped into this frame so
    ///     OCR elements share the coordinate space of AX elements.
    ///   - maxElements: cap on returned elements (highest-confidence first).
    public func recognizeText(
        inJPEG jpeg: Data,
        displayFrame: CGRect,
        maxElements: Int = 120
    ) async throws -> [SnapshotElement] {
        // TODO(fork-ocr): implement with VNRecognizeTextRequest.
        throw OCRError.recognitionFailed("not implemented")
    }

    /// Merges OCR elements into an AX snapshot, dropping OCR lines whose
    /// frames substantially overlap an existing AX element that already
    /// carries the same text (avoids duplicates), and returns the combined
    /// snapshot.
    public static func merge(ocrElements: [SnapshotElement], into snapshot: ScreenSnapshot) -> ScreenSnapshot {
        // TODO(fork-ocr): implement overlap/text dedupe.
        var merged = snapshot
        merged.elements.append(contentsOf: ocrElements)
        return merged
    }
}
