import AppKit
import SwiftUI

/// Editor for the user's standing instructions ("answer in Hindi",
/// "assume I use Vim") — injected into every system prompt. Saved on close
/// and on ⌘S-free autosave when the window resigns key.
@MainActor
final class InstructionsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model = InstructionsModel()
    private weak var engine: CompanionEngine?

    init(engine: CompanionEngine) {
        self.engine = engine
    }

    func show() {
        model.text = engine?.customInstructions ?? ""
        let window = self.window ?? buildWindow()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.center()
    }

    private func buildWindow() -> NSWindow {
        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "Wisp — Instructions"
        newWindow.isReleasedWhenClosed = false
        newWindow.minSize = NSSize(width: 340, height: 220)
        newWindow.contentView = NSHostingView(rootView: InstructionsView(model: model))
        newWindow.delegate = self
        window = newWindow
        return newWindow
    }

    func windowWillClose(_ notification: Notification) {
        engine?.setCustomInstructions(model.text)
        NSApp.setActivationPolicy(.accessory)
    }
}

@MainActor
final class InstructionsModel: ObservableObject {
    @Published var text = ""
}

private struct InstructionsView: View {
    @ObservedObject var model: InstructionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Standing preferences Wisp follows in every conversation — tone, language, tools you use, how much detail you want.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $model.text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                )

            Text("Saved when you close this window.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(minWidth: 340, minHeight: 220)
    }
}
