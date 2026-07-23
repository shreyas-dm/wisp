import AppKit
import ApplicationServices
import Foundation
import WispKit

/// Watches which app/window has focus and records completed focus spans to
/// the local `ActivityLog` (the fuel for recall and distillation). Purely
/// local; started only when `activityLogEnabled` and never prompts — window
/// titles are read via AX only while Accessibility is already trusted.
@MainActor
final class ActivityTracker {
    private let activityLog = ActivityLog()
    private var appActivationObserver: NSObjectProtocol?
    private var titlePollTimer: Timer?

    private struct OpenSpan {
        var appName: String
        var windowTitle: String?
        var start: Date
    }

    private var openSpan: OpenSpan?
    private(set) var isRunning = false

    func start() {
        guard !isRunning else { return }
        isRunning = true
        beginSpanForFrontmostApp()

        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.beginSpanForFrontmostApp() }
        }

        // Same app, different window/tab: catch title changes with a slow
        // poll instead of per-app AX observers (cheap and robust).
        titlePollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshTitleIfChanged() }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        closeOpenSpan(at: Date())
        if let appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appActivationObserver)
        }
        appActivationObserver = nil
        titlePollTimer?.invalidate()
        titlePollTimer = nil
    }

    /// Flush the in-progress span (app termination).
    func flush() {
        closeOpenSpan(at: Date())
        if isRunning {
            beginSpanForFrontmostApp()
        }
    }

    // MARK: - Span management

    private func beginSpanForFrontmostApp() {
        let now = Date()
        closeOpenSpan(at: now)
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              let appName = frontmost.localizedName,
              frontmost.bundleIdentifier != Bundle.main.bundleIdentifier
        else {
            openSpan = nil
            return
        }
        openSpan = OpenSpan(
            appName: appName,
            windowTitle: Self.focusedWindowTitle(of: frontmost),
            start: now
        )
    }

    private func refreshTitleIfChanged() {
        guard let span = openSpan,
              let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.localizedName == span.appName
        else { return }
        let currentTitle = Self.focusedWindowTitle(of: frontmost)
        if currentTitle != span.windowTitle {
            let now = Date()
            closeOpenSpan(at: now)
            openSpan = OpenSpan(appName: span.appName, windowTitle: currentTitle, start: now)
        }
    }

    private func closeOpenSpan(at end: Date) {
        guard let span = openSpan else { return }
        openSpan = nil
        try? activityLog.recordSpan(
            appName: span.appName,
            windowTitle: span.windowTitle,
            start: span.start,
            end: end
        )
    }

    /// Focused window title of an app via AX; nil when Accessibility is not
    /// trusted (never prompts) or the app exposes none.
    private static func focusedWindowTitle(of app: NSRunningApplication) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let window = windowValue, CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        var titleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &titleValue) == .success,
              let title = titleValue as? String, !title.isEmpty
        else { return nil }
        return String(title.prefix(120))
    }
}
