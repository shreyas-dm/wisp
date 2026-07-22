import Foundation
import CoreGraphics
import CoreText
import ImageIO
@testable import WispKit

/// Renders crisp black text on white at known top-left-origin rects and
/// returns JPEG data, so recognition runs against ground truth.
private func makeTestJPEG(texts: [(String, CGRect)], size: CGSize) -> Data {
    let context = CGContext(
        data: nil,
        width: Int(size.width),
        height: Int(size.height),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(origin: .zero, size: size))

    for (text, rect) in texts {
        let font = CTFontCreateWithName("Helvetica" as CFString, rect.height * 0.8, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(gray: 0, alpha: 1),
        ]
        let attributed = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attributed)
        // Convert the top-left-origin rect to the context's bottom-left
        // origin; baseline sits slightly above the rect's bottom edge.
        context.textPosition = CGPoint(x: rect.minX, y: size.height - rect.maxY + rect.height * 0.2)
        CTLineDraw(line, context)
    }

    let image = context.makeImage()!
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    CGImageDestinationFinalize(destination)
    return output as Data
}

private func fragment(_ text: String, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, confidence: Float = 1.0) -> OCRCapture.Fragment {
    OCRCapture.Fragment(text: text, frame: CGRect(x: x, y: y, width: w, height: h), confidence: confidence)
}

func ocrTests(_ t: TestRunner) -> [TestCase] {
    // The screenshot is half the display's size, proving normalized-box
    // mapping is independent of the JPEG downscale factor.
    let displayFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let imageSize = CGSize(width: 720, height: 450)

    return [
        TestCase("recognizes drawn text and maps frames to display coords") {
            let jpeg = makeTestJPEG(
                texts: [("Hello Wisp", CGRect(x: 80, y: 100, width: 240, height: 30))],
                size: imageSize
            )
            let elements = try await OCRCapture().recognizeText(inJPEG: jpeg, displayFrame: displayFrame)
            t.expect(!elements.isEmpty, "recognized at least one element")
            guard let hello = elements.first(where: { ($0.value ?? "").lowercased().contains("hello") }) else {
                t.expect(false, "found the drawn text, got: \(elements.map { $0.value ?? "" })")
                return
            }
            t.expect(hello.role == .ocrText, "role is ocr")
            t.expect(hello.id.hasPrefix("t"), "IDs are t-prefixed")
            // Drawn at image (80,100,~240x30) → display ≈ centered near (400,230).
            let center = CGPoint(x: hello.frame.midX, y: hello.frame.midY)
            t.expect(abs(center.x - 400) < 0.15 * displayFrame.width, "x center within 15% (got \(center.x))")
            t.expect(abs(center.y - 230) < 0.15 * displayFrame.height, "y center within 15% (got \(center.y))")
        },
        TestCase("reading order assigns t1 above t2") {
            let jpeg = makeTestJPEG(
                texts: [
                    ("Hello Wisp", CGRect(x: 80, y: 100, width: 240, height: 30)),
                    ("Settings", CGRect(x: 80, y: 300, width: 160, height: 30)),
                ],
                size: imageSize
            )
            let elements = try await OCRCapture().recognizeText(inJPEG: jpeg, displayFrame: displayFrame)
            t.expect(elements.count >= 2, "recognized both texts (got \(elements.count))")
            guard elements.count >= 2 else { return }
            t.expectEqual(elements[0].id, "t1")
            t.expectEqual(elements[1].id, "t2")
            t.expect(elements[0].frame.midY < elements[1].frame.midY, "t1 is above t2")
            t.expect((elements[0].value ?? "").lowercased().contains("hello"), "t1 is the upper text")
        },
        TestCase("maxElements caps output but keeps reading order and t1") {
            let jpeg = makeTestJPEG(
                texts: [
                    ("Hello Wisp", CGRect(x: 80, y: 100, width: 240, height: 30)),
                    ("Settings", CGRect(x: 80, y: 300, width: 160, height: 30)),
                ],
                size: imageSize
            )
            let elements = try await OCRCapture().recognizeText(inJPEG: jpeg, displayFrame: displayFrame, maxElements: 1)
            t.expectEqual(elements.count, 1, "capped to one element")
            t.expectEqual(elements.first?.id, "t1", "IDs reassigned after the cut")
        },
        TestCase("invalid image data throws invalidImage") {
            do {
                _ = try await OCRCapture().recognizeText(inJPEG: Data("not a jpeg".utf8), displayFrame: displayFrame)
                t.expect(false, "should have thrown")
            } catch let error as OCRError {
                if case .invalidImage = error {} else { t.expect(false, "wrong error: \(error)") }
            }
        },
        TestCase("assembleLines joins adjacent fragments on one line") {
            let joined = OCRCapture.assembleLines([
                fragment("Hello", 100, 200, 80, 20, confidence: 0.9),
                fragment("Wisp", 190, 201, 60, 20, confidence: 0.7),
            ])
            t.expectEqual(joined.count, 1, "one merged line")
            t.expectEqual(joined.first?.text, "Hello Wisp")
            t.expectEqual(joined.first?.frame, CGRect(x: 100, y: 200, width: 150, height: 21))
            if let confidence = joined.first?.confidence {
                t.expect(abs(confidence - (0.9 * 5 + 0.7 * 4) / 9) < 0.001, "length-weighted confidence")
            }
        },
        TestCase("assembleLines keeps two columns separate") {
            let lines = OCRCapture.assembleLines([
                fragment("Left column", 100, 200, 120, 20),
                fragment("Right column", 700, 200, 130, 20),
            ])
            t.expectEqual(lines.count, 2, "columns not merged across the gap")
        },
        TestCase("assembleLines keeps separate bands separate, top first") {
            let lines = OCRCapture.assembleLines([
                fragment("Lower", 100, 300, 80, 20),
                fragment("Upper", 100, 100, 80, 20),
            ])
            t.expectEqual(lines.count, 2)
            t.expectEqual(lines.first?.text, "Upper", "reading order is top-to-bottom")
        },
        TestCase("merge drops OCR duplicates of AX elements") {
            let snapshot = ScreenSnapshot(
                appName: "Test",
                elements: [
                    SnapshotElement(id: "e1", role: .button, title: "Send invoice now", frame: CGRect(x: 100, y: 100, width: 120, height: 30), isInteractive: true),
                ]
            )
            let merged = OCRCapture.merge(
                ocrElements: [
                    // High overlap + contained text → duplicate, dropped.
                    SnapshotElement(id: "t1", role: .ocrText, value: "Send Invoice", frame: CGRect(x: 102, y: 101, width: 116, height: 28)),
                    // High overlap but different text → kept.
                    SnapshotElement(id: "t2", role: .ocrText, value: "Total due", frame: CGRect(x: 100, y: 100, width: 120, height: 30)),
                    // Same text but elsewhere on screen → kept.
                    SnapshotElement(id: "t3", role: .ocrText, value: "Send invoice now", frame: CGRect(x: 600, y: 500, width: 120, height: 30)),
                ],
                into: snapshot
            )
            let ids = merged.elements.map(\.id)
            t.expectEqual(ids, ["e1", "t2", "t3"], "duplicate dropped, survivors appended in order")
            t.expectEqual(snapshot.elements.count, 1, "input snapshot not mutated")
        },
        TestCase("merge drops empty OCR values and exact value matches") {
            let snapshot = ScreenSnapshot(
                appName: "Test",
                elements: [
                    SnapshotElement(id: "e1", role: .textField, value: "hello   world", frame: CGRect(x: 0, y: 0, width: 200, height: 30)),
                ]
            )
            let merged = OCRCapture.merge(
                ocrElements: [
                    SnapshotElement(id: "t1", role: .ocrText, value: "Hello World", frame: CGRect(x: 2, y: 2, width: 196, height: 28)),
                    SnapshotElement(id: "t2", role: .ocrText, value: "   ", frame: CGRect(x: 300, y: 300, width: 50, height: 20)),
                ],
                into: snapshot
            )
            t.expectEqual(merged.elements.map(\.id), ["e1"], "whitespace-normalized duplicate and empty value both dropped")
        },
        TestCase("intersectionOverUnion sanity") {
            let a = CGRect(x: 0, y: 0, width: 100, height: 100)
            t.expectEqual(OCRCapture.intersectionOverUnion(a, a), 1.0)
            t.expectEqual(OCRCapture.intersectionOverUnion(a, CGRect(x: 200, y: 200, width: 10, height: 10)), 0)
            let half = OCRCapture.intersectionOverUnion(a, CGRect(x: 0, y: 0, width: 100, height: 50))
            t.expect(abs(half - 0.5) < 0.001, "half-overlap IoU is 0.5")
        },
    ]
}
