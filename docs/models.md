# Model setup

Wisp talks to models through **profiles** in `~/.wisp/config.json`. A profile
names a host (`baseURL`), a wire protocol (`apiStyle`), a model id, and
optionally the name of a key (`apiKeyRef`). Two API styles cover practically
every host:

- `"anthropic"` — the Anthropic Messages API.
- `"openai"` — OpenAI-style chat completions, spoken by nearly every other
  provider and every local server.

Add a key once and it lives in the macOS Keychain (an environment variable
with the same name also works, e.g. for SSH sessions):

```bash
wisp key set ANTHROPIC_API_KEY   # prompts for the key on stdin
wisp key list
```

> Model ids evolve quickly — the ids below are examples that worked at the
> time of writing. Check your host's documentation for current ones.

## Hosts

| Host | `baseURL` | `apiStyle` | Example `model` | Suggested `apiKeyRef` | Vision |
|---|---|---|---|---|---|
| Anthropic | `https://api.anthropic.com` | `anthropic` | `claude-sonnet-5` | `ANTHROPIC_API_KEY` | ✓ |
| OpenAI | `https://api.openai.com/v1` | `openai` | `gpt-5.2` | `OPENAI_API_KEY` | ✓ |
| OpenRouter | `https://openrouter.ai/api/v1` | `openai` | `anthropic/claude-sonnet-5` | `OPENROUTER_API_KEY` | varies |
| Zhipu (GLM) | `https://open.bigmodel.cn/api/paas/v4` | `openai` | `glm-5.2` | `ZHIPU_API_KEY` | model-dependent |
| Moonshot (Kimi) | `https://api.moonshot.ai/v1` | `openai` | `kimi-k3` | `MOONSHOT_API_KEY` | model-dependent |
| Groq | `https://api.groq.com/openai/v1` | `openai` | `llama-4-maverick` | `GROQ_API_KEY` | ✗ |
| DeepSeek | `https://api.deepseek.com/v1` | `openai` | `deepseek-chat` | `DEEPSEEK_API_KEY` | ✗ |
| Ollama (local) | `http://localhost:11434/v1` | `openai` | `qwen3:8b` | — | model-dependent |
| vLLM (local) | `http://localhost:8000/v1` | `openai` | whatever you serve | — | model-dependent |
| LM Studio (local) | `http://localhost:1234/v1` | `openai` | whatever you load | — | model-dependent |

Set `supportsVision` honestly per profile: it gates the `[[screenshot]]`
fallback. Wisp's core experience (snapshots + pointing) needs **no** vision
at all — that's the point.

## Fully local with Ollama

Nothing leaves your machine — speech recognition, speech synthesis, and the
model all run locally.

```bash
brew install ollama          # or download from ollama.com
ollama serve                 # if not already running
ollama pull qwen3:8b         # any instruction-following chat model works
```

The built-in `local` profile already points at `http://localhost:11434/v1`.
Pick **Local (Ollama)** in the menu bar — no key needed. Small models follow
the pointing protocol surprisingly well because it's just text; if replies
ramble, try a larger model or set `"temperature": 0.3`.

## Notes and quirks

- **Streaming** is used everywhere (SSE). All hosts above support it on
  their OpenAI-compatible endpoints.
- **OpenRouter** routes to many underlying models; vision and quality depend
  on the routed model, and ids use `vendor/model` form.
- **Zhipu/Moonshot** ids and base URLs occasionally shift between API
  versions; if you get 404s, re-check the host's current docs.
- **Local servers** need no `apiKeyRef`; leave it out entirely.
- `maxOutputTokens` defaults to 1024 — replies are deliberately short and
  spoken aloud; raise it if you ask for long-form answers.

## Voice engines

Voice is independent of the chat model. Wisp prefers state-of-the-art voice
APIs and falls back to the local Apple engines so it always has a voice:

| Engine | STT | TTS | Key ref | Notes |
|---|---|---|---|---|
| ElevenLabs | Scribe (`scribe_v1`) | `eleven_flash_v2_5` | `ELEVENLABS_API_KEY` | Preferred automatically when the key resolves (`"auto"`) |
| Apple (local) | Speech framework | AVSpeech | — | Zero-key fallback, fully offline |

```bash
wisp key set ELEVENLABS_API_KEY
```

Set `"sttEngine"` / `"ttsEngine"` to `"elevenlabs"` or `"apple"` in
`~/.wisp/config.json` to pin an engine instead of `"auto"`; pick a voice
with `"elevenLabsVoiceID"`. The engine layer is a small protocol — new voice
vendors are easy to add and A/B.
