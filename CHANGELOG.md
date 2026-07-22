# Changelog

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
