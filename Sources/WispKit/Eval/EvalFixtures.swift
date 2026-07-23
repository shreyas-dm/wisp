import Foundation
import CoreGraphics

/// Synthetic screens for the built-in eval suite. Fixtures are deliberately
/// rich (15–40 elements) so pointing tasks have plausible distractors.
enum EvalFixtures {
    private static let display = DisplayInfo(
        index: 0,
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        isMain: true
    )

    private static func element(
        _ id: String,
        _ role: ElementRole,
        _ title: String?,
        value: String? = nil,
        x: CGFloat, y: CGFloat, w: CGFloat = 120, h: CGFloat = 28,
        depth: Int = 1,
        interactive: Bool = false,
        focused: Bool = false
    ) -> SnapshotElement {
        SnapshotElement(
            id: id,
            role: role,
            title: title,
            value: value,
            frame: CGRect(x: x, y: y, width: w, height: h),
            depth: depth,
            isInteractive: interactive,
            displayIndex: 0,
            isFocused: focused
        )
    }

    /// Browser storefront: search, cart, product links with prices, checkout.
    static func storefront() -> ScreenSnapshot {
        ScreenSnapshot(
            appName: "Safari",
            appBundleID: "com.apple.Safari",
            windowTitle: "Aurora Supply Co. — Cart",
            focusedElementID: "e4",
            browserURL: "https://aurorasupply.example/cart",
            displays: [display],
            elements: [
                element("e1", .window, "Aurora Supply Co. — Cart", x: 0, y: 25, w: 1512, h: 957, depth: 0),
                element("e2", .toolbar, nil, x: 0, y: 25, w: 1512, h: 52),
                element("e3", .button, "Back", x: 12, y: 38, w: 32, h: 26, interactive: true),
                element("e4", .textField, "Address", value: "aurorasupply.example/cart", x: 420, y: 38, w: 660, h: 30, interactive: true, focused: true),
                element("e5", .webArea, nil, x: 0, y: 90, w: 1512, h: 892),
                element("e6", .image, "Aurora Supply Co. logo", x: 60, y: 110, w: 180, h: 48, depth: 2),
                element("e7", .textField, "Search products", x: 480, y: 118, w: 380, h: 34, depth: 2, interactive: true),
                element("e8", .button, "Cart (2)", x: 1330, y: 118, w: 96, h: 34, depth: 2, interactive: true),
                element("e9", .link, "Home", x: 60, y: 180, w: 60, h: 24, depth: 2, interactive: true),
                element("e10", .link, "New arrivals", x: 140, y: 180, w: 110, h: 24, depth: 2, interactive: true),
                element("e11", .link, "Sale", x: 270, y: 180, w: 48, h: 24, depth: 2, interactive: true),
                element("e12", .staticText, nil, value: "Your cart", x: 60, y: 240, w: 200, h: 34, depth: 2),
                element("e13", .link, "Fjord wool blanket", x: 60, y: 300, w: 240, h: 26, depth: 3, interactive: true),
                element("e14", .staticText, nil, value: "$89.00", x: 1180, y: 300, w: 80, h: 26, depth: 3),
                element("e15", .button, "Remove", x: 1290, y: 300, w: 80, h: 26, depth: 3, interactive: true),
                element("e16", .link, "Cedar desk organizer", x: 60, y: 348, w: 240, h: 26, depth: 3, interactive: true),
                element("e17", .staticText, nil, value: "$60.00", x: 1180, y: 348, w: 80, h: 26, depth: 3),
                element("e18", .button, "Remove", x: 1290, y: 348, w: 80, h: 26, depth: 3, interactive: true),
                element("e19", .staticText, nil, value: "Subtotal", x: 980, y: 430, w: 100, h: 26, depth: 2),
                element("e20", .staticText, nil, value: "$149.00", x: 1180, y: 430, w: 90, h: 30, depth: 2),
                element("e21", .staticText, nil, value: "Shipping calculated at checkout", x: 980, y: 466, w: 300, h: 22, depth: 2),
                element("e22", .button, "Check out", x: 1180, y: 510, w: 190, h: 44, depth: 2, interactive: true),
                element("e23", .link, "Continue shopping", x: 60, y: 520, w: 160, h: 24, depth: 2, interactive: true),
            ]
        )
    }

    /// Mail client: inbox rows, compose button, focused reply field.
    static func mail() -> ScreenSnapshot {
        ScreenSnapshot(
            appName: "Mail",
            appBundleID: "com.apple.mail",
            windowTitle: "Inbox — 4 messages",
            focusedElementID: "e18",
            displays: [display],
            elements: [
                element("e1", .window, "Inbox — 4 messages", x: 0, y: 25, w: 1512, h: 957, depth: 0),
                element("e2", .toolbar, nil, x: 0, y: 25, w: 1512, h: 48),
                element("e3", .button, "New Message", x: 16, y: 34, w: 120, h: 30, interactive: true),
                element("e4", .button, "Reply", x: 156, y: 34, w: 64, h: 30, interactive: true),
                element("e5", .button, "Forward", x: 230, y: 34, w: 76, h: 30, interactive: true),
                element("e6", .button, "Delete", x: 320, y: 34, w: 64, h: 30, interactive: true),
                element("e7", .textField, "Search mail", x: 1240, y: 34, w: 250, h: 30, interactive: true),
                element("e8", .table, "Message list", x: 0, y: 80, w: 460, h: 900),
                element("e9", .row, "Sarah Lin — Invoice for July", value: "Hi, attaching the July invoice — let me know if the amount looks right.", x: 0, y: 84, w: 460, h: 72, depth: 2, interactive: true),
                element("e10", .row, "GitHub — Security alert", value: "A new SSH key was added to your account.", x: 0, y: 158, w: 460, h: 72, depth: 2, interactive: true),
                element("e11", .row, "Priya Patel — Standup notes", value: "Notes from today's standup are in the doc.", x: 0, y: 232, w: 460, h: 72, depth: 2, interactive: true),
                element("e12", .row, "Aurora Supply — Order shipped", value: "Your order #4417 has shipped.", x: 0, y: 306, w: 460, h: 72, depth: 2, interactive: true),
                element("e13", .group, "Reading pane", x: 470, y: 80, w: 1042, h: 900),
                element("e14", .staticText, nil, value: "Invoice for July", x: 500, y: 110, w: 400, h: 30, depth: 2),
                element("e15", .staticText, nil, value: "From: Sarah Lin <sarah@linstudio.example>", x: 500, y: 148, w: 420, h: 22, depth: 2),
                element("e16", .staticText, nil, value: "Hi, attaching the July invoice — let me know if the amount looks right. Total is $2,340.", x: 500, y: 190, w: 900, h: 60, depth: 2),
                element("e17", .group, "Reply area", x: 500, y: 700, w: 940, h: 220, depth: 2),
                element("e18", .textField, "Reply to Sarah Lin", value: "", x: 516, y: 716, w: 900, h: 140, depth: 3, interactive: true, focused: true),
                element("e19", .button, "Send", x: 1330, y: 872, w: 80, h: 32, depth: 3, interactive: true),
            ]
        )
    }

    /// Settings pane: sidebar rows, toggles, a slider.
    static func settings() -> ScreenSnapshot {
        ScreenSnapshot(
            appName: "System Settings",
            appBundleID: "com.apple.systempreferences",
            windowTitle: "Displays",
            displays: [display],
            elements: [
                element("e1", .window, "Displays", x: 300, y: 120, w: 920, h: 700, depth: 0),
                element("e2", .table, "Sidebar", x: 300, y: 120, w: 220, h: 700),
                element("e3", .row, "Wi-Fi", x: 300, y: 140, w: 220, h: 36, depth: 2, interactive: true),
                element("e4", .row, "Bluetooth", x: 300, y: 178, w: 220, h: 36, depth: 2, interactive: true),
                element("e5", .row, "Network", x: 300, y: 216, w: 220, h: 36, depth: 2, interactive: true),
                element("e6", .row, "Displays", x: 300, y: 254, w: 220, h: 36, depth: 2, interactive: true),
                element("e7", .row, "Sound", x: 300, y: 292, w: 220, h: 36, depth: 2, interactive: true),
                element("e8", .group, "Detail pane", x: 530, y: 120, w: 690, h: 700),
                element("e9", .staticText, nil, value: "Built-in Display", x: 560, y: 150, w: 300, h: 30, depth: 2),
                element("e10", .checkbox, "True Tone", value: "on", x: 1100, y: 200, w: 44, h: 26, depth: 2, interactive: true),
                element("e11", .checkbox, "Automatically adjust brightness", value: "off", x: 1100, y: 240, w: 44, h: 26, depth: 2, interactive: true),
                element("e12", .checkbox, "Bluetooth", value: "on", x: 1100, y: 280, w: 44, h: 26, depth: 2, interactive: true),
                element("e13", .slider, "Brightness", value: "75%", x: 560, y: 330, w: 400, h: 26, depth: 2, interactive: true),
                element("e14", .slider, "Text size", value: "3 of 7", x: 560, y: 372, w: 400, h: 26, depth: 2, interactive: true),
                element("e15", .popup, "Refresh rate", value: "120 Hz", x: 560, y: 420, w: 200, h: 30, depth: 2, interactive: true),
                element("e16", .button, "Advanced…", x: 1080, y: 760, w: 110, h: 32, depth: 2, interactive: true),
            ]
        )
    }

    /// Code editor: file tree, tabs, run button, an error line.
    static func codeEditor() -> ScreenSnapshot {
        ScreenSnapshot(
            appName: "CodePad",
            appBundleID: "dev.codepad.app",
            windowTitle: "wisp — main.swift",
            focusedElementID: "e12",
            displays: [display],
            elements: [
                element("e1", .window, "wisp — main.swift", x: 0, y: 25, w: 1512, h: 957, depth: 0),
                element("e2", .toolbar, nil, x: 0, y: 25, w: 1512, h: 44),
                element("e3", .button, "Run", x: 16, y: 32, w: 64, h: 30, interactive: true),
                element("e4", .button, "Stop", x: 90, y: 32, w: 64, h: 30, interactive: true),
                element("e5", .table, "Files", x: 0, y: 80, w: 240, h: 900),
                element("e6", .row, "main.swift", x: 0, y: 84, w: 240, h: 28, depth: 2, interactive: true),
                element("e7", .row, "App.swift", x: 0, y: 112, w: 240, h: 28, depth: 2, interactive: true),
                element("e8", .row, "Engine.swift", x: 0, y: 140, w: 240, h: 28, depth: 2, interactive: true),
                element("e9", .row, "Package.swift", x: 0, y: 168, w: 240, h: 28, depth: 2, interactive: true),
                element("e10", .tab, "main.swift", x: 250, y: 80, w: 130, h: 30, interactive: true),
                element("e11", .tab, "Engine.swift", x: 384, y: 80, w: 130, h: 30, interactive: true),
                element("e12", .textField, "Editor", value: "func start() { delegate.launch() }", x: 250, y: 116, w: 1260, h: 640, depth: 1, interactive: true, focused: true),
                element("e13", .group, "Issues", x: 250, y: 760, w: 1260, h: 100),
                element("e14", .staticText, nil, value: "error: cannot find 'delegate' in scope — main.swift:14", x: 266, y: 772, w: 700, h: 24, depth: 2),
                element("e15", .staticText, nil, value: "Build failed — 1 error, 0 warnings", x: 266, y: 802, w: 400, h: 24, depth: 2),
                element("e16", .group, "Terminal", x: 250, y: 870, w: 1260, h: 110),
                element("e17", .staticText, nil, value: "$ swift build", x: 266, y: 880, w: 300, h: 22, depth: 2),
            ]
        )
    }

    /// Video player: sparse AX (canvas) plus OCR-recognized text elements.
    static func videoPlayer() -> ScreenSnapshot {
        ScreenSnapshot(
            appName: "Vidra",
            appBundleID: "app.vidra.player",
            windowTitle: "Lecture 4",
            displays: [display],
            elements: [
                element("e1", .window, "Lecture 4", x: 0, y: 25, w: 1512, h: 957, depth: 0),
                element("e2", .group, "Video surface", x: 0, y: 70, w: 1512, h: 820),
                element("e3", .button, "Play", x: 40, y: 910, w: 44, h: 36, interactive: true),
                element("e4", .slider, "Seek", value: "12:41 / 48:20", x: 100, y: 914, w: 1100, h: 24, interactive: true),
                element("t1", .ocrText, nil, value: "Introduction to Neural Networks", x: 380, y: 140, w: 750, h: 54),
                element("t2", .ocrText, nil, value: "Subscribe", x: 1290, y: 120, w: 140, h: 40),
                element("t3", .ocrText, nil, value: "gradient descent minimizes the loss function step by step", x: 300, y: 800, w: 900, h: 36),
                element("t4", .ocrText, nil, value: "Lecture 4 of 12", x: 60, y: 120, w: 180, h: 30),
            ]
        )
    }
}
