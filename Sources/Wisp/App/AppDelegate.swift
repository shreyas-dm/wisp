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
    private var onboardingController: OnboardingWindowController?
    private var escapeKeyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let configStore = WispConfigStore()
        let isFirstRun = !FileManager.default.fileExists(atPath: configStore.configURL.path)

        engine = CompanionEngine(configStore: configStore)
        overlayController = OverlayController(engine: engine)
        engine.overlay = overlayController
        menuBarController = MenuBarController(engine: engine)

        hotkeyMonitor = HotkeyMonitor(
            onPress: { [weak self] in self?.engine.hotkeyPressed() },
            onRelease: { [weak self] in self?.engine.hotkeyReleased() }
        )
        hotkeyMonitor.start()

        // Esc cancels an in-flight interaction when any Wisp window has key
        // focus (system-wide Esc would require intrusive key taps).
        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                self?.engine.cancelInteraction()
            }
            return event
        }

        let needsVoicePermissions = AVCaptureDevice.authorizationStatus(for: .audio) != .authorized
        if isFirstRun || !AXTreeCapture.isAccessibilityTrusted() || needsVoicePermissions {
            showOnboarding()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.persistSession()
        if let escapeKeyMonitor {
            NSEvent.removeMonitor(escapeKeyMonitor)
        }
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
