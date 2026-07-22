import Foundation

// Register every suite here. Suites live one per file as
// `func <name>Tests(_ t: TestRunner) -> [TestCase]`.
let runner = TestRunner()

await runner.run(suite: "smoke", smokeTests(runner))
await runner.run(suite: "screen-context", screenContextTests(runner))
await runner.run(suite: "providers", providerTests(runner))
await runner.run(suite: "tag-parser", tagParserTests(runner))
await runner.run(suite: "voice-memory", voiceMemoryTests(runner))
await runner.run(suite: "voice-api-config", voiceApiConfigTests(runner))

runner.finish()
