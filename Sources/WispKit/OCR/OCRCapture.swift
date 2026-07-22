import Foundation
import CoreGraphics
import ImageIO
import Vision

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
    /// Candidates below this confidence are noise, not UI text.
    static let minimumConfidence: Float = 0.35
    /// Values longer than this are truncated (matches AX capture behavior).
    static let maximumValueLength = 120

    public init() {}

    /// One recognized piece of text, in global Quartz coordinates.
    /// Internal so the line-assembly logic is testable in isolation.
    struct Fragment {
        var text: String
        var frame: CGRect
        var confidence: Float
    }

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
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw OCRError.invalidImage
        }

        let observations = try await Self.performRecognition(on: cgImage)

        var fragments: [Fragment] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, candidate.confidence >= Self.minimumConfidence else { continue }
            // Vision boxes are normalized with a bottom-left origin; map to
            // the display's global Quartz (top-left origin) frame. Because
            // the screenshot covers exactly the display, normalized mapping
            // is independent of the JPEG's downscale factor.
            let box = observation.boundingBox
            let mappedFrame = CGRect(
                x: displayFrame.minX + box.minX * displayFrame.width,
                y: displayFrame.minY + (1 - box.maxY) * displayFrame.height,
                width: box.width * displayFrame.width,
                height: box.height * displayFrame.height
            )
            fragments.append(Fragment(text: text, frame: mappedFrame, confidence: candidate.confidence))
        }

        var lines = Self.assembleLines(fragments)

        // Cap by confidence, then restore reading order for what survives.
        if lines.count > maxElements {
            let keptIndices = Set(
                lines.indices
                    .sorted { lines[$0].confidence > lines[$1].confidence }
                    .prefix(maxElements)
            )
            lines = lines.indices.filter(keptIndices.contains).map { lines[$0] }
        }

        return lines.enumerated().map { index, line in
            var value = line.text
            if value.count > Self.maximumValueLength {
                value = String(value.prefix(Self.maximumValueLength - 1)) + "…"
            }
            return SnapshotElement(
                id: "t\(index + 1)",
                role: .ocrText,
                title: nil,
                value: value,
                frame: line.frame,
                depth: 0,
                isInteractive: false,
                displayIndex: 0,
                isFocused: false
            )
        }
    }

    /// Runs the blocking Vision request off the caller's executor.
    private static func performRecognition(on cgImage: CGImage) async throws -> [VNRecognizedTextObservation] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.revision = VNRecognizeTextRequest.currentRevision
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do {
                    try handler.perform([request])
                    continuation.resume(returning: request.results ?? [])
                } catch {
                    continuation.resume(throwing: OCRError.recognitionFailed(error.localizedDescription))
                }
            }
        }
    }

    /// Groups fragments into visual lines (vertical bands), then joins
    /// horizontally adjacent fragments within a band. Two columns of text
    /// share a band but are NOT joined — only near-adjacent runs merge.
    /// Returns lines in reading order (top-to-bottom, left-to-right).
    static func assembleLines(_ fragments: [Fragment]) -> [Fragment] {
        guard !fragments.isEmpty else { return [] }

        // Band grouping by vertical center proximity.
        var bands: [[Fragment]] = []
        for fragment in fragments.sorted(by: { $0.frame.midY < $1.frame.midY }) {
            if let last = bands.last?.last,
               abs(fragment.frame.midY - last.frame.midY) < 0.4 * max(fragment.frame.height, last.frame.height) {
                bands[bands.count - 1].append(fragment)
            } else {
                bands.append([fragment])
            }
        }

        var lines: [Fragment] = []
        for band in bands {
            let ordered = band.sorted { $0.frame.minX < $1.frame.minX }
            var current: Fragment?
            for fragment in ordered {
                guard var accumulated = current else {
                    current = fragment
                    continue
                }
                let gap = fragment.frame.minX - accumulated.frame.maxX
                let joinThreshold = 2 * (Self.averageCharWidth(of: accumulated) + Self.averageCharWidth(of: fragment)) / 2
                if gap < joinThreshold {
                    let accumulatedLength = Float(accumulated.text.count)
                    let fragmentLength = Float(fragment.text.count)
                    accumulated.confidence = (accumulated.confidence * accumulatedLength + fragment.confidence * fragmentLength)
                        / max(1, accumulatedLength + fragmentLength)
                    accumulated.text += " " + fragment.text
                    accumulated.frame = accumulated.frame.union(fragment.frame)
                    current = accumulated
                } else {
                    lines.append(accumulated)
                    current = fragment
                }
            }
            if let current { lines.append(current) }
        }
        return lines
    }

    private static func averageCharWidth(of fragment: Fragment) -> CGFloat {
        fragment.frame.width / CGFloat(max(1, fragment.text.count))
    }

    // MARK: - Merging into an AX snapshot

    /// Merges OCR elements into an AX snapshot, dropping OCR lines whose
    /// frames substantially overlap an existing AX element that already
    /// carries the same text (avoids duplicates), and returns the combined
    /// snapshot.
    public static func merge(ocrElements: [SnapshotElement], into snapshot: ScreenSnapshot) -> ScreenSnapshot {
        let survivors = ocrElements.filter { ocrElement in
            let ocrText = normalize(ocrElement.value ?? "")
            guard !ocrText.isEmpty else { return false }
            let isDuplicate = snapshot.elements.contains { axElement in
                guard intersectionOverUnion(ocrElement.frame, axElement.frame) > 0.5 else { return false }
                let axTitle = normalize(axElement.title ?? "")
                let axValue = normalize(axElement.value ?? "")
                return axTitle == ocrText || axValue == ocrText
                    || (!axTitle.isEmpty && axTitle.contains(ocrText))
                    || (!axValue.isEmpty && axValue.contains(ocrText))
            }
            return !isDuplicate
        }
        var merged = snapshot
        merged.elements.append(contentsOf: survivors)
        return merged
    }

    static func intersectionOverUnion(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = a.width * a.height + b.width * b.height - intersectionArea
        guard unionArea > 0 else { return 0 }
        return intersectionArea / unionArea
    }

    /// Lowercased, whitespace-collapsed comparison form.
    static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
