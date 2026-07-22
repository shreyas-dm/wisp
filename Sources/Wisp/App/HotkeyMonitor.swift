import AppKit
import Foundation

/// System-wide push-to-talk: fires `onPress` when ⌃ and ⌥ are both held,
/// `onRelease` when either lifts. Prefers a listen-only CGEvent tap (works
/// while any app has focus); falls back to NSEvent global+local monitors
/// when the tap cannot be created (no Accessibility trust yet).
@MainActor
final class HotkeyMonitor {
    var onPress: () -> Void
    var onRelease: () -> Void

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var comboHeld = false
    private(set) var usingEventTap = false

    init(onPress: @escaping () -> Void, onRelease: @escaping () -> Void) {
        self.onPress = onPress
        self.onRelease = onRelease
    }

    func start() {
        stop()
        if startEventTap() {
            usingEventTap = true
        } else {
            startMonitorFallback()
            usingEventTap = false
        }
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
        comboHeld = false
    }

    /// Called after onboarding may have granted Accessibility — upgrade from
    /// the fallback monitors to the event tap when possible.
    func restart() {
        start()
    }

    func handleFlags(controlHeld: Bool, optionHeld: Bool) {
        let held = controlHeld && optionHeld
        guard held != comboHeld else { return }
        comboHeld = held
        if held {
            onPress()
        } else {
            onRelease()
        }
    }

    fileprivate func reenableTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
    }

    // MARK: - CGEvent tap

    private func startEventTap() -> Bool {
        let eventMask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: hotkeyEventTapCallback,
            userInfo: selfPointer
        ) else {
            return false
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    // MARK: - NSEvent fallback

    private func startMonitorFallback() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let control = event.modifierFlags.contains(.control)
            let option = event.modifierFlags.contains(.option)
            Task { @MainActor in
                self?.handleFlags(controlHeld: control, optionHeld: option)
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let control = event.modifierFlags.contains(.control)
            let option = event.modifierFlags.contains(.option)
            Task { @MainActor in
                self?.handleFlags(controlHeld: control, optionHeld: option)
            }
            return event
        }
    }
}

/// C-convention callback for the CGEvent tap. Listen-only: the returned
/// event is ignored by the system, but returning it is the convention.
private func hotkeyEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()

    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        Task { @MainActor in monitor.reenableTap() }
    case .flagsChanged:
        let control = event.flags.contains(.maskControl)
        let option = event.flags.contains(.maskAlternate)
        Task { @MainActor in
            monitor.handleFlags(controlHeld: control, optionHeld: option)
        }
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}
