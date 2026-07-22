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

/// Position of the draggable orb within the overlay view (top-left origin).
@MainActor
final class OrbPositionModel: ObservableObject {
    @Published var center: CGPoint = .zero
    @Published var isDragging = false
    /// Size of the overlay view, kept in sync so clamping and persistence
    /// can convert between points and screen fractions.
    var viewSize: CGSize = .zero

    static let orbDiameter: CGFloat = 30
    static let margin: CGFloat = 24

    func clamped(_ point: CGPoint) -> CGPoint {
        let inset = Self.orbDiameter / 2 + 8
        return CGPoint(
            x: min(max(point.x, inset), max(inset, viewSize.width - inset)),
            y: min(max(point.y, inset), max(inset, viewSize.height - inset))
        )
    }

    var defaultCenter: CGPoint {
        CGPoint(
            x: viewSize.width - Self.margin - Self.orbDiameter / 2,
            y: viewSize.height - Self.margin - Self.orbDiameter / 2
        )
    }
}

/// Hosts the click-through overlay: the orb companion, the response bubble,
/// and the pointer animation layer. One persistent full-screen panel lives
/// on the main display; pointing at elements on other displays flashes an
/// ephemeral highlight panel there. The panel stays click-through except
/// while the cursor hovers the orb, which lets the orb be dragged.
@MainActor
final class OverlayController {
    private let engine: CompanionEngine
    private let pointerModel = PointerModel()
    private let orbPosition = OrbPositionModel()
    private var panel: NSPanel?
    private var pointerClearTask: Task<Void, Never>?
    private var screenChangeObserver: NSObjectProtocol?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?

    private let positionDefaults = UserDefaults(suiteName: "so.wisp.app")

    init(engine: CompanionEngine) {
        self.engine = engine
        buildPanel()
        startHoverTracking()
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

    /// Where the orb currently sits, in global Cocoa (bottom-left origin)
    /// screen coordinates — used to place the floating text input nearby.
    func orbScreenPointCocoa() -> NSPoint {
        guard let panel, let screen = panel.screen ?? NSScreen.main else {
            return NSEvent.mouseLocation
        }
        return NSPoint(
            x: screen.frame.minX + orbPosition.center.x,
            y: screen.frame.maxY - orbPosition.center.y
        )
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
        orbPosition.viewSize = screen.frame.size
        restoreOrbPosition()
        let rootView = OverlayRootView(
            engine: engine,
            pointerModel: pointerModel,
            orbPosition: orbPosition,
            onOrbDragEnded: { [weak self] in self?.persistOrbPosition() }
        )
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
        orbPosition.viewSize = screen.frame.size
        restoreOrbPosition()
    }

    private func schedulePointerClear() {
        pointerClearTask?.cancel()
        pointerClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard !Task.isCancelled else { return }
            self?.pointerModel.request = nil
        }
    }

    // MARK: - Orb position persistence

    /// Stored as screen fractions, keyed by display count, so the position
    /// survives resolution changes and display plug/unplug sensibly.
    private var orbPositionKey: String {
        "orbPositionFraction-\(NSScreen.screens.count)displays"
    }

    private func restoreOrbPosition() {
        guard orbPosition.viewSize.width > 0, orbPosition.viewSize.height > 0 else { return }
        if let stored = positionDefaults?.string(forKey: orbPositionKey) {
            let parts = stored.split(separator: ",").compactMap { Double($0) }
            if parts.count == 2 {
                let point = CGPoint(
                    x: parts[0] * orbPosition.viewSize.width,
                    y: parts[1] * orbPosition.viewSize.height
                )
                orbPosition.center = orbPosition.clamped(point)
                return
            }
        }
        orbPosition.center = orbPosition.defaultCenter
    }

    private func persistOrbPosition() {
        guard orbPosition.viewSize.width > 0, orbPosition.viewSize.height > 0 else { return }
        let fractionX = orbPosition.center.x / orbPosition.viewSize.width
        let fractionY = orbPosition.center.y / orbPosition.viewSize.height
        positionDefaults?.set(String(format: "%.4f,%.4f", fractionX, fractionY), forKey: orbPositionKey)
    }

    // MARK: - Hover tracking

    /// The panel must stay click-through so Wisp never blocks the user's
    /// work — except when the cursor is over the orb, where mouse events are
    /// needed for dragging. Global+local mouse-moved monitors flip
    /// `ignoresMouseEvents` exactly within that window.
    private func startHoverTracking() {
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            Task { @MainActor in self?.updateHoverState() }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            Task { @MainActor in self?.updateHoverState() }
            return event
        }
    }

    private func updateHoverState() {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        // A hidden orb (transient mode, idle) must never intercept clicks.
        let orbIsVisible = engine.orbAlwaysVisible || engine.state != .idle
        guard orbIsVisible || orbPosition.isDragging else {
            if !panel.ignoresMouseEvents { panel.ignoresMouseEvents = true }
            return
        }
        let mouse = NSEvent.mouseLocation
        let localPoint = CGPoint(
            x: mouse.x - screen.frame.minX,
            y: screen.frame.maxY - mouse.y
        )
        let orbCenter = orbPosition.center
        let hoverRadius = OrbPositionModel.orbDiameter / 2 + 8
        let distance = hypot(localPoint.x - orbCenter.x, localPoint.y - orbCenter.y)
        let shouldReceiveMouse = distance <= hoverRadius || orbPosition.isDragging
        if panel.ignoresMouseEvents == shouldReceiveMouse {
            panel.ignoresMouseEvents = !shouldReceiveMouse
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
