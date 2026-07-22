import Foundation

/// Minimal dependency-free test harness (this toolchain ships neither
/// XCTest nor the swift-testing runtime). Each suite file contributes a
/// `[TestCase]`; `main.swift` runs them all and exits non-zero on failure.
struct TestCase {
    let name: String
    let body: () async throws -> Void

    init(_ name: String, _ body: @escaping () async throws -> Void) {
        self.name = name
        self.body = body
    }
}

final class TestRunner {
    private(set) var failureCount = 0
    private(set) var testCount = 0
    private var currentTestFailed = false
    private var currentTestName = ""

    func expect(
        _ condition: Bool,
        _ message: String,
        file: String = #fileID,
        line: Int = #line
    ) {
        if !condition {
            currentTestFailed = true
            print("    FAIL \(file):\(line) — \(message)")
        }
    }

    func expectEqual<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ message: String = "",
        file: String = #fileID,
        line: Int = #line
    ) {
        if actual != expected {
            currentTestFailed = true
            let detail = message.isEmpty ? "" : " — \(message)"
            print("    FAIL \(file):\(line)\(detail)")
            print("      expected: \(expected)")
            print("      actual:   \(actual)")
        }
    }

    func run(suite: String, _ cases: [TestCase]) async {
        print("suite \(suite)")
        for testCase in cases {
            testCount += 1
            currentTestFailed = false
            currentTestName = testCase.name
            do {
                try await testCase.body()
            } catch {
                currentTestFailed = true
                print("    THREW \(error)")
            }
            if currentTestFailed {
                failureCount += 1
                print("  ✗ \(testCase.name)")
            } else {
                print("  ✓ \(testCase.name)")
            }
        }
    }

    func finish() -> Never {
        if failureCount == 0 {
            print("\nOK — \(testCount) tests passed")
            exit(0)
        } else {
            print("\nFAILED — \(failureCount)/\(testCount) tests failed")
            exit(1)
        }
    }
}
