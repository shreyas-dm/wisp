import AppKit
import SwiftUI

/// Borderless panels refuse key status by default; typing needs it. The
/// panel is still non-activating, so the frontmost app keeps focus overall.
private final class KeyableInputPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Floating "ask by typing" input, summoned with ⌃⌥Space or from the menu
/// panel. Appears near the orb, submits to the engine, dismisses on Esc,
/// Return, or an outside click.
@MainActor
final class TextInputPanelController {
    private let engine: CompanionEngine
    private var panel: NSPanel?
    private var outsideClickMonitor: Any?
    private var localKeyMonitor: Any?

    private let panelSize = NSSize(width: 380, height: 52)

    init(engine: CompanionEngine) {
        self.engine = engine
    }

    var isVisible: Bool { panel?.isVisible == true }

    func toggle(near screenPoint: NSPoint) {
        if isVisible {
            hide()
        } else {
            show(near: screenPoint)
        }
    }

    func show(near screenPoint: NSPoint) {
        let panel = self.panel ?? buildPanel()

        // Above the anchor point, clamped inside the screen's visible frame.
        let screen = NSScreen.screens.first { NSMouseInRect(screenPoint, $0.frame, false) } ?? NSScreen.main
        var origin = NSPoint(
            x: screenPoint.x - panelSize.width / 2,
            y: screenPoint.y + 28
        )
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 12), visible.maxX - panelSize.width - 12)
            origin.y = min(max(origin.y, visible.minY + 12), visible.maxY - panelSize.height - 12)
        }
        panel.setFrameOrigin(origin)
        panel.makeKeyAndOrderFront(nil)
        installMonitors()
    }

    func hide() {
        panel?.orderOut(nil)
        removeMonitors()
    }

    private func buildPanel() -> NSPanel {
        let newPanel = KeyableInputPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true
        newPanel.level = .screenSaver
        newPanel.hidesOnDeactivate = false
        newPanel.isReleasedWhenClosed = false
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let hostingView = NSHostingView(
            rootView: TextInputView(
                onSubmit: { [weak self] text in
                    self?.hide()
                    self?.engine.ask(text)
                },
                onDismiss: { [weak self] in self?.hide() }
            )
        )
        hostingView.frame = NSRect(origin: .zero, size: panelSize)
        newPanel.contentView = hostingView
        panel = newPanel
        return newPanel
    }

    // MARK: - Dismissal

    private func installMonitors() {
        removeMonitors()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if event.window !== self?.panel {
                Task { @MainActor in self?.hide() }
            }
            return event
        }
    }

    private func removeMonitors() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
        }
        outsideClickMonitor = nil
        localKeyMonitor = nil
    }
}

/// Dark-glass single-line input matching the response bubble's styling.
private struct TextInputView: View {
    let onSubmit: (String) -> Void
    let onDismiss: () -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 13))
                .foregroundStyle(Color(red: 0.55, green: 0.5, blue: 1.0))
            TextField("Ask about your screen…", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.92))
                .focused($focused)
                .onSubmit(submit)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.black.opacity(0.72))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 14, y: 4)
        .environment(\.colorScheme, .dark)
        .onAppear {
            text = ""
            focused = true
        }
        .onExitCommand(perform: onDismiss)
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            onDismiss()
            return
        }
        onSubmit(trimmed)
    }
}
