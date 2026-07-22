import AppKit
import AVFoundation
import Speech
import SwiftUI
import WispKit

/// First-run window that walks through the three permissions. This is the
/// only place in the app that triggers permission prompts, and only from
/// explicit button clicks.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let onDismiss: () -> Void

    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        super.init()
    }

    func show() {
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: OnboardingView(onFinish: { [weak self] in
            self?.close()
        }))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        onDismiss()
    }
}

struct OnboardingView: View {
    let onFinish: () -> Void

    @State private var accessibilityGranted = AXTreeCapture.isAccessibilityTrusted()
    @State private var screenRecordingGranted = ScreenshotCapture.hasScreenRecordingPermission()
    @State private var voiceGranted =
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        && SFSpeechRecognizer.authorizationStatus() == .authorized

    private let statusTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 0.42, green: 0.36, blue: 0.98),
                                         Color(red: 0.62, green: 0.32, blue: 0.92)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 52, height: 52)
                        .shadow(color: Color(red: 0.5, green: 0.44, blue: 1.0).opacity(0.5), radius: 16)
                }
                .padding(.top, 18)
                Text("Welcome to Wisp")
                    .font(.system(size: 22, weight: .bold))
                Text("A companion that sees your screen, listens, and points.\nGrant a few permissions and you're set.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 10) {
                PermissionCard(
                    title: "Accessibility",
                    detail: "Lets Wisp read the structure of your screen — this is how it knows what it's looking at. Required.",
                    granted: accessibilityGranted,
                    buttonTitle: "Grant Access"
                ) {
                    _ = AXTreeCapture.isAccessibilityTrusted(promptIfNeeded: true)
                    openSettingsPane("Privacy_Accessibility")
                }
                PermissionCard(
                    title: "Microphone & Speech",
                    detail: "Hold ⌃⌥ and talk. Transcription runs on-device when possible.",
                    granted: voiceGranted,
                    buttonTitle: "Enable Voice"
                ) {
                    Task {
                        _ = await AppleSpeechToText().requestPermissions()
                    }
                }
                PermissionCard(
                    title: "Screen Recording",
                    detail: "Optional — lets Wisp attach a screenshot for canvases, video, and games.",
                    granted: screenRecordingGranted,
                    buttonTitle: "Allow"
                ) {
                    ScreenshotCapture.requestScreenRecordingPermission()
                }
            }
            .padding(.horizontal, 24)

            Spacer()

            Button(action: onFinish) {
                Text(accessibilityGranted ? "Start using Wisp" : "Finish later")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(red: 0.5, green: 0.44, blue: 1.0))
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
            .pointerOnHover()
        }
        .frame(width: 460, height: 520)
        .onReceive(statusTimer) { _ in
            accessibilityGranted = AXTreeCapture.isAccessibilityTrusted()
            screenRecordingGranted = ScreenshotCapture.hasScreenRecordingPermission()
            voiceGranted =
                AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                && SFSpeechRecognizer.authorizationStatus() == .authorized
        }
    }

    private func openSettingsPane(_ pane: String) {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct PermissionCard: View {
    let title: String
    let detail: String
    let granted: Bool
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 20))
                .foregroundStyle(granted ? Color.green : Color.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if !granted {
                Button(buttonTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .pointerOnHover()
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.045))
        )
    }
}
