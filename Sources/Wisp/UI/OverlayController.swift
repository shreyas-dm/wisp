import AppKit
import SwiftUI
import WispKit

/// A pointing request already converted into the overlay view's top-left
/// coordinate space.
struct PointRequest: Identifiable, Equatable {
    let id = UUID()
    let targetRectInView: CGRect
    let label: String?
}

@MainActor
final class PointerModel: ObservableObject {
    @Published var request: PointRequest?
}

/// Hosts the click-through overlay: the orb companion, the response bubble,
/// and the pointer animation layer. One persistent full-screen panel lives
/// on the main display; pointing at elements on other displays flashes an
/// ephemeral highlight panel there.
@MainActor
final class OverlayController {
    private let engine: CompanionEngine
    private let pointerModel = PointerModel()
    private var panel: NSPanel?
    private var pointerClearTask: Task<Void, Never>?
    private var screenChangeObserver: NSObjectProtocol?

    init(engine: CompanionEngine) {
        self.engine = engine
        buildPanel()
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.repositionPanel() }
        }
    }

    deinit {
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
        }
    }

    // MARK: - Engine hooks

    func interactionStarted() {
        panel?.orderFrontRegardless()
    }

    func interactionEnded() {
        // The orb/bubble fade via SwiftUI; the panel stays resident.
    }

    /// Points at an element frame given in global Quartz (top-left origin)
    /// coordinates on the given display.
    func point(atQuartzFrame quartzFrame: CGRect, on display: DisplayInfo, label: String?) {
        guard let panel, let panelScreen = panel.screen ?? NSScreen.main else { return }

        let panelDisplayFrame = Self.quartzFrame(of: panelScreen)
        if panelDisplayFrame.equalTo(display.frame, tolerance: 2) {
            let localRect = CGRect(
                x: quartzFrame.minX - display.frame.minX,
                y: quartzFrame.minY - display.frame.minY,
                width: quartzFrame.width,
                height: quartzFrame.height
            )
            pointerModel.request = PointRequest(targetRectInView: localRect, label: label)
            schedulePointerClear()
        } else if let targetScreen = Self.screen(matching: display) {
            let localRect = CGRect(
                x: quartzFrame.minX - display.frame.minX,
                y: quartzFrame.minY - display.frame.minY,
                width: quartzFrame.width,
                height: quartzFrame.height
            )
            flashRemoteRing(on: targetScreen, localRect: localRect)
        }
    }

    // MARK: - Panel lifecycle

    private func buildPanel() {
        guard let screen = NSScreen.main else { return }
        let newPanel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configureOverlayPanel(newPanel)
        let rootView = OverlayRootView(engine: engine, pointerModel: pointerModel)
        newPanel.contentView = NSHostingView(rootView: rootView)
        newPanel.setFrame(screen.frame, display: true)
        newPanel.orderFrontRegardless()
        panel = newPanel
    }

    private func configureOverlayPanel(_ panel: NSPanel) {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
    }

    private func repositionPanel() {
        guard let panel, let screen = NSScreen.main else { return }
        panel.setFrame(screen.frame, display: true)
    }

    private func schedulePointerClear() {
        pointerClearTask?.cancel()
        pointerClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard !Task.isCancelled else { return }
            self?.pointerModel.request = nil
        }
    }

    // MARK: - Remote display ring

    /// Brief highlight ring on a display other than the orb's: no flight
    /// animation (the orb is elsewhere), just the ring pulse.
    private func flashRemoteRing(on screen: NSScreen, localRect: CGRect) {
        let remotePanel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configureOverlayPanel(remotePanel)
        remotePanel.contentView = NSHostingView(rootView: RingFlashView(targetRect: localRect))
        remotePanel.setFrame(screen.frame, display: true)
        remotePanel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
            remotePanel.orderOut(nil)
        }
    }

    // MARK: - Display matching

    /// Global Quartz (top-left origin) frame of an NSScreen.
    private static func quartzFrame(of screen: NSScreen) -> CGRect {
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return .zero
        }
        return CGDisplayBounds(CGDirectDisplayID(screenNumber.uint32Value))
    }

    private static func screen(matching display: DisplayInfo) -> NSScreen? {
        NSScreen.screens.first { quartzFrame(of: $0).equalTo(display.frame, tolerance: 2) }
    }
}

private extension CGRect {
    func equalTo(_ other: CGRect, tolerance: CGFloat) -> Bool {
        abs(minX - other.minX) <= tolerance
            && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}
