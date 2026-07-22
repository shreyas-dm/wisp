# Wisp

[![CI](https://github.com/shreyas-dm/wisp/actions/workflows/ci.yml/badge.svg)](https://github.com/shreyas-dm/wisp/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Wisp is a native macOS companion that lives next to your cursor: hold **⌃⌥**,
ask a question out loud, and it answers in a small bubble and a calm voice —
having actually looked at your screen — and can fly a pointer to the exact
button, field, or link it's talking about.

It is built from scratch around three convictions: a screen assistant should
understand **structure, not just pixels**; it should work with **any model
you choose**, including open-source ones; and a companion that forgets you
after every conversation isn't much of a companion.

## Why Wisp is different

### 1. It understands structure, not just pixels

Most screen assistants ship only a screenshot to a vision model on every
question and hope it can read your screen back out of the pixels. Wisp reads
the macOS Accessibility tree and builds a **Semantic Screen Snapshot** — the
frontmost app, window, and visible elements, each with a short ID, role,
label, value, and position:

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

Exact labels, values, and focus (`*`) — information a screenshot can only
approximate. By default (`hybrid` mode) each turn sends **both** the snapshot
and a downscaled screenshot, so a vision model gets precise structure *and*
full visual context — belt and suspenders. And because the expensive part is
optional, you dial cost with one setting:

| Screen context per turn | Typical tokens |
|---|---|
| Raw retina screenshot (what most tools send) | 1,500–5,000+ |
| `hybrid` — snapshot + downscaled screenshot (default) | 1,200–2,400 |
| `structure` — snapshot only | 300–1,200 (budget-capped) |
| Follow-up snapshot (delta) | 30–150 |

Follow-up snapshots only send what changed (`+` added / `~` changed / `-`
removed), and history compaction drops old screenshots, so multi-turn
conversations stay flat. Text-only models degrade automatically to
`structure` mode — and still get the pointing superpower below.

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
it's how Wisp sees your screen), **Screen Recording** (for the screenshot
half of hybrid context), and **Microphone + Speech Recognition** (for
voice).

Wisp boots with zero API keys: voice falls back to the local Apple engines
and a built-in **Demo** profile exercises the full experience — bubble,
voice, pointing — with canned replies. Add real keys when ready (stored in
the macOS Keychain, never in a file):

```bash
make release
./.build/release/wisp key set ANTHROPIC_API_KEY    # your model
./.build/release/wisp key set ELEVENLABS_API_KEY   # state-of-the-art voice
```

With an ElevenLabs key present, speech-to-text (Scribe) and text-to-speech
upgrade automatically; the voice engine layer is pluggable, so other voice
APIs can slot in as they're added.

Then pick a profile from the menu bar icon. Optionally put the CLI on your
PATH: `ln -s "$PWD/.build/release/wisp" /usr/local/bin/wisp`.

## Using Wisp

Hold **⌃⌥** and speak. A waveform confirms Wisp is listening; release, and
the reply streams into the bubble while your configured voice reads it
(ElevenLabs when a key is set, the local system voice otherwise). When the
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
  ✓ screen recording granted (hybrid context sends a screenshot each turn)
  ✓ api key          ANTHROPIC_API_KEY present (Keychain)
  ✓ endpoint         https://api.anthropic.com reachable
  ✓ voice            stt: ElevenLabs (auto) · tts: ElevenLabs (auto)
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

Beyond profiles, the interesting knobs (all optional, shown with defaults):

```json
{
  "screenContextMode": "hybrid",      // hybrid | structure | auto | screenshot
  "screenshotMaxDimension": 1024,     // longest side of the attached screenshot
  "snapshotTokenBudget": 1200,
  "sttEngine": "auto",                // auto | elevenlabs | apple
  "ttsEngine": "auto",
  "elevenLabsVoiceID": "21m00Tcm4TlvDq8ikWAM"
}
```

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
