# Changelog

## Unreleased (v0.2)

In progress: selected-text / browser-URL / open-windows context, local OCR
fallback for non-accessible content, provider connection warmup, global Esc
cancel, draggable orb, launch at login, floating text input, memory viewer
and session history window.

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
