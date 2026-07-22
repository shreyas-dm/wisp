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

Options:

- `--voice` — also speak the reply with the local TTS.
- `--profile ID` — use a specific model profile for this question.

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

Or just edit `~/.wisp/memory/facts.md` by hand — see
[docs/memory.md](memory.md).

## `wisp version`

Prints the version.
