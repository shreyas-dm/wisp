import ServiceManagement
import SwiftUI
import WispKit

/// Actions the panel triggers on its owning controllers.
struct MenuBarPanelActions {
    var openMemoryWindow: (MemoryHistoryWindowController.Tab) -> Void = { _ in }
    var openTextInput: () -> Void = {}
    var openInstructions: () -> Void = {}
    var quit: () -> Void = {}
}

/// Content of the menu bar dropdown panel: status, model picker, toggles,
/// session token stats, and quick actions.
struct MenuBarPanelView: View {
    @ObservedObject var engine: CompanionEngine
    let actions: MenuBarPanelActions

    @State private var modelListExpanded = false
    @State private var doctorChecks: [DoctorCheck]?
    @State private var doctorRunning = false
    @State private var loginItemEnabled = false
    @State private var loginItemNeedsApproval = false

    /// Launch-at-login only makes sense from the .app bundle; the bare CLI
    /// binary has no bundle identity to register.
    private var runningFromAppBundle: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            hotkeyHint
            modelSection
            togglesSection
            tokenLine
            Divider().overlay(Color.white.opacity(0.1))
            actionsRow
            if let doctorChecks {
                doctorResults(doctorChecks)
            }
        }
        .padding(16)
        .frame(width: 300, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.09, green: 0.09, blue: 0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
        .environment(\.colorScheme, .dark)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(stateColor)
                .frame(width: 8, height: 8)
            Text("Wisp")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            Text(stateLabel)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    private var hotkeyHint: some View {
        HStack(spacing: 6) {
            Text("Hold")
                .foregroundStyle(.white.opacity(0.55))
            Text("⌃ ⌥")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.12)))
                .foregroundStyle(.white.opacity(0.9))
            Text("and talk about your screen")
                .foregroundStyle(.white.opacity(0.55))
        }
        .font(.system(size: 12))
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MODEL")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    modelListExpanded.toggle()
                }
            } label: {
                HStack {
                    Text(activeProfileName)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.9))
                    Spacer()
                    Image(systemName: modelListExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .pointerOnHover()

            if modelListExpanded {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(engine.profiles) { profile in
                        Button {
                            engine.setProfile(id: profile.id)
                            withAnimation(.easeInOut(duration: 0.18)) {
                                modelListExpanded = false
                            }
                        } label: {
                            HStack {
                                Text(profile.displayName)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(.white.opacity(0.85))
                                Spacer()
                                if profile.id == engine.activeProfileID {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(Color(red: 0.55, green: 0.5, blue: 1.0))
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .pointerOnHover()
                    }
                }
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
            }
        }
    }

    private var togglesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $engine.voiceRepliesEnabled) {
                Text("Voice replies")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.85))
            }
            Toggle(isOn: $engine.orbAlwaysVisible) {
                Text("Always show orb")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.85))
            }
            Toggle(isOn: $engine.activityLogEnabled) {
                Text("Activity log (local)")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .help("Remembers which apps you were using so you can ask about past work. Never leaves this Mac.")
            Toggle(isOn: loginItemBinding) {
                Text("Start Wisp at login")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(runningFromAppBundle ? 0.85 : 0.4))
            }
            .disabled(!runningFromAppBundle)
            .help(runningFromAppBundle ? "" : "Run from Wisp.app to enable")
            if loginItemNeedsApproval {
                Button {
                    SMAppService.openSystemSettingsLoginItems()
                } label: {
                    Text("Needs approval in System Settings → Login Items")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color(red: 0.95, green: 0.75, blue: 0.3))
                        .underline()
                }
                .buttonStyle(.plain)
                .pointerOnHover()
            }
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(Color(red: 0.5, green: 0.44, blue: 1.0))
        .onAppear(perform: refreshLoginItemStatus)
    }

    private var loginItemBinding: Binding<Bool> {
        Binding(
            get: { loginItemEnabled },
            set: { enable in
                do {
                    if enable {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    // Status refresh below surfaces the real state (e.g.
                    // requiresApproval) instead of a silently wrong toggle.
                }
                refreshLoginItemStatus()
            }
        )
    }

    private func refreshLoginItemStatus() {
        guard runningFromAppBundle else { return }
        let status = SMAppService.mainApp.status
        loginItemEnabled = status == .enabled
        loginItemNeedsApproval = status == .requiresApproval
    }

    private var tokenLine: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("session · ↑\(formatTokens(engine.sessionInputTokens)) ↓\(formatTokens(engine.sessionOutputTokens)) tokens")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
            if let lastTurnSummary = engine.lastTurnSummary {
                Text(lastTurnSummary)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.28))
                    .lineLimit(1)
            }
        }
    }

    private var actionsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            if engine.conversationTurnCount > 0 {
                panelActionButton("New conversation", systemImage: "plus.bubble") {
                    engine.resetConversation()
                }
            }
            HStack(spacing: 8) {
                panelActionButton("Memory", systemImage: "brain") {
                    actions.openMemoryWindow(.memory)
                }
                panelActionButton("History", systemImage: "clock.arrow.circlepath") {
                    actions.openMemoryWindow(.history)
                }
                panelActionButton("Type", systemImage: "keyboard") {
                    actions.openTextInput()
                }
            }
            HStack(spacing: 8) {
                panelActionButton("Instructions", systemImage: "text.alignleft") {
                    actions.openInstructions()
                }
                panelActionButton(doctorRunning ? "Checking…" : "Doctor", systemImage: "stethoscope") {
                    runDoctor()
                }
                Spacer()
                panelActionButton("Quit", systemImage: "power") {
                    actions.quit()
                }
            }
        }
    }

    private func doctorResults(_ checks: [DoctorCheck]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(checks.enumerated()), id: \.offset) { _, check in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(check.status.symbol)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(symbolColor(check.status))
                    Text(check.name)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                    Text(check.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(2)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
    }

    // MARK: - Helpers

    private func panelActionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10.5))
                Text(title)
                    .font(.system(size: 11.5))
            }
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerOnHover()
    }

    private func runDoctor() {
        guard !doctorRunning else { return }
        doctorRunning = true
        Task { @MainActor in
            let checks = await DoctorChecks.runAll()
            doctorChecks = checks
            doctorRunning = false
        }
    }

    private func symbolColor(_ status: DoctorCheck.Status) -> Color {
        switch status {
        case .pass: return Color(red: 0.3, green: 0.85, blue: 0.5)
        case .fail: return Color(red: 0.95, green: 0.4, blue: 0.4)
        case .neutral: return Color.white.opacity(0.4)
        }
    }

    private var activeProfileName: String {
        engine.profiles.first { $0.id == engine.activeProfileID }?.displayName ?? engine.activeProfileID
    }

    private var stateColor: Color {
        switch engine.state {
        case .idle: return Color.white.opacity(0.35)
        case .listening: return Color(red: 0.3, green: 0.85, blue: 0.5)
        case .thinking: return Color(red: 0.95, green: 0.75, blue: 0.3)
        case .responding, .speaking: return Color(red: 0.4, green: 0.6, blue: 0.98)
        case .walkthrough: return Color(red: 0.55, green: 0.5, blue: 1.0)
        }
    }

    private var stateLabel: String {
        switch engine.state {
        case .idle: return "ready"
        case .listening: return "listening"
        case .thinking: return "thinking"
        case .responding: return "responding"
        case .speaking: return "speaking"
        case .walkthrough(let stepIndex, let total): return "step \(stepIndex)/\(total)"
        }
    }

    private func formatTokens(_ count: Int) -> String {
        count >= 1000 ? String(format: "%.1fk", Double(count) / 1000) : "\(count)"
    }
}

/// Shows the pointing-hand cursor while hovering any interactive element.
struct PointerOnHover: ViewModifier {
    func body(content: Content) -> some View {
        content.onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

extension View {
    func pointerOnHover() -> some View {
        modifier(PointerOnHover())
    }
}
