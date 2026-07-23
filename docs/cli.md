# CLI reference

The `wisp` binary is both the app and its command line. Run with no
arguments to launch the menu-bar app; subcommands run headless, which makes
every part of Wisp scriptable and debuggable — including over SSH.

Build it with `make release`; the binary lands at `.build/release/wisp`.
Optionally: `ln -s "$PWD/.build/release/wisp" /usr/local/bin/wisp`.

## `wisp`

Launches the menu-bar app (orb, hotkey, bubble). First run opens onboarding
for permissions.

## `wisp snapshot`

Captures and prints the Semantic Screen Snapshot of the frontmost app — the
exact text a model would receive — plus a token estimate. Great for checking
what Wisp can see in a given app.

```
$ wisp snapshot
<screen> app=Mail window="Inbox – 3 unread" display=1/1 1512x982
  e2 btn "New Message" (12,52 32x28)
  e5 field "Search" (300,52 240x28)
* e9 row "Ada Lovelace — Analytical Engine notes" (0,120 640x44)
  e10 row "Bank — Statement ready" (0,164 640x44)
  e14 text val="Hi — attached are the notes from…" (660,120 820x700)
</screen>
≈ 118 tokens
```

Options:

- `--budget N` — serializer token budget (default from config, 1200).
- `--json` — raw snapshot as JSON (ids, roles, frames) for tooling.

Requires Accessibility trust; `wisp doctor` tells you if it's missing.

## `wisp ask "question"`

One-shot question with screen context, streamed to stdout. Pointing tags are
rendered as annotations instead of animations:

```
$ wisp ask "which button submits this form?"
The filled blue button at the bottom right, labeled "Send invoice".
→ points at e21 "Send invoice"
```

Ask a how-do-I question and the reply arrives as a walkthrough — the same
steps the app walks you through with the pointer render as a numbered list:

```
$ wisp ask "how do I turn on dark mode here?"
Appearance lives in the View menu.
  1. e12: Open the View menu
  2. e31: Choose Appearance
  3. e44: Select Dark
```

Options:

- `--voice` — also speak the reply with the configured TTS.
- `--profile ID` — use a specific model profile for this question.
- `--timing` — append a per-stage latency breakdown after the reply:

```
$ wisp ask --timing "what's this dialog asking?"
It wants permission to open the link in Slack — Open proceeds, Cancel stays.
→ points at e7 "Open"
capture 48ms · stt 610ms · first-token 890ms · stream 2100ms · tts 130ms
```

Timing lines are also appended to `~/.wisp/metrics.jsonl` (local only), so
you can compare models and settings over time.

## `wisp doctor`

Checks everything and says what to fix:

```
$ wisp doctor
Wisp doctor
  ✓ accessibility        trusted — screen snapshots available
  ✓ screen recording     granted — hybrid screen context available
  ✓ microphone           authorized
  ✓ speech recognition   authorized
  ✓ config               ~/.wisp/config.json
  ✓ model profile        Claude Sonnet (claude-sonnet-5, anthropic)
  ✓ api key              ANTHROPIC_API_KEY resolves
  ✓ endpoint             https://api.anthropic.com reachable
  ✓ voice engines        stt: ElevenLabs (auto) · tts: ElevenLabs (auto)
  ✓ tts voice            Samantha
```

Exit code is non-zero when a required check fails, so it can gate scripts.

## `wisp key`

Manage API keys in the macOS Keychain (service `so.wisp.keys`). Environment
variables with the same name work as a fallback resolution path.

```
$ wisp key set ANTHROPIC_API_KEY     # prompts on stdin, input hidden
$ wisp key list
  ANTHROPIC_API_KEY   (keychain)
  ZHIPU_API_KEY       (env)
$ wisp key delete ZHIPU_API_KEY
```

Keys are never written to config files or logs.

## `wisp memory`

```
$ wisp memory list
  b3f2c1d0  Prefers keyboard-driven workflows  (model, 2026-07-23)
  91ac4e77  Building a Swift package called "aurora"  (distilled, 2026-07-24)
$ wisp memory clear     # asks for confirmation
```

`wisp memory search` runs the same local search the `[[recall:…]]` tag uses
— facts, session transcripts, and the activity log, scored with a recency
boost:

```
$ wisp memory search "certificate error"
  [session · 2026-07-22] on 2026-07-22: user: the build failed with a
      certificate error / wisp: that signing certificate expired — renew…
  [activity · 2026-07-22] on 2026-07-22: 16:10–16:40 Xcode — "wisp — signing" (30m)
```

Or just edit `~/.wisp/memory/facts.md` by hand — see
[docs/memory.md](memory.md).

## `wisp eval`

Runs the built-in model-evaluation suite (fixture screens, ~10 tasks)
against a profile and scores pointing accuracy, comprehension, invented
element IDs, and latency. See [docs/eval.md](eval.md).

```
$ wisp eval --profile kimi
Running 10 tasks against Kimi (Moonshot)…

  task              point  comprehend  latency
  browser-form      ✓      ✓           1.2s
  mail-triage       ✓      ✓           0.9s
  settings-toggle   ✓      –           1.1s
  ocr-video         ✗      ✓           1.6s
  …

  pointing 8/9 · comprehension 6/6 · invented IDs 0 · mean latency 1.3s
```

Defaults to the active profile; needs that profile's API key (or a local
server). The Demo profile works for a dry run of the harness itself.

## `wisp instructions`

Standing preferences injected into every conversation (stored as
`customInstructions` in config):

```
$ wisp instructions set "Answer in short sentences. Assume I use Vim."
$ wisp instructions           # prints the current instructions
$ wisp instructions clear
```

## `wisp version`

Prints the version.
