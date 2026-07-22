import Foundation
import CoreGraphics

/// A semantic snapshot of what is on screen, built from the Accessibility
/// tree of the frontmost app. This is Wisp's primary screen context — it is
/// 10–20x cheaper in tokens than a screenshot and carries exact labels,
/// values, and frames the model can reference by element ID.
public struct ScreenSnapshot: Sendable, Equatable {
    public var appName: String
    public var appBundleID: String?
    public var windowTitle: String?
    /// ID of the element that currently has keyboard focus, if any.
    public var focusedElementID: String?
    public var displays: [DisplayInfo]
    /// Flattened element tree in depth-first order.
    public var elements: [SnapshotElement]
    public var capturedAt: Date

    public init(
        appName: String,
        appBundleID: String? = nil,
        windowTitle: String? = nil,
        focusedElementID: String? = nil,
        displays: [DisplayInfo] = [],
        elements: [SnapshotElement] = [],
        capturedAt: Date = Date()
    ) {
        self.appName = appName
        self.appBundleID = appBundleID
        self.windowTitle = windowTitle
        self.focusedElementID = focusedElementID
        self.displays = displays
        self.elements = elements
        self.capturedAt = capturedAt
    }
}

public struct DisplayInfo: Sendable, Equatable {
    /// 0-based index; 0 is the main display.
    public var index: Int
    /// Global (Quartz) frame of the display.
    public var frame: CGRect
    public var isMain: Bool

    public init(index: Int, frame: CGRect, isMain: Bool) {
        self.index = index
        self.frame = frame
        self.isMain = isMain
    }
}

/// Compact roles for serialization. Raw values are what the model sees, so
/// they are short but readable.
public enum ElementRole: String, Sendable, Codable, CaseIterable {
    case button = "btn"
    case link = "link"
    case textField = "field"
    case staticText = "text"
    case image = "img"
    case checkbox = "check"
    case radio = "radio"
    case popup = "popup"      // popup buttons / dropdowns
    case menuItem = "menu"
    case tab = "tab"
    case slider = "slider"
    case table = "table"
    case row = "row"
    case group = "grp"
    case toolbar = "toolbar"
    case webArea = "web"
    case scrollArea = "scroll"
    case window = "window"
    case other = "el"
}

public struct SnapshotElement: Sendable, Equatable, Identifiable {
    /// Short stable-within-snapshot ID, e.g. "e12". The model points at
    /// elements with `[[point:e12]]`.
    public var id: String
    public var role: ElementRole
    /// Accessible title/label, already trimmed.
    public var title: String?
    /// Current value (text field contents, checkbox state, slider value…),
    /// truncated by the capturer.
    public var value: String?
    /// Global (Quartz, top-left origin) frame.
    public var frame: CGRect
    /// Depth in the original AX tree, used for indentation in serialization.
    public var depth: Int
    /// Whether the user can act on it (click, type, toggle…).
    public var isInteractive: Bool
    /// Index into `ScreenSnapshot.displays` for the display containing this
    /// element's center.
    public var displayIndex: Int
    /// True if the element currently has keyboard focus.
    public var isFocused: Bool

    public init(
        id: String,
        role: ElementRole,
        title: String? = nil,
        value: String? = nil,
        frame: CGRect,
        depth: Int = 0,
        isInteractive: Bool = false,
        displayIndex: Int = 0,
        isFocused: Bool = false
    ) {
        self.id = id
        self.role = role
        self.title = title
        self.value = value
        self.frame = frame
        self.depth = depth
        self.isInteractive = isInteractive
        self.displayIndex = displayIndex
        self.isFocused = isFocused
    }
}
