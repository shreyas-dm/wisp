import Foundation
@testable import WispKit

/// Streams one fixed reply, then usage. For scoring tests.
private struct ScriptedEvalProvider: LLMProvider {
    let profile = LLMModelProfile(
        id: "scripted",
        displayName: "Scripted",
        apiStyle: .openaiCompatible,
        baseURL: URL(string: "http://localhost:0")!,
        model: "scripted"
    )
    let reply: String

    func streamChat(_ request: LLMChatRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let text = reply
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta(text))
            continuation.yield(.done(LLMUsage(inputTokens: 10, outputTokens: 20)))
            continuation.finish()
        }
    }
}

private struct FailingEvalProvider: LLMProvider {
    let profile = LLMModelProfile(
        id: "failing",
        displayName: "Failing",
        apiStyle: .openaiCompatible,
        baseURL: URL(string: "http://localhost:0")!,
        model: "failing"
    )

    func streamChat(_ request: LLMChatRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: LLMProviderError.network("scripted outage"))
        }
    }
}

private func makeEvalConfig() -> WispConfig {
    WispConfig.makeDefault()
}

private func singleTask(acceptable: Set<String> = ["e5"], keywords: [String] = []) -> EvalTask {
    EvalTask(
        id: "unit-task",
        snapshot: ScreenSnapshot(
            appName: "TestApp",
            displays: [DisplayInfo(index: 0, frame: CGRect(x: 0, y: 0, width: 1000, height: 700), isMain: true)],
            elements: [
                SnapshotElement(id: "e1", role: .window, title: "Test", frame: CGRect(x: 0, y: 0, width: 1000, height: 700)),
                SnapshotElement(id: "e5", role: .button, title: "Target", frame: CGRect(x: 10, y: 10, width: 80, height: 30), isInteractive: true),
            ]
        ),
        question: "Where do I click?",
        acceptablePointIDs: acceptable,
        keywords: keywords
    )
}

func evalTests(_ t: TestRunner) -> [TestCase] {
    [
        TestCase("built-in suite is coherent") {
            let tasks = EvalRunner.builtInTasks()
            t.expectEqual(tasks.count, 10)
            for task in tasks {
                let knownIDs = Set(task.snapshot.elements.map(\.id))
                for acceptable in task.acceptablePointIDs {
                    t.expect(knownIDs.contains(acceptable), "\(task.id): acceptable ID \(acceptable) exists in fixture")
                }
                t.expect(!task.question.isEmpty, "\(task.id) has a question")
                t.expect(!task.acceptablePointIDs.isEmpty || !task.keywords.isEmpty, "\(task.id) scores something")
            }
            let ocrTask = tasks.first { $0.id == "video-subscribe" }
            t.expect(ocrTask != nil, "OCR pointing task present")
            t.expect(ocrTask?.acceptablePointIDs.contains("t2") == true, "OCR task targets a t-element")
            t.expect(
                ocrTask?.snapshot.elements.contains { $0.role == .ocrText } == true,
                "video fixture carries ocrText elements"
            )
        },
        TestCase("runner completes the full suite against the demo provider") {
            let tasks = EvalRunner.builtInTasks()
            let provider = MockProvider(
                profile: makeEvalConfig().profiles.first { $0.id == "mock" }!,
                wordDelayNanoseconds: 0
            )
            let report = await EvalRunner().run(tasks: tasks, provider: provider, config: makeEvalConfig())
            t.expectEqual(report.results.count, 10)
            t.expect(report.results.allSatisfy { $0.latencyMs > 0 }, "latencies recorded")
            let rendered = report.render()
            t.expect(rendered.contains("Eval — profile mock"), "render names the profile")
            t.expect(rendered.contains("mean latency"), "render has the summary line")
        },
        TestCase("correct point scores true with no invented IDs") {
            let result = EvalRunner.score(
                task: singleTask(),
                rawReply: "Click the target button [[point:e5]].",
                latencyMs: 12,
                outputTokens: 9
            )
            t.expectEqual(result.pointedCorrectly, true)
            t.expect(result.inventedElementIDs.isEmpty, "no invented IDs")
            t.expect(result.comprehended == nil, "no keywords → comprehension unscored")
            t.expect(!result.replyExcerpt.contains("[[point"), "excerpt is de-tagged")
        },
        TestCase("wrong and invented point IDs are caught") {
            let result = EvalRunner.score(
                task: singleTask(),
                rawReply: "Try this one [[point:e99]].",
                latencyMs: 12,
                outputTokens: 9
            )
            t.expectEqual(result.pointedCorrectly, false)
            t.expectEqual(result.inventedElementIDs, ["e99"])
        },
        TestCase("step tags count as pointing attempts") {
            let result = EvalRunner.score(
                task: singleTask(),
                rawReply: "Here's how. [[step:e5:Click the target]]",
                latencyMs: 5,
                outputTokens: 4
            )
            t.expectEqual(result.pointedCorrectly, true)
        },
        TestCase("keyword scoring hits and misses") {
            let hit = EvalRunner.score(
                task: singleTask(acceptable: [], keywords: ["149"]),
                rawReply: "The total is $149.00 in the summary row.",
                latencyMs: 5,
                outputTokens: 4
            )
            t.expectEqual(hit.comprehended, true)
            t.expect(hit.pointedCorrectly == nil, "no point target → pointing unscored")

            let miss = EvalRunner.score(
                task: singleTask(acceptable: [], keywords: ["999"]),
                rawReply: "The total is $149.00.",
                latencyMs: 5,
                outputTokens: 4
            )
            t.expectEqual(miss.comprehended, false)
        },
        TestCase("scripted provider round-trips through run()") {
            let report = await EvalRunner().run(
                tasks: [singleTask()],
                provider: ScriptedEvalProvider(reply: "Click here [[point:e5]]."),
                config: makeEvalConfig()
            )
            t.expectEqual(report.results.count, 1)
            t.expectEqual(report.results[0].pointedCorrectly, true)
            t.expectEqual(report.results[0].outputTokens, 20)
        },
        TestCase("provider errors don't abort the run") {
            let report = await EvalRunner().run(
                tasks: [singleTask()],
                provider: FailingEvalProvider(),
                config: makeEvalConfig()
            )
            t.expectEqual(report.results.count, 1)
            t.expect(report.results[0].replyExcerpt.hasPrefix("ERROR:"), "failure surfaced in excerpt")
            t.expectEqual(report.results[0].pointedCorrectly, false)
        },
        TestCase("whisper endpoint URL building") {
            let plain = WhisperSpeechToText(baseURL: URL(string: "http://localhost:8080/v1")!)
            t.expectEqual(plain.endpointURL.path, "/v1/audio/transcriptions")
            let full = WhisperSpeechToText(baseURL: URL(string: "http://localhost:8080/v1/audio/transcriptions")!)
            t.expectEqual(full.endpointURL.path, "/v1/audio/transcriptions")
        },
        TestCase("whisper upload: multipart body, no bearer when keyless, transcript parsed") {
            StubHTTPProtocol.reset(script: [
                .init(status: 200, headers: ["Content-Type": "application/json"], chunks: [Data(#"{"text":" hello wisp "}"#.utf8)]),
            ])
            let engine = WhisperSpeechToText(
                baseURL: URL(string: "http://localhost:9999/v1")!,
                model: "whisper-large-v3",
                apiKey: nil,
                session: makeStubbedSession()
            )
            let wav = MicRecorder.wavData(fromPCM16: Data(repeating: 1, count: 640), sampleRate: 16000, channels: 1)
            let transcript = try await engine.transcribe(wav: wav)
            t.expectEqual(transcript, "hello wisp")

            let logged = StubHTTPProtocol.loggedRequests
            t.expectEqual(logged.count, 1)
            let request = logged[0].request
            t.expect(request.value(forHTTPHeaderField: "Authorization") == nil, "no bearer without a key")
            let body = logged[0].body ?? Data()
            let bodyText = String(decoding: body, as: UTF8.self)
            t.expect(bodyText.contains("name=\"model\""), "model field present")
            t.expect(bodyText.contains("whisper-large-v3"), "model value present")
            t.expect(bodyText.contains("RIFF"), "wav payload present")
        },
        TestCase("whisper sends bearer when a key exists") {
            StubHTTPProtocol.reset(script: [
                .init(status: 200, headers: ["Content-Type": "application/json"], chunks: [Data(#"{"text":"ok"}"#.utf8)]),
            ])
            let engine = WhisperSpeechToText(
                baseURL: URL(string: "http://localhost:9999/v1")!,
                apiKey: "gsk-test",
                session: makeStubbedSession()
            )
            _ = try await engine.transcribe(wav: Data(repeating: 0, count: 64))
            let request = StubHTTPProtocol.loggedRequests.first?.request
            t.expectEqual(request?.value(forHTTPHeaderField: "Authorization"), "Bearer gsk-test")
        },
    ]
}
