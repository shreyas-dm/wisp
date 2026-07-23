import Foundation
@testable import WispKit

private func makeElement(
    _ id: String,
    role: ElementRole = .button,
    title: String? = nil,
    value: String? = nil,
    frame: CGRect = CGRect(x: 10, y: 10, width: 100, height: 30),
    isFocused: Bool = false
) -> SnapshotElement {
    SnapshotElement(
        id: id,
        role: role,
        title: title,
        value: value,
        frame: frame,
        depth: 1,
        isInteractive: role != .staticText && role != .ocrText,
        displayIndex: 0,
        isFocused: isFocused
    )
}

private func makeSnapshot(
    app: String = "TestApp",
    window: String? = "Main",
    focusedID: String? = nil,
    elements: [SnapshotElement]
) -> ScreenSnapshot {
    ScreenSnapshot(
        appName: app,
        windowTitle: window,
        focusedElementID: focusedID,
        displays: [DisplayInfo(index: 0, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), isMain: true)],
        elements: elements
    )
}

private func makeTempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("wisp-core-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let isoFormatter = ISO8601DateFormatter()

func coreV3Tests(_ t: TestRunner) -> [TestCase] {
    [
        // MARK: StepPlanBuilder.looksCompleted

        TestCase("step completes when the target disappears") {
            let step = WalkthroughStep(index: 1, elementID: "e2", instruction: "Open the File menu")
            let previous = makeSnapshot(elements: [
                makeElement("e1", title: "Other"),
                makeElement("e2", title: "File"),
            ])
            let current = makeSnapshot(elements: [makeElement("e1", title: "Other")])
            t.expect(StepPlanBuilder.looksCompleted(step: step, previous: previous, current: current), "disappeared target advances")
        },

        TestCase("step completes when the target's value changes") {
            let step = WalkthroughStep(index: 1, elementID: "e3", instruction: "Type the amount")
            let previous = makeSnapshot(elements: [makeElement("e3", role: .textField, title: "Amount", value: "")])
            let current = makeSnapshot(elements: [makeElement("e3", role: .textField, title: "Amount", value: "420")])
            t.expect(StepPlanBuilder.looksCompleted(step: step, previous: previous, current: current), "value change advances")
        },

        TestCase("step completes on window navigation") {
            let step = WalkthroughStep(index: 1, elementID: "e1", instruction: "Click Continue")
            let previous = makeSnapshot(window: "Step one", elements: [makeElement("e1", title: "Continue")])
            let current = makeSnapshot(window: "Step two", elements: [makeElement("e1", title: "Continue")])
            t.expect(StepPlanBuilder.looksCompleted(step: step, previous: previous, current: current), "window change advances")
        },

        TestCase("step completes when focus reaches the target") {
            let step = WalkthroughStep(index: 1, elementID: "e5", instruction: "Click into Search")
            let previous = makeSnapshot(elements: [makeElement("e5", role: .textField, title: "Search")])
            let current = makeSnapshot(
                focusedID: "e5",
                elements: [makeElement("e5", role: .textField, title: "Search", isFocused: true)]
            )
            t.expect(StepPlanBuilder.looksCompleted(step: step, previous: previous, current: current), "focus reached advances")
        },

        TestCase("unrelated changes do not complete a step") {
            let step = WalkthroughStep(index: 1, elementID: "e1", instruction: "Click Save")
            let previous = makeSnapshot(elements: [
                makeElement("e1", title: "Save"),
                makeElement("e2", role: .staticText, value: "3 items"),
            ])
            let current = makeSnapshot(elements: [
                makeElement("e1", title: "Save"),
                makeElement("e2", role: .staticText, value: "4 items"),
            ])
            t.expect(!StepPlanBuilder.looksCompleted(step: step, previous: previous, current: current), "unrelated change must not advance")
        },

        TestCase("OCR step completes when its text leaves the screen") {
            let step = WalkthroughStep(index: 1, elementID: "t1", instruction: "Dismiss the banner")
            let previous = makeSnapshot(elements: [makeElement("t1", role: .ocrText, value: "Accept cookies")])
            let current = makeSnapshot(elements: [makeElement("t1", role: .ocrText, value: "Welcome back")])
            t.expect(StepPlanBuilder.looksCompleted(step: step, previous: previous, current: current), "vanished OCR text advances")
        },

        TestCase("OCR step holds while its text is still visible") {
            let step = WalkthroughStep(index: 1, elementID: "t1", instruction: "Read the banner")
            let previous = makeSnapshot(elements: [makeElement("t1", role: .ocrText, value: "Accept cookies")])
            let current = makeSnapshot(elements: [
                makeElement("t1", role: .ocrText, value: "Accept cookies"),
                makeElement("t2", role: .ocrText, value: "New line appeared"),
            ])
            t.expect(!StepPlanBuilder.looksCompleted(step: step, previous: previous, current: current), "visible OCR text holds")
        },

        // MARK: MemorySearch

        TestCase("search finds a fact by keyword") {
            let store = MemoryStore(directory: makeTempDirectory())
            try store.appendFact("The user deploys with Docker Compose.", source: "model")
            try store.appendFact("The user prefers dark mode.", source: "model")
            let hits = MemorySearch(store: store).search(query: "docker deploy")
            t.expectEqual(hits.count, 1)
            t.expectEqual(hits.first?.source, .fact)
            t.expect(hits.first?.snippet.contains("Docker Compose") == true, "right fact found")
        },

        TestCase("search finds a session exchange with its date") {
            let store = MemoryStore(directory: makeTempDirectory())
            try FileManager.default.createDirectory(at: store.sessionsDirectory, withIntermediateDirectories: true)
            let sessionContent = "## 10:15\n\nuser: why is the docker build failing\nwisp: the base image tag is wrong\n\n"
            try sessionContent.write(
                to: store.sessionsDirectory.appendingPathComponent("2026-07-20.md"),
                atomically: true, encoding: .utf8
            )
            let hits = MemorySearch(store: store).search(query: "docker build failing")
            t.expectEqual(hits.count, 1)
            t.expectEqual(hits.first?.source, .session)
            t.expect(hits.first?.snippet.hasPrefix("on 2026-07-20:") == true, "snippet carries the day")
            t.expect(hits.first?.snippet.contains("base image tag") == true, "reply included")
            t.expect(hits.first?.date != nil, "dated hit")
        },

        TestCase("search finds activity lines") {
            let store = MemoryStore(directory: makeTempDirectory())
            let search = MemorySearch(store: store)
            try FileManager.default.createDirectory(at: search.activityDirectory, withIntermediateDirectories: true)
            let day = MemorySearch.dayFormatter.string(from: Date())
            let activityContent = "# Activity \(day)\n\n- 09:00–09:45 Figma — \"landing page\" (45m)\n"
            try activityContent.write(
                to: search.activityDirectory.appendingPathComponent("\(day).md"),
                atomically: true, encoding: .utf8
            )
            let hits = search.search(query: "figma landing")
            t.expectEqual(hits.count, 1)
            t.expectEqual(hits.first?.source, .activity)
        },

        TestCase("newer content outranks older on equal match") {
            let store = MemoryStore(directory: makeTempDirectory())
            let today = isoFormatter.string(from: Date())
            let lastYear = isoFormatter.string(from: Date(timeIntervalSinceNow: -300 * 86_400))
            let facts = """
            # Wisp memory

            - The user's kubernetes cluster runs at home.  <!-- id:aaaa0001 src:model at:\(lastYear) -->
            - The user's kubernetes upgrade is in progress.  <!-- id:aaaa0002 src:model at:\(today) -->
            """
            try facts.write(to: store.factsURL, atomically: true, encoding: .utf8)
            let hits = MemorySearch(store: store).search(query: "kubernetes")
            t.expectEqual(hits.count, 2)
            t.expect(hits[0].snippet.contains("upgrade") == true, "today's fact ranks first")
        },

        TestCase("token budget cuts hits but never the first") {
            let store = MemoryStore(directory: makeTempDirectory())
            for index in 1...5 {
                try store.appendFact(
                    "Gradle build note number \(index): " + String(repeating: "detail ", count: 30),
                    source: "model"
                )
            }
            let hits = MemorySearch(store: store).search(query: "gradle build", limit: 6, tokenBudget: 100)
            t.expect(!hits.isEmpty, "at least one hit survives a tiny budget")
            t.expect(hits.count < 5, "budget trims the tail (got \(hits.count))")
        },

        TestCase("no match yields empty results and honest rendering") {
            let store = MemoryStore(directory: makeTempDirectory())
            try store.appendFact("The user prefers dark mode.", source: "model")
            let hits = MemorySearch(store: store).search(query: "quantum chromodynamics")
            t.expectEqual(hits.count, 0)
            t.expectEqual(
                MemorySearch.renderHits(hits, query: "quantum chromodynamics"),
                "Local memory has nothing relevant to \"quantum chromodynamics\"."
            )
        },

        TestCase("renderHits formats source and date") {
            let date = MemorySearch.dayFormatter.date(from: "2026-07-21")!
            let hits = [MemorySearchHit(source: .fact, snippet: "The user uses zsh.", date: date, score: 1)]
            let rendered = MemorySearch.renderHits(hits, query: "shell")
            t.expectEqual(
                rendered,
                "Local memory results for \"shell\":\n- [fact · 2026-07-21] The user uses zsh."
            )
        },

        // MARK: ActivityLog

        TestCase("activity span records and parses back") {
            let log = ActivityLog(directory: makeTempDirectory())
            let start = Calendar.current.date(bySettingHour: 14, minute: 3, second: 0, of: Date())!
            let end = Calendar.current.date(byAdding: .minute, value: 18, to: start)!
            try log.recordSpan(appName: "Xcode", windowTitle: "wisp — Engine.swift", start: start, end: end)
            let lines = log.lines(on: start)
            t.expectEqual(lines.count, 1)
            t.expectEqual(lines[0], "- 14:03–14:21 Xcode — \"wisp — Engine.swift\" (18m)")
        },

        TestCase("sub-minute spans format in seconds and titles are optional") {
            let log = ActivityLog(directory: makeTempDirectory())
            let start = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!
            let end = start.addingTimeInterval(45)
            try log.recordSpan(appName: "Finder", windowTitle: nil, start: start, end: end)
            t.expectEqual(log.lines(on: start), ["- 09:00–09:00 Finder (45s)"])
        },

        TestCase("spans under the minimum are dropped") {
            let log = ActivityLog(directory: makeTempDirectory())
            let start = Date()
            try log.recordSpan(appName: "Blip", windowTitle: nil, start: start, end: start.addingTimeInterval(4))
            t.expectEqual(log.lines(on: start).count, 0)
        },

        TestCase("daySummary aggregates apps and windows") {
            let log = ActivityLog(directory: makeTempDirectory())
            let base = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: Date())!
            try log.recordSpan(appName: "Xcode", windowTitle: "wisp — Engine.swift", start: base, end: base.addingTimeInterval(70 * 60))
            try log.recordSpan(appName: "Safari", windowTitle: "GitHub", start: base.addingTimeInterval(71 * 60), end: base.addingTimeInterval(91 * 60))
            try log.recordSpan(appName: "Xcode", windowTitle: "wisp — Overlay.swift", start: base.addingTimeInterval(92 * 60), end: base.addingTimeInterval(152 * 60))
            let summary = log.daySummary(base)
            t.expect(summary?.hasPrefix("Xcode 2h10m, Safari 20m") == true, "apps ranked by time (got: \(summary ?? "nil"))")
            t.expect(summary?.contains("windows: \"wisp — Engine.swift\", \"GitHub\", \"wisp — Overlay.swift\"") == true, "windows listed (got: \(summary ?? "nil"))")
        },

        // MARK: MetricsLog

        TestCase("metrics append and read back") {
            let fileURL = makeTempDirectory().appendingPathComponent("metrics.jsonl")
            let log = MetricsLog(fileURL: fileURL)
            var first = TurnMetrics(profileID: "claude")
            first.firstTokenMs = 420
            first.outputTokens = 96
            var second = TurnMetrics(profileID: "glm")
            second.firstTokenMs = 900
            log.append(first)
            log.append(second)
            let recent = log.recent()
            t.expectEqual(recent.count, 2)
            t.expectEqual(recent[0].profileID, "claude")
            t.expectEqual(recent[0].firstTokenMs, 420)
            t.expectEqual(recent[1].profileID, "glm")
        },

        TestCase("corrupt metrics lines are skipped") {
            let fileURL = makeTempDirectory().appendingPathComponent("metrics.jsonl")
            let log = MetricsLog(fileURL: fileURL)
            log.append(TurnMetrics(profileID: "claude"))
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("{not json at all\n".utf8))
            try handle.close()
            log.append(TurnMetrics(profileID: "kimi"))
            let recent = log.recent()
            t.expectEqual(recent.count, 2, "corrupt line skipped, valid ones kept")
            t.expectEqual(recent.last?.profileID, "kimi")
        },
    ]
}
