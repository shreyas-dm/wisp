# Wisp

A native macOS AI companion that lives next to your cursor — it sees your
screen, listens, talks back, and points at things. Built from scratch to be
radically token-efficient and to work with **any** model, including
open-source ones (GLM, Kimi, Qwen, Llama via Ollama/vLLM/OpenRouter…).

Instead of shipping screenshots to a vision model, Wisp reads the macOS
Accessibility tree and sends a compact **Semantic Screen Snapshot** — exact
labels, values, and positions at ~10–20× fewer tokens — and lets the model
point at elements by ID, so even text-only models can guide you around your
screen.

See [DESIGN.md](DESIGN.md) for the full design. Work in progress.
