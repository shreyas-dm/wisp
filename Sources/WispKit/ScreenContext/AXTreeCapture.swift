import Foundation
import ApplicationServices
import AppKit

public enum ScreenContextError: Error, Sendable, Equatable {
    case accessibilityNotTrusted
    case noFrontmostApp
    case captureFailed(String)
}

/// Captures a `ScreenSnapshot` from the Accessibility tree of the frontmost
/// application. Must run on the main actor because it talks to AppKit for
/// display and app information.
@MainActor
public final class AXTreeCapture {
    /// Traversal guardrails so pathological trees (Electron apps, giant web
    /// pages) stay fast. Exceeding any cap ends the walk gracefully with
    /// whatever was collected.
    public struct Limits: Sendable {
        public var maxElements: Int = 400
        public var maxDepth: Int = 25
        /// Raw recursion cap independent of emitted depth, so skipped
        /// wrapper chains cannot recurse forever.
        public var maxRawDepth: Int = 60
        public var maxChildrenPerNode: Int = 120
        public var maxWindows: Int = 3
        public var timeBudget: TimeInterval = 0.6

        public init() {}
    }

    public var limits = Limits()

    public init() {}

    /// Whether the app has Accessibility trust (System Settings › Privacy &
    /// Security › Accessibility). Pass `promptIfNeeded` to show the system
    /// prompt on first ask.
    public static func isAccessibilityTrusted(promptIfNeeded: Bool = false) -> Bool {
        if promptIfNeeded {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
        return AXIsProcessTrusted()
    }

    /// Walks the frontmost app's AX tree and returns a flattened snapshot.
    public func captureSnapshot() throws -> ScreenSnapshot {
        guard AXIsProcessTrusted() else {
            throw ScreenContextError.accessibilityNotTrusted
        }
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            throw ScreenContextError.noFrontmostApp
        }

        let appElement = AXUIElementCreateApplication(frontmostApp.processIdentifier)
        let displays = Self.currentDisplays()
        let focusedElement = Self.copyElement(appElement, kAXFocusedUIElementAttribute)

        let focusedWindow = Self.copyElement(appElement, kAXFocusedWindowAttribute)
        var windows = Self.copyElementArray(appElement, kAXWindowsAttribute)
        if windows.isEmpty, let focusedWindow {
            windows = [focusedWindow]
        }
        // Put the focused window first so it survives the caps.
        if let focusedWindow, let focusedPosition = windows.firstIndex(where: { CFEqual($0, focusedWindow) }), focusedPosition != 0 {
            windows.swapAt(0, focusedPosition)
        }
        windows = Array(windows.prefix(limits.maxWindows))

        let windowTitle = (focusedWindow ?? windows.first).flatMap { Self.copyString($0, kAXTitleAttribute) }

        var state = TraversalState(
            deadline: Date().addingTimeInterval(limits.timeBudget),
            screenUnion: displays.reduce(CGRect.null) { $0.union($1.frame) },
            displays: displays,
            focusedElement: focusedElement,
            limits: limits
        )

        for window in windows {
            traverse(window, emittedDepth: 0, rawDepth: 0, parentAXRole: nil, state: &state)
            if state.exhausted { break }
        }

        return ScreenSnapshot(
            appName: frontmostApp.localizedName ?? "Unknown",
            appBundleID: frontmostApp.bundleIdentifier,
            windowTitle: windowTitle,
            focusedElementID: state.focusedElementID,
            displays: displays,
            elements: state.elements,
            capturedAt: Date()
        )
    }

    // MARK: - Traversal

    private struct TraversalState {
        var elements: [SnapshotElement] = []
        var focusedElementID: String?
        var exhausted = false
        let deadline: Date
        let screenUnion: CGRect
        let displays: [DisplayInfo]
        let focusedElement: AXUIElement?
        let limits: Limits
    }

    private func traverse(
        _ element: AXUIElement,
        emittedDepth: Int,
        rawDepth: Int,
        parentAXRole: String?,
        state: inout TraversalState
    ) {
        if state.exhausted { return }
        if state.elements.count >= state.limits.maxElements
            || rawDepth > state.limits.maxRawDepth
            || Date() >= state.deadline {
            state.exhausted = true
            return
        }
        guard emittedDepth <= state.limits.maxDepth else { return }

        let axRole = Self.copyString(element, kAXRoleAttribute) ?? ""
        let frame = Self.frame(of: element)

        var childDepth = emittedDepth
        var shouldEmit = false
        var emitted: SnapshotElement?

        if let frame {
            // Fully offscreen subtrees (scrolled-away content) are useless
            // to describe; prune them entirely. Zero-sized elements are
            // often layout wrappers whose children are visible — descend.
            let hasArea = frame.width > 0 && frame.height > 0
            if hasArea && state.screenUnion.intersection(frame).isNull {
                return
            }

            if hasArea {
                let mappedRole = Self.mapRole(axRole, parentAXRole: parentAXRole)
                let title = Self.bestTitle(of: element)
                let value = Self.stringValue(of: element, mappedRole: mappedRole)
                let isDecorativeWrapper =
                    (mappedRole == .group || mappedRole == .other || mappedRole == .scrollArea || mappedRole == .webArea)
                    && title == nil && value == nil
                shouldEmit = !isDecorativeWrapper

                if shouldEmit {
                    let elementID = "e\(state.elements.count + 1)"
                    let isFocused = state.focusedElement.map { CFEqual($0, element) } ?? false
                    let interactive = Self.isInteractive(element, mappedRole: mappedRole)
                    let snapshotElement = SnapshotElement(
                        id: elementID,
                        role: mappedRole,
                        title: title,
                        value: value,
                        frame: frame,
                        depth: emittedDepth,
                        isInteractive: interactive,
                        displayIndex: Self.displayIndex(for: frame, in: state.displays),
                        isFocused: isFocused
                    )
                    state.elements.append(snapshotElement)
                    emitted = snapshotElement
                    if isFocused {
                        state.focusedElementID = elementID
                    }
                    childDepth = emittedDepth + 1
                }
            }
        }
        _ = emitted

        // Menus/menu bars hang off windows in some apps but are invisible;
        // AXMenuBar is captured implicitly if on screen. Descend either way.
        let children = Self.copyElementArray(element, kAXChildrenAttribute)
        guard !children.isEmpty else { return }
        for child in children.prefix(state.limits.maxChildrenPerNode) {
            traverse(
                child,
                emittedDepth: childDepth,
                rawDepth: rawDepth + 1,
                parentAXRole: axRole.isEmpty ? parentAXRole : axRole,
                state: &state
            )
            if state.exhausted { return }
        }
    }

    // MARK: - Role mapping

    static func mapRole(_ axRole: String, parentAXRole: String?) -> ElementRole {
        switch axRole {
        case "AXButton": return .button
        case "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox": return .textField
        case "AXStaticText": return .staticText
        case "AXLink": return .link
        case "AXImage": return .image
        case "AXCheckBox": return .checkbox
        case "AXRadioButton":
            // Radio buttons inside a tab group are the tabs themselves.
            return parentAXRole == "AXTabGroup" ? .tab : .radio
        case "AXPopUpButton", "AXMenuButton": return .popup
        case "AXMenuItem", "AXMenuBarItem": return .menuItem
        case "AXTabGroup": return .group
        case "AXSlider": return .slider
        case "AXTable", "AXOutline", "AXList": return .table
        case "AXRow", "AXCell": return .row
        case "AXGroup": return .group
        case "AXToolbar": return .toolbar
        case "AXWebArea": return .webArea
        case "AXScrollArea": return .scrollArea
        case "AXWindow", "AXSheet", "AXDrawer": return .window
        default: return .other
        }
    }

    private static let interactiveRoles: Set<ElementRole> = [
        .button, .link, .textField, .checkbox, .radio, .popup, .menuItem, .tab, .slider,
    ]

    static func isInteractive(_ element: AXUIElement, mappedRole: ElementRole) -> Bool {
        if interactiveRoles.contains(mappedRole) { return true }
        // Only pay for the actions query on roles that are plausibly
        // clickable despite a passive role (custom web widgets mostly).
        guard mappedRole == .image || mappedRole == .group || mappedRole == .other else { return false }
        var actionsRef: CFArray?
        guard AXUIElementCopyActionNames(element, &actionsRef) == .success,
              let actions = actionsRef as? [String]
        else { return false }
        return actions.contains(kAXPressAction)
    }

    // MARK: - Attribute helpers

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var valueRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &valueRef)
        guard result == .success else { return nil }
        return valueRef
    }

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copyAttribute(element, attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private static func copyElementArray(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        guard let value = copyAttribute(element, attribute),
              let array = value as? [AnyObject]
        else { return [] }
        return array.compactMap { item in
            guard CFGetTypeID(item) == AXUIElementGetTypeID() else { return nil }
            return (item as! AXUIElement)
        }
    }

    private static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        guard let value = copyAttribute(element, attribute) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// First non-empty of AXTitle / AXDescription / placeholder, capped.
    static func bestTitle(of element: AXUIElement) -> String? {
        let candidates = [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute]
        for attribute in candidates {
            if let title = copyString(element, attribute) {
                return truncate(title, to: 80)
            }
        }
        return nil
    }

    /// Stringified AXValue: bools as on/off for toggles, numbers rounded,
    /// strings truncated.
    static func stringValue(of element: AXUIElement, mappedRole: ElementRole) -> String? {
        guard let raw = copyAttribute(element, kAXValueAttribute) else { return nil }

        if let number = raw as? NSNumber {
            if mappedRole == .checkbox || mappedRole == .radio || mappedRole == .tab {
                return number.boolValue ? "on" : "off"
            }
            let doubleValue = number.doubleValue
            if doubleValue.rounded() == doubleValue {
                return String(Int(doubleValue))
            }
            return String(format: "%.2f", doubleValue)
        }
        if let string = raw as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return truncate(trimmed, to: 120)
        }
        return nil
    }

    static func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }

    /// Global top-left-origin frame from kAXPosition/kAXSize (already Quartz
    /// coordinates).
    static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionRef = copyAttribute(element, kAXPositionAttribute),
              let sizeRef = copyAttribute(element, kAXSizeAttribute),
              CFGetTypeID(positionRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue((positionRef as! AXValue), .cgPoint, &position),
              AXValueGetValue((sizeRef as! AXValue), .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    // MARK: - Displays

    /// NSScreen frames converted from Cocoa (bottom-left origin) to global
    /// Quartz (top-left origin) coordinates, matching AX element frames.
    static func currentDisplays() -> [DisplayInfo] {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return [] }
        let primaryHeight = primary.frame.maxY
        return screens.enumerated().map { index, screen in
            let cocoaFrame = screen.frame
            let quartzFrame = CGRect(
                x: cocoaFrame.origin.x,
                y: primaryHeight - cocoaFrame.maxY,
                width: cocoaFrame.width,
                height: cocoaFrame.height
            )
            return DisplayInfo(index: index, frame: quartzFrame, isMain: index == 0)
        }
    }

    static func displayIndex(for frame: CGRect, in displays: [DisplayInfo]) -> Int {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        for display in displays where display.frame.contains(center) {
            return display.index
        }
        return 0
    }
}
