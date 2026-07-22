import Foundation
@testable import WispKit

func voiceMemoryTests(_ t: TestRunner) -> [TestCase] {
    var cases: [TestCase] = []

    // MARK: - SentenceChunker

    cases.append(TestCase("chunker emits sentence when boundary is followed by space") {
        var chunker = SentenceChunker()
        let emitted = chunker.consume("Hello there, friend. How are you?")
        t.expectEqual(emitted, ["Hello there, friend."])
        t.expectEqual(chunker.finish(), ["How are you?"])
    })

    cases.append(TestCase("chunker handles boundary split across deltas") {
        var chunker = SentenceChunker()
        var emitted = chunker.consume("This is sentence one")
        t.expectEqual(emitted, [])
        emitted = chunker.consume(". And sentence two follows here. ")
        t.expectEqual(emitted, ["This is sentence one.", "And sentence two follows here."])
    })

    cases.append(TestCase("chunker does not split on abbreviations") {
        var chunker = SentenceChunker()
        let emitted = chunker.consume("Use e.g. the menu bar to start things. ")
        t.expectEqual(emitted, ["Use e.g. the menu bar to start things."])
    })

    cases.append(TestCase("chunker does not split inside a decimal streamed in two parts") {
        var chunker = SentenceChunker()
        var emitted = chunker.consume("The value of pi is 3.")
        t.expectEqual(emitted, [])
        emitted = chunker.consume("14 roughly speaking. ")
        t.expectEqual(emitted, ["The value of pi is 3.14 roughly speaking."])
    })

    cases.append(TestCase("chunker does not treat version numbers as sentence ends") {
        var chunker = SentenceChunker()
        let emitted = chunker.consume("Install version 6.2. Then restart the app. ")
        t.expectEqual(emitted, ["Install version 6.2. Then restart the app."])
    })

    cases.append(TestCase("chunker cuts on newline") {
        var chunker = SentenceChunker()
        let emitted = chunker.consume("First line here okay\nSecond thing")
        t.expectEqual(emitted, ["First line here okay"])
        t.expectEqual(chunker.finish(), ["Second thing"])
    })

    cases.append(TestCase("chunker accumulates short sentences with the next one") {
        var chunker = SentenceChunker()
        let emitted = chunker.consume("Yes. Absolutely, that is correct. ")
        t.expectEqual(emitted, ["Yes. Absolutely, that is correct."])
    })

    cases.append(TestCase("chunker spills at last clause boundary when buffer runs long") {
        var chunker = SentenceChunker()
        let longRunOn = "one two three four five six seven eight nine ten, "
            + "eleven twelve thirteen fourteen fifteen sixteen seventeen, "
            + "eighteen nineteen twenty twentyone twentytwo twentythree twentyfour and more words"
        let emitted = chunker.consume(longRunOn)
        t.expectEqual(emitted.count, 1, "expected exactly one clause spill")
        if let clause = emitted.first {
            t.expect(clause.hasSuffix(","), "spill should cut at the last comma, got: \(clause)")
        }
        let flushed = chunker.finish()
        t.expectEqual(flushed, ["eighteen nineteen twenty twentyone twentytwo twentythree twentyfour and more words"])
    })

    cases.append(TestCase("chunker finish flushes remainder and empties") {
        var chunker = SentenceChunker()
        t.expectEqual(chunker.consume("hello"), [])
        t.expectEqual(chunker.finish(), ["hello"])
        t.expectEqual(chunker.finish(), [])
    })

    cases.append(TestCase("chunker never emits from whitespace-only input") {
        var chunker = SentenceChunker()
        t.expectEqual(chunker.consume("   \n  "), [])
        t.expectEqual(chunker.finish(), [])
    })

    // MARK: - MemoryStore

    func makeTemporaryStore() -> (MemoryStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisp-tests-\(UUID().uuidString)")
        return (MemoryStore(directory: directory), directory)
    }

    cases.append(TestCase("memory store appends and reads back a fact") {
        let (store, directory) = makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.appendFact("The user prefers Vim keybindings", source: "model")
        let facts = store.allFacts()
        t.expectEqual(facts.count, 1)
        t.expectEqual(facts.first?.text, "The user prefers Vim keybindings")
        t.expectEqual(facts.first?.source, "model")
    })

    cases.append(TestCase("memory store dedupes case-insensitively") {
        let (store, directory) = makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.appendFact("The user works in Swift", source: "model")
        try store.appendFact("the user works in swift", source: "distilled")
        t.expectEqual(store.allFacts().count, 1)
    })

    cases.append(TestCase("memory store parses hand-edited lines without metadata") {
        let (store, directory) = makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let handEdited = "# Wisp memory\n\n- The user likes green tea\n"
        try handEdited.data(using: .utf8)!.write(to: store.factsURL, options: .atomic)

        let facts = store.allFacts()
        t.expectEqual(facts.count, 1)
        t.expectEqual(facts.first?.text, "The user likes green tea")
        t.expectEqual(facts.first?.source, "user")
        t.expect(!(facts.first?.id.isEmpty ?? true), "hand-edited fact needs an id")
    })

    cases.append(TestCase("memory store deletes a fact by id, including hand-edited ones") {
        let (store, directory) = makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.appendFact("Fact number one to keep around", source: "model")
        try store.appendFact("Fact number two to delete soon", source: "model")
        let victim = store.allFacts().first { $0.text.contains("delete soon") }
        t.expect(victim != nil, "victim fact exists")
        if let victim {
            try store.deleteFact(id: victim.id)
        }
        let remaining = store.allFacts()
        t.expectEqual(remaining.count, 1)
        t.expectEqual(remaining.first?.text, "Fact number one to keep around")

        // Hand-edited fact: id derives stably from text.
        var content = try String(contentsOf: store.factsURL, encoding: .utf8)
        content += "- A hand written fact\n"
        try content.data(using: .utf8)!.write(to: store.factsURL, options: .atomic)
        let handEditedFact = store.allFacts().first { $0.text == "A hand written fact" }
        t.expect(handEditedFact != nil, "hand-edited fact parsed")
        if let handEditedFact {
            try store.deleteFact(id: handEditedFact.id)
        }
        t.expect(!store.allFacts().contains { $0.text == "A hand written fact" }, "hand-edited fact deleted")
    })

    cases.append(TestCase("memory profile is newest-first and budget-capped") {
        let (store, directory) = makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        // appendFact stamps time-of-call; write lines with explicit dates
        // instead so ordering is deterministic.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let content = """
        # Wisp memory

        - Oldest fact about the user  <!-- id:aaaaaaaa src:model at:2026-01-01T00:00:00Z -->
        - Middle fact about the user  <!-- id:bbbbbbbb src:model at:2026-03-01T00:00:00Z -->
        - Newest fact about the user  <!-- id:cccccccc src:model at:2026-06-01T00:00:00Z -->
        """
        try content.data(using: .utf8)!.write(to: store.factsURL, options: .atomic)

        let fullProfile = store.profile(tokenBudget: 500)
        t.expect(fullProfile?.hasPrefix("- Newest fact") ?? false, "newest first, got: \(fullProfile ?? "nil")")

        // Each "- Xxx fact about the user" line is ~7 tokens; a budget of
        // 15 fits exactly two lines.
        let cappedProfile = store.profile(tokenBudget: 15)
        let lineCount = cappedProfile?.components(separatedBy: "\n").count ?? 0
        t.expectEqual(lineCount, 2, "budget should cap the profile")
        t.expect(!(cappedProfile?.contains("Oldest") ?? true), "oldest dropped first")
    })

    cases.append(TestCase("memory profile is nil when empty") {
        let (store, directory) = makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        t.expect(store.profile(tokenBudget: 100) == nil, "no facts → nil profile")
    })

    cases.append(TestCase("recordSession strips screen blocks and images") {
        let (store, directory) = makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let messages = [
            ChatMessage(
                role: .user,
                text: "<screen> app=Safari window=\"News\"\ne1 btn \"Reload\" (10,10 20x20)\n</screen>\n\nWhat is on this page?"
            ),
            ChatMessage(role: .assistant, text: "A news article about sailing."),
            ChatMessage(role: .user, text: "<screen delta> app=Safari\n~ e1 val=\"x\"\n</screen>\n\nSummarize it."),
        ]
        try store.recordSession(messages: messages)

        let files = try FileManager.default.contentsOfDirectory(atPath: store.sessionsDirectory.path)
        t.expectEqual(files.count, 1)
        let logContent = try String(
            contentsOf: store.sessionsDirectory.appendingPathComponent(files[0]),
            encoding: .utf8
        )
        t.expect(logContent.contains("user: What is on this page?"), "user line present, got: \(logContent)")
        t.expect(logContent.contains("wisp: A news article about sailing."), "assistant line present")
        t.expect(logContent.contains("user: Summarize it."), "delta-stripped user line present")
        t.expect(!logContent.contains("<screen"), "screen blocks stripped")
    })

    cases.append(TestCase("stable id derivation does not change between parses") {
        let first = MemoryStore.stableID(for: "A hand written fact")
        let second = MemoryStore.stableID(for: "A hand written fact")
        t.expectEqual(first, second)
        t.expect(first != MemoryStore.stableID(for: "A different fact"), "distinct texts, distinct ids")
    })

    // MARK: - MemoryDistiller (with a scripted provider, no network)

    cases.append(TestCase("distiller appends one fact per reply line, ignoring bullets, blanks, and overlong lines") {
        let (store, directory) = makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let provider = ScriptedProvider(
            reply: "- The user is named Alex\n\nThe user ships a macOS app\n" + String(repeating: "x", count: 300)
        )
        let distiller = MemoryDistiller(store: store)
        await distiller.distill(
            messages: [
                ChatMessage(role: .user, text: "I'm Alex, I build a macOS app."),
                ChatMessage(role: .assistant, text: "Nice to meet you, Alex."),
            ],
            using: provider
        )

        let texts = store.allFacts().map(\.text)
        t.expectEqual(texts.sorted(), ["The user is named Alex", "The user ships a macOS app"].sorted())
    })

    cases.append(TestCase("distiller swallows provider errors silently") {
        let (store, directory) = makeTemporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let distiller = MemoryDistiller(store: store)
        await distiller.distill(
            messages: [ChatMessage(role: .user, text: "hello")],
            using: FailingProvider()
        )
        t.expectEqual(store.allFacts().count, 0)
    })

    // MARK: - SecretsStore (env fallback only — no Keychain writes in tests)

    cases.append(TestCase("secrets store returns nil for unknown ref") {
        let secrets = SecretsStore(service: "so.wisp.keys.tests")
        t.expect(secrets.apiKey(for: "WISP_TEST_NONEXISTENT_XYZ") == nil, "unknown ref resolves to nil")
    })

    cases.append(TestCase("secrets store falls back to environment variables") {
        let secrets = SecretsStore(service: "so.wisp.keys.tests")
        // PATH is always present in the test environment.
        t.expect(secrets.apiKey(for: "PATH") != nil, "env fallback works")
    })

    cases.append(TestCase("availableRefs reports only resolvable refs") {
        let secrets = SecretsStore(service: "so.wisp.keys.tests")
        func profile(_ id: String, keyRef: String?) -> LLMModelProfile {
            LLMModelProfile(
                id: id,
                displayName: id,
                apiStyle: .openaiCompatible,
                baseURL: URL(string: "http://localhost")!,
                model: "m",
                apiKeyRef: keyRef
            )
        }
        let profiles = [
            profile("a", keyRef: "PATH"),
            profile("b", keyRef: "WISP_TEST_NONEXISTENT_XYZ"),
            profile("c", keyRef: nil),
        ]
        t.expectEqual(secrets.availableRefs(from: profiles), ["PATH"])
    })

    return cases
}

// MARK: - Test doubles

/// Streams a fixed reply in a few uneven chunks.
private struct ScriptedProvider: LLMProvider {
    let reply: String

    var profile: LLMModelProfile {
        LLMModelProfile(
            id: "scripted",
            displayName: "Scripted",
            apiStyle: .openaiCompatible,
            baseURL: URL(string: "http://localhost")!,
            model: "scripted"
        )
    }

    func streamChat(_ request: LLMChatRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            var remaining = Substring(reply)
            while !remaining.isEmpty {
                let chunk = remaining.prefix(7)
                continuation.yield(.textDelta(String(chunk)))
                remaining = remaining.dropFirst(7)
            }
            continuation.yield(.done(nil))
            continuation.finish()
        }
    }
}

private struct FailingProvider: LLMProvider {
    var profile: LLMModelProfile {
        LLMModelProfile(
            id: "failing",
            displayName: "Failing",
            apiStyle: .openaiCompatible,
            baseURL: URL(string: "http://localhost")!,
            model: "failing"
        )
    }

    func streamChat(_ request: LLMChatRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: LLMProviderError.network("scripted failure"))
        }
    }
}
