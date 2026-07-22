import AppKit
import SwiftUI
import WispKit

/// The "what Wisp knows" window: a Memory tab (facts, deletable) and a
/// History tab (past session transcripts). The app activates while the
/// window is open and returns to accessory mode on close.
@MainActor
final class MemoryHistoryWindowController: NSObject, NSWindowDelegate {
    enum Tab: String, CaseIterable, Identifiable {
        case memory = "Memory"
        case history = "History"
        var id: String { rawValue }
    }

    private var window: NSWindow?
    private let selectedTab = SelectedTabModel()

    func show(tab: Tab) {
        selectedTab.tab = tab
        let window = self.window ?? buildWindow()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.center()
    }

    private func buildWindow() -> NSWindow {
        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 540),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "Wisp — Memory & History"
        newWindow.isReleasedWhenClosed = false
        newWindow.minSize = NSSize(width: 400, height: 380)
        newWindow.contentView = NSHostingView(rootView: MemoryHistoryView(selectedTab: selectedTab))
        newWindow.delegate = self
        window = newWindow
        return newWindow
    }

    func windowWillClose(_ notification: Notification) {
        // Back to menu-bar-only once the window goes away.
        NSApp.setActivationPolicy(.accessory)
    }
}

@MainActor
final class SelectedTabModel: ObservableObject {
    @Published var tab: MemoryHistoryWindowController.Tab = .memory
}

// MARK: - Root view

private struct MemoryHistoryView: View {
    @ObservedObject var selectedTab: SelectedTabModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab.tab) {
                ForEach(MemoryHistoryWindowController.Tab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            Divider()

            switch selectedTab.tab {
            case .memory: MemoryTabView()
            case .history: HistoryTabView()
            }
        }
        .frame(minWidth: 400, minHeight: 380)
    }
}

// MARK: - Memory tab

private struct MemoryTabView: View {
    @State private var facts: [MemoryFact] = []
    private let memory = MemoryStore()

    var body: some View {
        VStack(spacing: 0) {
            if facts.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(facts) { fact in
                        factRow(fact)
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Text("\(facts.count) fact\(facts.count == 1 ? "" : "s") · plain Markdown, edit freely")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reveal in Finder") {
                    try? FileManager.default.createDirectory(at: memory.directory, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([memory.factsURL])
                }
                .controlSize(.small)
            }
            .padding(10)
        }
        .onAppear(perform: reload)
    }

    private func factRow(_ fact: MemoryFact) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(fact.text)
                    .font(.system(size: 12.5))
                HStack(spacing: 6) {
                    Text(fact.source)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(sourceColor(fact.source).opacity(0.18)))
                        .foregroundStyle(sourceColor(fact.source))
                    if fact.createdAt != .distantPast {
                        Text(fact.createdAt, style: .date)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button {
                try? memory.deleteFact(id: fact.id)
                reload()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .pointerOnHover()
            .help("Forget this")
        }
        .padding(.vertical, 3)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "brain")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("Wisp hasn't remembered anything yet.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("Durable facts from your conversations will appear here.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func reload() {
        facts = memory.allFacts().sorted { $0.createdAt > $1.createdAt }
    }

    private func sourceColor(_ source: String) -> Color {
        switch source {
        case "model": return Color(red: 0.5, green: 0.44, blue: 1.0)
        case "distilled": return Color(red: 0.3, green: 0.7, blue: 0.9)
        default: return Color(red: 0.4, green: 0.75, blue: 0.5)
        }
    }
}

// MARK: - History tab

private struct SessionDay: Identifiable {
    let id: String        // "2026-07-23"
    let entries: [SessionEntry]
}

private struct SessionEntry: Identifiable {
    let id = UUID()
    let time: String      // "14:05"
    let lines: [(speaker: String, text: String)]
}

private struct HistoryTabView: View {
    @State private var days: [SessionDay] = []

    var body: some View {
        Group {
            if days.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("No conversations recorded yet.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(days) { day in
                            dayView(day)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .onAppear(perform: reload)
    }

    private func dayView(_ day: SessionDay) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(day.id)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(day.entries) { entry in
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.time)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    ForEach(Array(entry.lines.enumerated()), id: \.offset) { _, line in
                        transcriptRow(speaker: line.speaker, text: line.text)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.primary.opacity(0.04))
                )
            }
        }
    }

    private func transcriptRow(speaker: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(speaker == "user" ? "you" : "wisp")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(speaker == "user" ? Color.secondary : Color(red: 0.5, green: 0.44, blue: 1.0))
                .frame(width: 34, alignment: .trailing)
            Text(text)
                .font(.system(size: 12))
                .textSelection(.enabled)
        }
    }

    /// Parses the session logs MemoryStore writes: `sessions/YYYY-MM-DD.md`
    /// files with `## HH:MM` sections of `user:`/`wisp:` lines.
    private func reload() {
        let sessionsDirectory = MemoryStore().sessionsDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: nil
        ) else {
            days = []
            return
        }
        days = files
            .filter { $0.pathExtension == "md" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .compactMap { fileURL in
                guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
                let entries = Self.parseEntries(from: content)
                guard !entries.isEmpty else { return nil }
                return SessionDay(id: fileURL.deletingPathExtension().lastPathComponent, entries: entries)
            }
    }

    static func parseEntries(from content: String) -> [SessionEntry] {
        var entries: [SessionEntry] = []
        var currentTime: String?
        var currentLines: [(String, String)] = []

        func flush() {
            if let currentTime, !currentLines.isEmpty {
                entries.append(SessionEntry(time: currentTime, lines: currentLines))
            }
            currentLines = []
        }

        for line in content.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                flush()
                currentTime = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("user: ") {
                currentLines.append(("user", String(line.dropFirst(6))))
            } else if line.hasPrefix("wisp: ") {
                currentLines.append(("wisp", String(line.dropFirst(6))))
            }
        }
        flush()
        // Newest conversation first within the day.
        return entries.reversed()
    }
}
