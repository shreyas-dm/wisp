# Wisp — Design

Wisp is a native macOS companion that lives next to your cursor, sees your
screen, listens, talks back, and points at things. This document records the
design decisions and the reasoning behind them.

## Why build this

Screen-aware voice assistants today share three structural problems:

1. **They ship pixels.** Sending a retina screenshot with every question costs
   thousands of image tokens, most of which encode chrome, wallpaper, and
   whitespace. It is slow, expensive, and caps how much history you can keep.
2. **They require frontier vision models.** Pointing at UI by pixel coordinate
   only works when the model has strong vision grounding. That locks out
   open-source models entirely.
3. **They know nothing about you.** Every session starts cold.

Wisp is designed from scratch around fixing all three.

## Pillar 1 — Structure over pixels

Wisp's primary screen context is a **Semantic Screen Snapshot**: a compact
text serialization of the macOS Accessibility tree of the frontmost app.

```
<screen> app=Safari window="Invoice – Stripe" display=1/2 1512x982
* e18 field "Amount" val="420.00" (612,388 220x28)
  e19 btn "Send invoice" (612,440 120x32)
  e3 link "Payments" (24,120)
  ...
</screen>
```

- Exact labels, values, roles, focus state, and frames — richer than pixels
  for almost all real UI, at **~10–20× fewer tokens** than a screenshot.
- Every element carries a short ID. The model points with `[[point:e19]]`;
  Wisp resolves the ID to the element's frame and animates the pointer. No
  vision grounding needed — **text-only open models can point reliably.**
- Follow-up turns send **deltas** (`+`/`~`/`-` lines against the previous
  snapshot), so multi-turn conversations stay cheap.
- The serializer is budget-driven (default ~1200 tokens): focused element
  first, then interactive elements, then informative text, dropping
  decoration first.
- Screenshots still exist as an explicit fallback: for canvas/video/game
  content the model replies `[[screenshot]]` and Wisp re-sends the request
  with a downscaled JPEG — but only when the active profile supports vision.

## Pillar 2 — Any model

A thin provider layer speaks two wire protocols:

- **Anthropic Messages** (Claude), with SSE streaming.
- **OpenAI-compatible Chat Completions** — one implementation covers OpenAI,
  Ollama, vLLM, LM Studio, OpenRouter, Groq, Zhipu (GLM), Moonshot (Kimi),
  and DeepSeek.

The interaction protocol (pointing, screenshot requests, memory writes) is
**plain-text tags, not native tool calls**, so it degrades gracefully on any
model that can follow instructions. Model profiles live in
`~/.wisp/config.json`; switching models is one click in the menu bar.

## Pillar 3 — Memory

Wisp maintains a local, user-editable memory at `~/.wisp/memory/`:

- The model tags durable facts inline (`[[remember:...]]`); Wisp appends them
  to the store with provenance.
- A distilled profile (token-budgeted, default 500) is injected into every
  system prompt, so Wisp gets more useful the more you use it.
- Plain Markdown on disk. Nothing leaves the machine except inside prompts to
  the model endpoint the user configured.

## Pillar 4 — Native polish

- Menu bar app (no dock icon), SwiftUI + AppKit bridging.
- A floating orb companion with distinct idle / listening / thinking /
  speaking states; a response bubble that streams text as it arrives; a
  pointer that flies along a curved path and rings the target element.
- Push-to-talk (hold ⌃⌥) via a listen-only CGEvent tap.
- **Zero-key boot**: Apple Speech STT and AVSpeechSynthesizer TTS are local,
  and a demo provider exercises the full pipeline before any API key exists.
- `wisp doctor` diagnoses permissions, config, and endpoint reachability.
- Keys live in the macOS Keychain (`wisp key set <REF>`), never in config
  files.

## Token-efficiency techniques (summary)

| Technique | Effect |
|---|---|
| AX-tree snapshot instead of screenshot | ~10–20× cheaper, more precise |
| Delta snapshots on follow-ups | repeat turns cost ~10% of first turn |
| Budget-driven serializer with priority ordering | hard cap per turn |
| Element-ID pointing | no vision tokens, works on text-only models |
| History compaction (old snapshots dropped, turns summarized) | long sessions stay flat |
| Screenshot only on explicit model request | images are the exception |

## Package layout

```
Sources/WispKit        — testable core (no UI)
  Chat/                — messages, prompt building, system prompt
  Providers/           — Anthropic + OpenAI-compatible + mock, SSE parsing
  ScreenContext/       — AX capture, serializer, diff, screenshot fallback
  Memory/              — store + distillation
  Voice/               — STT (Apple Speech), TTS (AVSpeech)
  Config/              — config store, secrets (Keychain)
Sources/Wisp           — the app: engine, menu bar, overlay, hotkey, CLI
Tests/WispKitTests     — unit tests for all pure logic
```
