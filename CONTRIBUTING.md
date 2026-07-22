# Contributing

## Building

```bash
make build     # debug build
make test      # run the test suite
make app       # release build + dist/Wisp.app (ad-hoc signed)
make run       # debug build + launch
```

Requires macOS 14+ and a Swift 6 toolchain. Full Xcode is **not** needed —
Command Line Tools are enough. `scripts/dev-env.sh` (sourced automatically
by `make`) detects and works around some broken CLT installations; on a
healthy toolchain it's a no-op.

## Tests

The runner is dependency-free (no XCTest — some supported toolchains don't
ship it). Suites live in `Tests/WispTests`, one file per area:

```swift
func myAreaTests(_ t: TestRunner) -> [TestCase] {
    [
        TestCase("does the thing") {
            t.expectEqual(actual, expected)
        },
    ]
}
```

Register new suites in `Tests/WispTests/main.swift`. Anything in `WispKit`
that is pure logic (serialization, diffing, parsing, budgeting) should have
tests; UI and permission-gated code is exercised manually.

## Style

- Clarity over cleverness. Descriptive names, even when long.
- Comments explain *why*, not *what* — especially around AppKit bridging
  and TCC/permission behavior.
- SwiftUI for UI unless AppKit is genuinely required (panels, event taps);
  keep AppKit bridging isolated.
- `WispKit` stays UI-free and testable.

## Pull requests

- Branch from `main`: `feature/…` or `fix/…`.
- Imperative commit subjects; explain the why in the body when it isn't
  obvious.
- CI (build + tests) must pass.
