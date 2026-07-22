import Foundation
import AVFoundation
import Speech
import WispKit

/// One diagnosed aspect of the installation. Shared by `wisp doctor` and the
/// menu bar panel's inline diagnostics.
struct DoctorCheck {
    enum Status {
        case pass
        case fail
        case neutral

        var symbol: String {
            switch self {
            case .pass: return "✓"
            case .fail: return "✗"
            case .neutral: return "–"
            }
        }
    }

    let name: String
    let status: Status
    let detail: String
    /// Critical checks decide the process exit code; the rest are warnings.
    let critical: Bool
}

enum DoctorChecks {
    /// Runs every check. Never triggers a permission prompt — statuses are
    /// only queried. Main-actor because the accessibility query is.
    @MainActor
    static func runAll() async -> [DoctorCheck] {
        var checks: [DoctorCheck] = []

        // Accessibility (screen snapshots).
        let accessibilityTrusted = AXTreeCapture.isAccessibilityTrusted()
        checks.append(DoctorCheck(
            name: "accessibility",
            status: accessibilityTrusted ? .pass : .fail,
            detail: accessibilityTrusted
                ? "trusted — screen snapshots available"
                : "not trusted — grant in System Settings › Privacy & Security › Accessibility",
            critical: false
        ))

        // Screen recording (hybrid screen context sends a screenshot each turn).
        let screenRecordingGranted = ScreenshotCapture.hasScreenRecordingPermission()
        checks.append(DoctorCheck(
            name: "screen recording",
            status: screenRecordingGranted ? .pass : .neutral,
            detail: screenRecordingGranted
                ? "granted — hybrid screen context available"
                : "not granted — hybrid mode will send snapshots only until granted",
            critical: false
        ))

        // Microphone.
        let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        checks.append(DoctorCheck(
            name: "microphone",
            status: microphoneStatus == .authorized ? .pass : (microphoneStatus == .notDetermined ? .neutral : .fail),
            detail: describeAuthorization(microphoneStatus),
            critical: false
        ))

        // Speech recognition.
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        let speechDescription: String
        let speechCheckStatus: DoctorCheck.Status
        switch speechStatus {
        case .authorized:
            speechDescription = "authorized"
            speechCheckStatus = .pass
        case .notDetermined:
            speechDescription = "not determined (will ask during onboarding)"
            speechCheckStatus = .neutral
        default:
            speechDescription = "denied — grant in System Settings › Privacy & Security › Speech Recognition"
            speechCheckStatus = .fail
        }
        checks.append(DoctorCheck(
            name: "speech recognition",
            status: speechCheckStatus,
            detail: speechDescription,
            critical: false
        ))

        // Config file.
        let configStore = WispConfigStore()
        let configPath = configStore.configURL.path
        var configIsValid = true
        if let data = try? Data(contentsOf: configStore.configURL) {
            configIsValid = (try? JSONDecoder().decode(WispConfig.self, from: data)) != nil
        }
        let config = configStore.load()
        checks.append(DoctorCheck(
            name: "config",
            status: configIsValid ? .pass : .fail,
            detail: configIsValid
                ? abbreviateHome(configPath)
                : "\(abbreviateHome(configPath)) failed to parse — using defaults",
            critical: true
        ))

        // Active model profile.
        if let profile = config.activeProfile {
            checks.append(DoctorCheck(
                name: "model profile",
                status: .pass,
                detail: "\(profile.displayName) (\(profile.model), \(profile.apiStyle.rawValue))",
                critical: true
            ))

            // API key for the active profile.
            let secrets = SecretsStore()
            if let keyRef = profile.apiKeyRef {
                let keyResolves = secrets.apiKey(for: keyRef) != nil
                checks.append(DoctorCheck(
                    name: "api key",
                    status: keyResolves ? .pass : .fail,
                    detail: keyResolves
                        ? "\(keyRef) resolves"
                        : "\(keyRef) not set — run: wisp key set \(keyRef)",
                    critical: false
                ))
            } else {
                checks.append(DoctorCheck(
                    name: "api key",
                    status: .neutral,
                    detail: "not needed for this profile",
                    critical: false
                ))
            }

            // Endpoint reachability.
            if profile.model == "mock" {
                checks.append(DoctorCheck(
                    name: "endpoint",
                    status: .neutral,
                    detail: "demo provider — no network needed",
                    critical: false
                ))
            } else {
                let reachability = await probeEndpoint(profile.baseURL)
                checks.append(DoctorCheck(
                    name: "endpoint",
                    status: reachability.reachable ? .pass : .fail,
                    detail: reachability.detail,
                    critical: false
                ))
            }
        } else {
            checks.append(DoctorCheck(
                name: "model profile",
                status: .fail,
                detail: "active profile '\(config.activeProfileID)' not found in config",
                critical: true
            ))
        }

        // Voice engines (STT/TTS selection incl. ElevenLabs upgrade path).
        let voiceDescriptions = VoiceEngineFactory.engineDescriptions(config: config, secrets: SecretsStore())
        checks.append(DoctorCheck(
            name: "voice engines",
            status: .pass,
            detail: "stt: \(voiceDescriptions.stt) · tts: \(voiceDescriptions.tts)",
            critical: false
        ))

        // TTS voice.
        if let voiceName = bestEnglishVoiceName() {
            checks.append(DoctorCheck(
                name: "tts voice",
                status: .pass,
                detail: voiceName,
                critical: false
            ))
        } else {
            checks.append(DoctorCheck(
                name: "tts voice",
                status: .neutral,
                detail: "no English voice installed — replies will be text-only",
                critical: false
            ))
        }

        return checks
    }

    static func renderReport(_ checks: [DoctorCheck]) -> String {
        let nameColumnWidth = (checks.map { $0.name.count }.max() ?? 0) + 2
        var lines = ["Wisp doctor"]
        for check in checks {
            let paddedName = check.name.padding(toLength: nameColumnWidth, withPad: " ", startingAt: 0)
            lines.append("  \(check.status.symbol) \(paddedName) \(check.detail)")
        }
        return lines.joined(separator: "\n")
    }

    static func allCriticalChecksPass(_ checks: [DoctorCheck]) -> Bool {
        checks.filter(\.critical).allSatisfy { $0.status != .fail }
    }

    // MARK: - Helpers

    private static func describeAuthorization(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .notDetermined: return "not determined (will ask during onboarding)"
        case .denied: return "denied — grant in System Settings › Privacy & Security › Microphone"
        case .restricted: return "restricted by policy"
        @unknown default: return "unknown"
        }
    }

    private static func probeEndpoint(_ baseURL: URL) async -> (reachable: Bool, detail: String) {
        var request = URLRequest(url: baseURL, timeoutInterval: 3)
        request.httpMethod = "GET"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                // Any HTTP status proves the host answers; auth errors are fine.
                return (true, "\(baseURL.absoluteString) reachable (HTTP \(httpResponse.statusCode))")
            }
            return (true, "\(baseURL.absoluteString) reachable")
        } catch {
            return (false, "\(baseURL.absoluteString) unreachable")
        }
    }

    private static func bestEnglishVoiceName() -> String? {
        let englishVoices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        guard !englishVoices.isEmpty else { return nil }
        func qualityRank(_ voice: AVSpeechSynthesisVoice) -> Int {
            switch voice.quality {
            case .premium: return 0
            case .enhanced: return 1
            default: return 2
            }
        }
        return englishVoices.min { qualityRank($0) < qualityRank($1) }?.name
    }

    private static func abbreviateHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
