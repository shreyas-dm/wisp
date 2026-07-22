# Wisp

[![CI](https://github.com/shreyas-dm/wisp/actions/workflows/ci.yml/badge.svg)](https://github.com/shreyas-dm/wisp/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Wisp is a native macOS companion that lives next to your cursor: hold **⌃⌥**,
ask a question out loud, and it answers in a small bubble and a calm voice —
having actually looked at your screen — and can fly a pointer to the exact
button, field, or link it's talking about.

It is built from scratch around three convictions: screen context should be
**structured text, not pixels**; a screen assistant should work with **any
model you choose**, including open-source ones; and a companion that forgets
you after every conversation isn't much of a companion.

## Why Wisp is different

### 1. It sends structure, not screenshots

Most screen assistants ship a full screenshot to a vision model on every
question. Almost all of those image tokens encode window chrome, wallpaper,
and whitespace. Wisp instead reads the macOS Accessibility tree and sends a
**Semantic Screen Snapshot** — the frontmost app, window, and visible
elements, each with a short ID, role, label, value, and position:

```
<screen> app=Safari window="Invoice – Stripe" display=1/2 1512x982
  e3 link "Payments" (24,120 96x24)
  e7 link "Customers" (24,152 96x24)
* e18 field "Amount" val="420.00" (612,388 220x28)
  e19 popup "Currency" val="USD" (844,388 80x28)
  e20 field "Memo" (612,430 312x28)
  e21 btn "Send invoice" (612,480 120x32)
  e22 btn "Save draft" (744,480 100x32)
</screen>
```

Exact labels, values, and focus (`*`) — richer than pixels for real UI, at a
fraction of the cost:

| Screen context per turn | Typical tokens |
|---|---|
| Retina screenshot (vision model) | 1,500–5,000+ |
| Semantic Screen Snapshot | 300–1,200 (budget-capped) |
| Follow-up snapshot (delta) | 30–150 |

Follow-ups only send what changed (`+` added / `~` changed / `-` removed), so
multi-turn conversations stay flat. Screenshots still exist — as an explicit
fallback the model can request for canvases, video, and games, and only when
your chosen model supports vision.

### 2. It works with any model — including open-source

Because elements carry IDs, the model points by writing `[[point:e21]]` in
plain text — no pixel-coordinate grounding, no vision requirement — so a
text-only open model can guide you around your screen as reliably as a
frontier one. The whole interaction protocol (pointing, screenshot requests,
memory writes) is plain text.

Wisp speaks two wire protocols: the Anthropic Messages API and OpenAI-style
chat completions, which covers OpenAI, Ollama, vLLM, LM Studio, OpenRouter,
Groq, Zhipu (GLM), Moonshot (Kimi), DeepSeek, and most everything else.
Switching models is one click in the menu bar. See
[docs/models.md](docs/models.md).

### 3. It remembers you

When Wisp learns something durable — your name, your stack, the project
you're wrestling with — it records a fact in `~/.wisp/memory/`, plain
Markdown you can read, edit, or delete. A token-budgeted digest is injected
into every conversation, so Wisp gets more useful the more you use it.
Everything stays on your machine. See [docs/memory.md](docs/memory.md).

## Quick start

Requires macOS 14+ and a Swift 6 toolchain (Command Line Tools are enough —
no Xcode needed).

```bash
git clone https://github.com/shreyas-dm/wisp.git
cd wisp
make app          # builds dist/Wisp.app
open dist/Wisp.app
```

First launch walks you through permissions: **Accessibility** (required —
it's how Wisp sees your screen), **Microphone + Speech Recognition** (for
voice), and optionally **Screen Recording** (only used for the vision
fallback).

Wisp boots with zero API keys: speech-to-text and text-to-speech are local
(Apple Speech), and a built-in **Demo** profile exercises the full
experience — bubble, voice, pointing — with canned replies. When you're
ready, add a real key (stored in the macOS Keychain, never in a file):

```bash
make release
./.build/release/wisp key set ANTHROPIC_API_KEY
```

Then pick a profile from the menu bar icon. Optionally put the CLI on your
PATH: `ln -s "$PWD/.build/release/wisp" /usr/local/bin/wisp`.

## Using Wisp

Hold **⌃⌥** and speak. A waveform confirms Wisp is listening; release, and
the reply streams into the bubble while a local voice reads it. When the
answer involves something on screen — *"click Send invoice in the form"* —
a pointer glides to the element and rings it.

Everything also works from the terminal:

```
$ wisp snapshot
<screen> app=Terminal window="~ — zsh" display=1/1 1512x982
* e2 text val="make test\nOK — 41 tests passed" (12,40 1488x900)
</screen>
≈ 62 tokens

$ wisp ask "what's the biggest number in this spreadsheet?"
Looking at the Total column, the largest value is 12,480 in row 14
→ points at e31 "N14"

$ wisp doctor
  ✓ config           ~/.wisp/config.json (6 profiles, active: claude)
  ✓ accessibility    trusted
  ✓ microphone       granted
  ✓ speech           granted
  ○ screen recording not granted (optional — only the vision fallback needs it)
  ✓ api key          ANTHROPIC_API_KEY present (Keychain)
  ✓ endpoint         https://api.anthropic.com reachable
  ✓ tts              voice: Samantha (Enhanced)
```

The full command reference is in [docs/cli.md](docs/cli.md).

## Configuration

Profiles live in `~/.wisp/config.json`. A profile is a host + model + key
reference; Wisp ships with ready-to-fill profiles for the common hosts:

```json
{
  "activeProfileID": "glm",
  "profiles": [
    {
      "id": "glm",
      "displayName": "GLM (Zhipu)",
      "apiStyle": "openai",
      "baseURL": "https://open.bigmodel.cn/api/paas/v4",
      "model": "glm-5.2",
      "apiKeyRef": "ZHIPU_API_KEY",
      "supportsVision": false,
      "maxOutputTokens": 1024
    },
    {
      "id": "kimi",
      "displayName": "Kimi (Moonshot)",
      "apiStyle": "openai",
      "baseURL": "https://api.moonshot.ai/v1",
      "model": "kimi-k3",
      "apiKeyRef": "MOONSHOT_API_KEY"
    },
    {
      "id": "local",
      "displayName": "Local (Ollama)",
      "apiStyle": "openai",
      "baseURL": "http://localhost:11434/v1",
      "model": "qwen3:8b"
    }
  ]
}
```

A local Ollama profile needs no key at all — Wisp end to end with nothing
leaving your machine. Host-by-host details: [docs/models.md](docs/models.md).

## Privacy

Wisp has no backend, no analytics, and no telemetry. Screen snapshots,
transcripts, and memory exist only on your Mac — the single exception is the
prompt sent to the model endpoint *you* configured. Use a local model and
nothing leaves the machine at all.

## Status

Early and moving fast. The core design is settled (snapshots, tag protocol,
provider layer, memory); polish and hardening are ongoing. Issues and PRs
welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
