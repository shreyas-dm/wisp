import AppKit
import SwiftUI

/// Menu bar presence: a sparkles status item that toggles a custom floating
/// panel (borderless, non-activating, dismisses on outside clicks).
@MainActor
final class MenuBarController {
    private let engine: CompanionEngine
    private let actions: MenuBarPanelActions
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var hostingView: NSHostingView<MenuBarPanelView>?
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?

    private let panelWidth: CGFloat = 300

    init(engine: CompanionEngine, actions: MenuBarPanelActions) {
        self.engine = engine
        self.actions = actions
        buildStatusItem()
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Wisp")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(statusItemClicked)
        }
        statusItem = item
    }

    @objc private func statusItemClicked() {
        if panel?.isVisible == true {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        let panel = self.panel ?? buildPanel()
        positionPanel(panel)
        panel.orderFrontRegardless()
        installDismissMonitors()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        removeDismissMonitors()
    }

    private func buildPanel() -> NSPanel {
        let newPanel = NSPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: panelWidth, height: 380)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true
        newPanel.level = .statusBar
        newPanel.hidesOnDeactivate = false
        newPanel.isReleasedWhenClosed = false
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.becomesKeyOnlyIfNeeded = true

        let hosting = NSHostingView(
            rootView: MenuBarPanelView(engine: engine, actions: actions)
        )
        newPanel.contentView = hosting
        hostingView = hosting
        panel = newPanel
        return newPanel
    }

    /// The panel hugs its SwiftUI content (which grows with doctor results,
    /// the new-conversation button, etc.).
    private var panelSize: NSSize {
        let fitting = hostingView?.fittingSize ?? NSSize(width: panelWidth, height: 380)
        return NSSize(width: panelWidth, height: max(200, fitting.height))
    }

    private func positionPanel(_ panel: NSPanel) {
        guard let button = statusItem?.button, let buttonWindow = button.window else {
            return
        }
        let size = panelSize
        panel.setContentSize(size)
        let buttonFrame = buttonWindow.frame
        var origin = NSPoint(
            x: buttonFrame.maxX - size.width,
            y: buttonFrame.minY - size.height - 6
        )
        if let screen = buttonWindow.screen {
            origin.x = max(screen.visibleFrame.minX + 8, origin.x)
        }
        panel.setFrameOrigin(origin)
    }

    // MARK: - Dismissal

    private func installDismissMonitors() {
        removeDismissMonitors()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.hidePanel() }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            if event.window !== self?.panel {
                Task { @MainActor in self?.hidePanel() }
            }
            return event
        }
    }

    private func removeDismissMonitors() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
        }
        outsideClickMonitor = nil
        localClickMonitor = nil
    }
}
