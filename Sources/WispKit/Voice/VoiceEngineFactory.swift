import Foundation

/// The secret ref used for both ElevenLabs STT and TTS.
public let elevenLabsAPIKeyRef = "ELEVENLABS_API_KEY"

/// Resolves the configured STT/TTS engines. `.auto` prefers the
/// state-of-the-art API engines (ElevenLabs) whenever their key resolves and
/// falls back to the local Apple engines, so Wisp always has a voice.
public enum VoiceEngineFactory {
    public static func makeSpeechToText(config: WispConfig, secrets: APIKeyResolving) -> SpeechToTextEngine {
        let key = secrets.apiKey(for: elevenLabsAPIKeyRef)
        switch config.sttEngine {
        case .apple:
            return AppleSpeechToText()
        case .whisper:
            if let base = config.whisperBaseURL, let url = URL(string: base) {
                return WhisperSpeechToText(
                    baseURL: url,
                    model: config.whisperModel,
                    apiKey: secrets.apiKey(for: "WHISPER_API_KEY")
                )
            }
            return AppleSpeechToText()
        case .elevenlabs, .auto:
            if let key {
                return ElevenLabsSpeechToText(apiKey: key, modelID: config.elevenLabsSTTModel)
            }
            return AppleSpeechToText()
        }
    }

    public static func makeTextToSpeech(config: WispConfig, secrets: APIKeyResolving) -> TextToSpeechEngine {
        let key = secrets.apiKey(for: elevenLabsAPIKeyRef)
        switch config.ttsEngine {
        case .apple, .whisper:
            return AppleTextToSpeech()
        case .elevenlabs, .auto:
            if let key {
                return ElevenLabsTextToSpeech(
                    apiKey: key,
                    voiceID: config.elevenLabsVoiceID,
                    modelID: config.elevenLabsTTSModel
                )
            }
            return AppleTextToSpeech()
        }
    }

    /// Human-readable engine names for `wisp doctor` and the menu panel.
    public static func engineDescriptions(config: WispConfig, secrets: APIKeyResolving) -> (stt: String, tts: String) {
        let hasKey = secrets.apiKey(for: elevenLabsAPIKeyRef) != nil
        func describe(_ choice: VoiceEngineChoice) -> String {
            switch choice {
            case .apple: return "Apple (local)"
            case .whisper: return "Whisper endpoint"
            case .elevenlabs: return hasKey ? "ElevenLabs" : "ElevenLabs (no key — using Apple)"
            case .auto: return hasKey ? "ElevenLabs (auto)" : "Apple (auto — add ELEVENLABS_API_KEY to upgrade)"
            }
        }
        return (describe(config.sttEngine), describe(config.ttsEngine))
    }
}
