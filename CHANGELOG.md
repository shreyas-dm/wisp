# Changelog

## v0.3.0 — 2026-07-23

It teaches, it remembers, it proves itself.

- **Guided walkthroughs**: how-do-I questions come back as 2–6 step tags;
  Wisp walks you through them one at a time — pointer on each step,
  auto-advancing when the screen shows the step happened (navigation, a
  value change, focus arriving), with manual Next as fallback. In the CLI,
  steps render as a numbered list.
- **Recall**: a `[[recall:…]]` tag lets the model search Wisp's local
  memory — facts, session transcripts, and the activity log — and
  re-answer with what it found. Also exposed as `wisp memory search`.
- **Activity log** (optional, on by default, local-only): which app and
  window had focus and for how long, one Markdown file per day; feeds
  recall and distillation. `"activityLogEnabled": false` turns it off.
- **`wisp eval`**: a built-in benchmark over fixture screens measuring
  pointing accuracy, comprehension, invented element IDs, and latency for
  any profile — the "works with open models" claim, made measurable.
- **Turn metrics**: per-stage latency breakdown (capture, STT, first
  token, stream, TTS) via `wisp ask --timing`, logged locally to
  `~/.wisp/metrics.jsonl`.
- **Whisper-compatible STT**: any `/audio/transcriptions` server
  (whisper.cpp, Groq, LM Studio, OpenAI) via `"sttEngine": "whisper"`.
- **Custom instructions**: standing preferences injected into every
  conversation — `wisp instructions set "…"`.

## v0.2.0 — 2026-07-23

Deeper context, faster feel.

- Snapshots now carry the user's **selected text**, the **browser URL**,
  and an **also-open window list**, captured best-effort under strict time
  budgets and dropped first under token pressure.
- **Local OCR fallback** (Apple Vision, fully on-device): when the
  accessibility tree is sparse — canvases, video, games — screen text
  becomes pointable `t`-prefixed elements, so even text-only models can
  read and point at content accessibility cannot describe.
- Provider connections **pre-warm while you speak** (throttled to once a
  minute), so the first token lands sooner. Both wire protocols are now
  covered by chunk-level streaming tests through the real URL loading
  pipeline.
- App polish: **Esc cancels system-wide**, the orb is **draggable** and
  remembers its position, **launch at login**, **⌃⌥Space** opens a
  floating text input, a **Memory & History window** lists remembered
  facts (with delete) and past conversations, and **New conversation**
  resets context.

## v0.1 — 2026-07-23

First working version, built from scratch.

- Semantic Screen Snapshots from the Accessibility tree with budget-driven
  serialization and delta updates; hybrid mode attaches a downscaled
  screenshot every turn.
- Provider layer: Anthropic Messages + OpenAI-compatible streaming (Ollama,
  vLLM, OpenRouter, Groq, Zhipu GLM, Moonshot Kimi, DeepSeek…), plain-text
  tag protocol ([[point:eID]], [[screenshot]], [[remember:…]]) so text-only
  open models get the full experience, including pointing.
- Voice: ElevenLabs STT (Scribe) and TTS preferred automatically when the
  key resolves; local Apple Speech/AVSpeech fallback keeps everything
  working with zero keys.
- Memory: [[remember:]] facts plus idle-time distillation into
  user-editable Markdown at ~/.wisp/memory, with a token-budgeted profile
  injected each conversation.
- Native app: menu-bar panel, glowing orb with state animations, streaming
  reply bubble, bezier pointer with element highlight ring, push-to-talk
  (hold ⌃⌥), onboarding, promptless `wisp doctor`.
- CLI: snapshot/ask/doctor/key/memory; Keychain-backed key storage.
- 73-test dependency-free harness; CI on GitHub Actions.
