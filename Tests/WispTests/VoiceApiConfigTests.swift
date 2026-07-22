import Foundation
@testable import WispKit

private struct StubSecrets: APIKeyResolving {
    let keys: [String: String]
    func apiKey(for ref: String) -> String? { keys[ref] }
}

func voiceApiConfigTests(_ t: TestRunner) -> [TestCase] {
    [
        TestCase("wav payload has correct RIFF structure") {
            let pcm = Data(repeating: 0xAB, count: 3200) // 0.1s @ 16kHz mono PCM16
            let wav = MicRecorder.wavData(fromPCM16: pcm, sampleRate: 16000, channels: 1)
            t.expectEqual(wav.count, 44 + 3200, "header is 44 bytes")
            t.expectEqual(String(data: wav.prefix(4), encoding: .ascii), "RIFF")
            t.expectEqual(String(data: wav.subdata(in: 8..<12), encoding: .ascii), "WAVE")
            let dataSize = wav.subdata(in: 40..<44).withUnsafeBytes { $0.load(as: UInt32.self) }
            t.expectEqual(Int(UInt32(littleEndian: dataSize)), 3200, "data chunk size")
            let sampleRate = wav.subdata(in: 24..<28).withUnsafeBytes { $0.load(as: UInt32.self) }
            t.expectEqual(Int(UInt32(littleEndian: sampleRate)), 16000, "sample rate")
        },
        TestCase("voice factory falls back to Apple without key") {
            let config = WispConfig.makeDefault()
            let stt = VoiceEngineFactory.makeSpeechToText(config: config, secrets: StubSecrets(keys: [:]))
            let tts = VoiceEngineFactory.makeTextToSpeech(config: config, secrets: StubSecrets(keys: [:]))
            t.expect(stt is AppleSpeechToText, "auto STT without key is Apple")
            t.expect(tts is AppleTextToSpeech, "auto TTS without key is Apple")
        },
        TestCase("voice factory prefers ElevenLabs when key resolves") {
            let config = WispConfig.makeDefault()
            let secrets = StubSecrets(keys: [elevenLabsAPIKeyRef: "xi-test"])
            let stt = VoiceEngineFactory.makeSpeechToText(config: config, secrets: secrets)
            let tts = VoiceEngineFactory.makeTextToSpeech(config: config, secrets: secrets)
            t.expect(stt is ElevenLabsSpeechToText, "auto STT with key is ElevenLabs")
            t.expect(tts is ElevenLabsTextToSpeech, "auto TTS with key is ElevenLabs")
        },
        TestCase("explicit apple engine wins even with key") {
            var config = WispConfig.makeDefault()
            config.ttsEngine = .apple
            let secrets = StubSecrets(keys: [elevenLabsAPIKeyRef: "xi-test"])
            let tts = VoiceEngineFactory.makeTextToSpeech(config: config, secrets: secrets)
            t.expect(tts is AppleTextToSpeech, "explicit apple respected")
        },
        TestCase("legacy config json without new keys decodes with defaults") {
            let legacy = """
            {"activeProfileID":"mock","profiles":[{"id":"mock","displayName":"Demo","apiStyle":"openai","baseURL":"http://localhost:0","model":"mock","supportsVision":false,"maxOutputTokens":512}],"voiceRepliesEnabled":false,"orbAlwaysVisible":true,"snapshotTokenBudget":900,"memoryTokenBudget":500,"historyTurnLimit":12}
            """
            let config = try JSONDecoder().decode(WispConfig.self, from: Data(legacy.utf8))
            t.expectEqual(config.screenContextMode, .hybrid, "default mode is hybrid")
            t.expectEqual(config.sttEngine, .auto)
            t.expectEqual(config.snapshotTokenBudget, 900, "existing keys preserved")
            t.expectEqual(config.voiceRepliesEnabled, false)
        },
        TestCase("screenshot modes degrade to structure for non-vision profiles") {
            let config = WispConfig.makeDefault() // hybrid default
            let vision = config.profiles.first { $0.id == "claude" }
            let textOnly = config.profiles.first { $0.id == "mock" }
            t.expectEqual(config.effectiveScreenContextMode(for: vision), .hybrid)
            t.expectEqual(config.effectiveScreenContextMode(for: textOnly), .structure)
        },
        TestCase("system prompt teaches screenshot fallback only when not already attached") {
            let withShot = SystemPrompt.build(memoryProfile: nil, supportsVision: true, screenshotIncluded: true)
            let withoutShot = SystemPrompt.build(memoryProfile: nil, supportsVision: true, screenshotIncluded: false)
            t.expect(withShot.contains("screenshot of the same screen is attached"), "hybrid wording present")
            t.expect(!withShot.contains("SCREENSHOT FALLBACK"), "no fallback section in hybrid")
            t.expect(withoutShot.contains("SCREENSHOT FALLBACK"), "fallback taught in structure mode")
        },
    ]
}
