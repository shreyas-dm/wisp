import AppKit
import AVFoundation
import Foundation
import WispKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var engine: CompanionEngine!
    private var menuBarController: MenuBarController!
    private var overlayController: OverlayController!
    private var hotkeyMonitor: HotkeyMonitor!
    private var textInputController: TextInputPanelController!
    private var memoryHistoryController: MemoryHistoryWindowController!
    private var instructionsController: InstructionsWindowController!
    private var activityTracker: ActivityTracker!
    private var onboardingController: OnboardingWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let configStore = WispConfigStore()
        let isFirstRun = !FileManager.default.fileExists(atPath: configStore.configURL.path)

        engine = CompanionEngine(configStore: configStore)
        overlayController = OverlayController(engine: engine)
        engine.overlay = overlayController
        textInputController = TextInputPanelController(engine: engine)
        memoryHistoryController = MemoryHistoryWindowController()
        instructionsController = InstructionsWindowController(engine: engine)

        // Local-only activity awareness, honoring the config toggle live.
        activityTracker = ActivityTracker()
        if engine.activityLogEnabled {
            activityTracker.start()
        }
        engine.onActivityLogToggled = { [weak self] enabled in
            if enabled {
                self?.activityTracker.start()
            } else {
                self?.activityTracker.stop()
            }
        }

        var actions = MenuBarPanelActions()
        actions.openMemoryWindow = { [weak self] tab in
            self?.memoryHistoryController.show(tab: tab)
        }
        actions.openTextInput = { [weak self] in
            guard let self else { return }
            self.textInputController.show(near: self.overlayController.orbScreenPointCocoa())
        }
        actions.openInstructions = { [weak self] in
            self?.instructionsController.show()
        }
        actions.quit = { NSApp.terminate(nil) }
        menuBarController = MenuBarController(engine: engine, actions: actions)

        hotkeyMonitor = HotkeyMonitor(
            onPress: { [weak self] in self?.engine.hotkeyPressed() },
            onRelease: { [weak self] in self?.engine.hotkeyReleased() }
        )
        // Esc cancels an in-flight interaction system-wide (listen-only tap
        // — nothing is swallowed, and idle presses are ignored here).
        hotkeyMonitor.onEscape = { [weak self] in
            guard let self else { return }
            if self.engine.state != .idle {
                self.engine.cancelInteraction()
            }
        }
        // ⌃⌥Space asks by typing. Holding ⌃⌥ starts push-to-talk first, so
        // cancel that listening stub before showing the input.
        hotkeyMonitor.onTextInputShortcut = { [weak self] in
            guard let self else { return }
            if self.engine.state == .listening {
                self.engine.cancelInteraction()
            }
            guard self.engine.state == .idle else { return }
            self.textInputController.toggle(near: self.overlayController.orbScreenPointCocoa())
        }
        hotkeyMonitor.start()

        let needsVoicePermissions = AVCaptureDevice.authorizationStatus(for: .audio) != .authorized
        if isFirstRun || !AXTreeCapture.isAccessibilityTrusted() || needsVoicePermissions {
            showOnboarding()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        activityTracker.stop()
        engine.persistSession()
    }

    private func showOnboarding() {
        let controller = OnboardingWindowController(onDismiss: { [weak self] in
            // Accessibility may have been granted — upgrade the hotkey path
            // from the NSEvent fallback to the CGEvent tap.
            self?.hotkeyMonitor.restart()
            self?.onboardingController = nil
        })
        onboardingController = controller
        controller.show()
    }
}
