import Foundation
import CoreGraphics
@testable import WispKit

private func el(
    _ id: String,
    _ role: ElementRole,
    _ title: String? = nil,
    val: String? = nil,
    x: CGFloat, y: CGFloat, w: CGFloat = 0, h: CGFloat = 0,
    depth: Int = 0,
    interactive: Bool = false,
    focused: Bool = false
) -> SnapshotElement {
    SnapshotElement(
        id: id,
        role: role,
        title: title,
        value: val,
        frame: CGRect(x: x, y: y, width: w, height: h),
        depth: depth,
        isInteractive: interactive,
        displayIndex: 0,
        isFocused: focused
    )
}

private let mainDisplay = DisplayInfo(
    index: 0,
    frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
    isMain: true
)

private func invoiceSnapshot() -> ScreenSnapshot {
    ScreenSnapshot(
        appName: "Safari",
        windowTitle: "Invoice – Stripe",
        focusedElementID: "e2",
        displays: [mainDisplay],
        elements: [
            el("e1", .window, "Invoice – Stripe", x: 0, y: 25, w: 1512, h: 957, depth: 0),
            el("e2", .textField, "Amount", val: "420.00", x: 612, y: 388, w: 220, h: 28, depth: 1, interactive: true, focused: true),
            el("e3", .button, "Send invoice", x: 612, y: 440, w: 120, h: 32, depth: 1, interactive: true),
            el("e4", .staticText, val: "Total due", x: 20, y: 100, w: 200, h: 20, depth: 2),
        ]
    )
}

/// A snapshot whose window/app stay fixed so deltas apply; `values` controls
/// the field's value, `saveOrigin` the button's position.
private func formSnapshot(
    ids: [String],
    fieldValue: String,
    saveX: CGFloat = 10
) -> ScreenSnapshot {
    ScreenSnapshot(
        appName: "App",
        windowTitle: "W",
        displays: [mainDisplay],
        elements: [
            el(ids[0], .button, "Save", x: saveX, y: 10, w: 100, h: 30, interactive: true),
            el(ids[1], .textField, "Name", val: fieldValue, x: 10, y: 50, w: 200, h: 28, interactive: true),
            el(ids[2], .button, "A", x: 10, y: 130, w: 50, h: 20, interactive: true),
            el(ids[3], .button, "B", x: 10, y: 160, w: 50, h: 20, interactive: true),
            el(ids[4], .button, "C", x: 10, y: 190, w: 50, h: 20, interactive: true),
            el(ids[5], .button, "D", x: 10, y: 220, w: 50, h: 20, interactive: true),
        ]
    )
}

func screenContextTests(_ t: TestRunner) -> [TestCase] {
    [
        TestCase("full serialization golden") {
            let output = SnapshotSerializer().serialize(invoiceSnapshot())
            let expected = """
            <screen> app=Safari window="Invoice – Stripe" display=1/1 1512x982
            e1 window "Invoice – Stripe" (0,25)
            * e2 field "Amount" val="420.00" (612,388 220x28)
              e3 btn "Send invoice" (612,440 120x32)
                e4 text val="Total due" (20,100)
            </screen>
            """
            t.expectEqual(output, expected)
        },

        TestCase("focused line starts with star and no indent") {
            var snapshot = invoiceSnapshot()
            snapshot.elements[1].depth = 4
            let output = SnapshotSerializer().serialize(snapshot)
            t.expect(output.contains("\n* e2 field"), "focused line unindented with star prefix")
        },

        TestCase("header omits window and display when unknown") {
            let snapshot = ScreenSnapshot(
                appName: "X",
                elements: [el("e1", .staticText, val: "hi", x: 1, y: 2, w: 50, h: 10)]
            )
            let expected = """
            <screen> app=X
            e1 text val="hi" (1,2)
            </screen>
            """
            t.expectEqual(SnapshotSerializer().serialize(snapshot), expected)
        },

        TestCase("titles and values are escaped") {
            let snapshot = ScreenSnapshot(
                appName: "X",
                elements: [el("e1", .button, "Say \"hi\"", val: "a\nb", x: 0, y: 0, w: 10, h: 10, interactive: true)]
            )
            let output = SnapshotSerializer().serialize(snapshot)
            t.expect(output.contains("\"Say \\\"hi\\\"\""), "quotes escaped in title: \(output)")
            t.expect(output.contains("val=\"a\\nb\""), "newline escaped in value: \(output)")
        },

        TestCase("budget drops deepest static text first") {
            let filler = String(repeating: "x", count: 40)
            let snapshot = ScreenSnapshot(
                appName: "TestApp",
                focusedElementID: "e1",
                elements: [
                    el("e1", .textField, "Query", x: 0, y: 0, w: 300, h: 30, depth: 1, interactive: true, focused: true),
                    el("e2", .button, "Go", x: 310, y: 0, w: 60, h: 30, depth: 1, interactive: true),
                    el("e3", .staticText, val: filler, x: 0, y: 50, w: 300, h: 20, depth: 2),
                    el("e4", .staticText, val: filler, x: 0, y: 80, w: 300, h: 20, depth: 3),
                    el("e5", .staticText, val: filler, x: 0, y: 110, w: 300, h: 20, depth: 4),
                ]
            )
            let unbudgeted = SnapshotSerializer(tokenBudget: 100_000).serialize(snapshot)
            let budget = TokenEstimator.estimate(unbudgeted) - 1
            let output = SnapshotSerializer(tokenBudget: budget).serialize(snapshot)
            t.expect(!output.contains("e5"), "deepest text dropped first: \(output)")
            t.expect(output.contains("e4"), "shallower text kept")
            t.expect(output.contains("e3"), "shallowest text kept")
            t.expect(output.contains("… 1 more elements omitted"), "omitted count line present")
        },

        TestCase("budget never drops the focused element") {
            let snapshot = ScreenSnapshot(
                appName: "TestApp",
                focusedElementID: "e1",
                elements: [
                    el("e1", .textField, "Query", x: 0, y: 0, w: 300, h: 30, depth: 1, interactive: true, focused: true),
                    el("e2", .button, "Go", x: 310, y: 0, w: 60, h: 30, depth: 1, interactive: true),
                    el("e3", .staticText, val: "hello world text", x: 0, y: 50, w: 300, h: 20, depth: 2),
                ]
            )
            let output = SnapshotSerializer(tokenBudget: 1).serialize(snapshot)
            t.expect(output.contains("* e1 field \"Query\""), "focused survives budget 1: \(output)")
            t.expect(!output.contains("e3"), "droppable text dropped")
            t.expect(output.contains("2 more elements omitted"), "everything else omitted: \(output)")
        },

        TestCase("delta golden: add, change value, remove") {
            let previous = ScreenSnapshot(
                appName: "App",
                windowTitle: "W",
                displays: [mainDisplay],
                elements: formSnapshot(ids: ["p1", "p2", "p5", "p6", "p7", "p8"], fieldValue: "a").elements
                    + [el("p3", .staticText, val: "Hello", x: 10, y: 90, w: 100, h: 20)]
            )
            var current = formSnapshot(ids: ["c1", "c2", "c5", "c6", "c7", "c8"], fieldValue: "ab")
            current.elements.append(el("c4", .link, "Docs", x: 10, y: 260, w: 80, h: 20, interactive: true))

            let output = SnapshotSerializer().serializeDelta(from: previous, to: current)
            let expected = """
            <screen delta> app=App window="W"
            + c4 link "Docs" (10,260 80x20)
            ~ c2 val="ab"
            - p3
            unchanged: 5 elements
            </screen>
            """
            t.expectEqual(output, expected)
        },

        TestCase("delta with no changes reports only unchanged count") {
            let previous = formSnapshot(ids: ["p1", "p2", "p5", "p6", "p7", "p8"], fieldValue: "a")
            let current = formSnapshot(ids: ["c1", "c2", "c5", "c6", "c7", "c8"], fieldValue: "a")
            let expected = """
            <screen delta> app=App window="W"
            unchanged: 6 elements
            </screen>
            """
            t.expectEqual(SnapshotSerializer().serializeDelta(from: previous, to: current), expected)
        },

        TestCase("delta position change emits position only") {
            let previous = formSnapshot(ids: ["p1", "p2", "p5", "p6", "p7", "p8"], fieldValue: "a")
            let current = formSnapshot(ids: ["c1", "c2", "c5", "c6", "c7", "c8"], fieldValue: "a", saveX: 15)
            let output = SnapshotSerializer().serializeDelta(from: previous, to: current)
            t.expect(output.contains("~ c1 (15,10 100x30)"), "position-only change line: \(output)")
            t.expect(!output.contains("~ c1 val="), "no value in position-only change")
        },

        TestCase("delta value+position change emits both") {
            var previous = formSnapshot(ids: ["p1", "p2", "p5", "p6", "p7", "p8"], fieldValue: "a")
            var current = formSnapshot(ids: ["c1", "c2", "c5", "c6", "c7", "c8"], fieldValue: "b")
            previous.elements[1].frame.origin.x = 10
            current.elements[1].frame.origin.x = 40
            let output = SnapshotSerializer().serializeDelta(from: previous, to: current)
            t.expect(output.contains("~ c2 val=\"b\" (40,50 200x28)"), "both fields emitted: \(output)")
        },

        TestCase("delta falls back to full when window changed") {
            var previous = formSnapshot(ids: ["p1", "p2", "p5", "p6", "p7", "p8"], fieldValue: "a")
            previous.windowTitle = "Other"
            let current = formSnapshot(ids: ["c1", "c2", "c5", "c6", "c7", "c8"], fieldValue: "a")
            let output = SnapshotSerializer().serializeDelta(from: previous, to: current)
            t.expect(output.hasPrefix("<screen> app=App"), "full block on window change: \(output)")
        },

        TestCase("delta falls back to full when app changed") {
            var previous = formSnapshot(ids: ["p1", "p2", "p5", "p6", "p7", "p8"], fieldValue: "a")
            previous.appName = "OtherApp"
            let current = formSnapshot(ids: ["c1", "c2", "c5", "c6", "c7", "c8"], fieldValue: "a")
            t.expect(
                SnapshotSerializer().serializeDelta(from: previous, to: current).hasPrefix("<screen> app=App"),
                "full block on app change"
            )
        },

        TestCase("delta falls back to full when most elements changed") {
            let previous = ScreenSnapshot(
                appName: "App",
                windowTitle: "W",
                elements: [
                    el("p1", .textField, "A", val: "1", x: 0, y: 0, w: 100, h: 20, interactive: true),
                    el("p2", .textField, "B", val: "2", x: 0, y: 30, w: 100, h: 20, interactive: true),
                    el("p3", .textField, "C", val: "3", x: 0, y: 60, w: 100, h: 20, interactive: true),
                ]
            )
            let current = ScreenSnapshot(
                appName: "App",
                windowTitle: "W",
                elements: [
                    el("c1", .textField, "A", val: "9", x: 0, y: 0, w: 100, h: 20, interactive: true),
                    el("c2", .textField, "B", val: "8", x: 0, y: 30, w: 100, h: 20, interactive: true),
                    el("c3", .textField, "C", val: "7", x: 0, y: 60, w: 100, h: 20, interactive: true),
                ]
            )
            let output = SnapshotSerializer().serializeDelta(from: previous, to: current)
            t.expect(output.hasPrefix("<screen> app=App"), "ratio fallback to full: \(output)")
        },

        TestCase("diff matches duplicate titles by nearest position") {
            let previous = [
                el("p1", .button, "Go", x: 0, y: 0, w: 50, h: 20, interactive: true),
                el("p2", .button, "Go", x: 500, y: 0, w: 50, h: 20, interactive: true),
            ]
            let current = [
                el("c1", .button, "Go", x: 2, y: 0, w: 50, h: 20, interactive: true),
                el("c2", .button, "Go", x: 498, y: 0, w: 50, h: 20, interactive: true),
            ]
            let result = SnapshotDiff.diff(previous: previous, current: current)
            t.expectEqual(result.added.count, 0, "no adds")
            t.expectEqual(result.removed.count, 0, "no removals")
            let pairs = Dictionary(uniqueKeysWithValues: result.matches.map { ($0.current.id, $0.previous.id) })
            t.expectEqual(pairs["c1"], "p1", "left button matched to left")
            t.expectEqual(pairs["c2"], "p2", "right button matched to right")
        },

        TestCase("diff reports value changes") {
            let previous = [el("p1", .textField, "Q", val: "a", x: 0, y: 0, w: 100, h: 20, interactive: true)]
            let current = [el("c1", .textField, "Q", val: "b", x: 0, y: 0, w: 100, h: 20, interactive: true)]
            let result = SnapshotDiff.diff(previous: previous, current: current)
            t.expectEqual(result.changed.count, 1, "one change")
            t.expect(result.changed.first?.valueChanged == true, "value changed")
            t.expect(result.changed.first?.positionChanged == false, "position unchanged")
        },

        // MARK: v0.2 context enrichment

        TestCase("nil enrichment fields keep the v0.1 format exactly") {
            let output = SnapshotSerializer(tokenBudget: 5000).serialize(invoiceSnapshot())
            let expected = """
            <screen> app=Safari window="Invoice – Stripe" display=1/1 1512x982
            e1 window "Invoice – Stripe" (0,25)
            * e2 field "Amount" val="420.00" (612,388 220x28)
              e3 btn "Send invoice" (612,440 120x32)
                e4 text val="Total due" (20,100)
            </screen>
            """
            t.expectEqual(output, expected, "golden v0.1 compatibility")
        },

        TestCase("full format orders header url, also-open, selected, elements") {
            let output = SnapshotSerializer(tokenBudget: 5000).serialize(enrichedSnapshot())
            let expected = """
            <screen> app=Safari window="Docs \\"draft\\"" url="https://example.com/docs?q=1" display=1/1 1512x982
            also-open: "Mail — Inbox", "Xcode — wisp"
            selected: "important selected words"
            e1 window "Docs \\"draft\\"" (0,25)
              e2 btn "Share" (10,60 80x30)
            </screen>
            """
            t.expectEqual(output, expected, "golden enriched format")
        },

        TestCase("budget drops also-open before selected") {
            var withoutAlsoOpen = enrichedSnapshot()
            withoutAlsoOpen.openWindows = []
            let target = SnapshotSerializer(tokenBudget: 5000).serialize(withoutAlsoOpen)
            let budget = TokenEstimator.estimate(target)
            let output = SnapshotSerializer(tokenBudget: budget).serialize(enrichedSnapshot())
            t.expectEqual(output, target, "also-open sacrificed first, selection kept")
        },

        TestCase("budget drops selected before any element") {
            var bare = enrichedSnapshot()
            bare.openWindows = []
            bare.selectedText = nil
            let target = SnapshotSerializer(tokenBudget: 5000).serialize(bare)
            let budget = TokenEstimator.estimate(target)
            let output = SnapshotSerializer(tokenBudget: budget).serialize(enrichedSnapshot())
            t.expectEqual(output, target, "both context lines gone, all elements intact")
            t.expect(!output.contains("omitted"), "no element was dropped")
        },

        TestCase("selected line is capped to a single reasonable line") {
            var snapshot = enrichedSnapshot()
            snapshot.selectedText = String(repeating: "x", count: 1000)
            let output = SnapshotSerializer(tokenBudget: 5000).serialize(snapshot)
            let selectedLines = output.split(separator: "\n").filter { $0.hasPrefix("selected: ") }
            t.expectEqual(selectedLines.count, 1, "exactly one selected line")
            t.expect((selectedLines.first?.count ?? 0) <= 400, "line capped: \(selectedLines.first?.count ?? 0)")
            t.expect(selectedLines.first?.hasSuffix("…\"") == true, "ellipsis marks truncation")
        },

        TestCase("delta reports selection change, never also-open") {
            var previous = enrichedSnapshot()
            previous.selectedText = "old words"
            var current = enrichedSnapshot()
            current.selectedText = "new words"
            let output = SnapshotSerializer(tokenBudget: 5000).serializeDelta(from: previous, to: current)
            t.expect(output.hasPrefix("<screen delta> app=Safari"), "is a delta: \(output)")
            t.expect(output.contains("~ selected: \"new words\""), "selection change line present")
            t.expect(!output.contains("also-open"), "also-open never in deltas")
        },

        TestCase("delta reports selection removal") {
            var previous = enrichedSnapshot()
            previous.selectedText = "was selected"
            var current = enrichedSnapshot()
            current.selectedText = nil
            let output = SnapshotSerializer(tokenBudget: 5000).serializeDelta(from: previous, to: current)
            t.expect(output.contains("\n- selected\n"), "selection removal line present: \(output)")
        },

        TestCase("delta omits selection when unchanged and keeps url in header") {
            var previous = enrichedSnapshot()
            var current = enrichedSnapshot()
            current.elements[1].value = "v2"
            previous.elements[1].value = "v1"
            let output = SnapshotSerializer(tokenBudget: 5000).serializeDelta(from: previous, to: current)
            t.expect(!output.contains("selected"), "no selection lines when unchanged")
            t.expect(output.hasPrefix("<screen delta> app=Safari window=\"Docs \\\"draft\\\"\" url=\"https://example.com/docs?q=1\""), "delta header carries url: \(output)")
        },

        TestCase("url sanitizer truncates monster queries only") {
            let longQuery = "https://shop.example.com/results?" + String(repeating: "utm=x&", count: 40)
            let sanitizedLong = AXTreeCapture.sanitizeURLString(URL(string: longQuery)!)
            t.expect(sanitizedLong.hasSuffix("…"), "long query truncated")
            t.expect(sanitizedLong.count < longQuery.count, "shorter than original")
            t.expect(sanitizedLong.hasPrefix("https://shop.example.com/results?"), "path intact")
            let short = "https://example.com/a?b=1"
            t.expectEqual(AXTreeCapture.sanitizeURLString(URL(string: short)!), short, "short query untouched")
        },

        TestCase("selection normalizer collapses whitespace and caps length") {
            t.expectEqual(AXTreeCapture.normalizeSelection("  a\n\n b\tc  "), "a b c")
            let long = AXTreeCapture.normalizeSelection(String(repeating: "y", count: 400))
            t.expectEqual(long.count, 300, "capped at 300")
            t.expect(long.hasSuffix("…"), "ellipsis on cap")
        },
    ]
}

/// Fixture with every v0.2 enrichment populated.
private func enrichedSnapshot() -> ScreenSnapshot {
    ScreenSnapshot(
        appName: "Safari",
        appBundleID: "com.apple.Safari",
        windowTitle: "Docs \"draft\"",
        selectedText: "important selected words",
        browserURL: "https://example.com/docs?q=1",
        openWindows: ["Mail — Inbox", "Xcode — wisp"],
        displays: [mainDisplay],
        elements: [
            el("e1", .window, "Docs \"draft\"", x: 0, y: 25, w: 1512, h: 957, depth: 0),
            el("e2", .button, "Share", x: 10, y: 60, w: 80, h: 30, depth: 1, interactive: true),
        ]
    )
}
