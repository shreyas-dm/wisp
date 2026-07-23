# Memory

Wisp's continual learning is deliberately boring: **plain Markdown files on
your disk**, readable and editable with any editor. Nothing is embedded,
uploaded, or hidden.

```
~/.wisp/memory/
  facts.md        # one durable fact per line
  sessions/       # transcripts of past conversations (for distillation)
  activity/       # local app-usage log, one file per day (optional)
```

## How facts get written

1. **Inline, during conversation** — when the model learns something durable
   ("I'm a designer", "my project targets iOS 17") it emits a
   `[[remember:…]]` tag. Wisp strips the tag from the visible reply and
   appends the fact.
2. **Distillation, after a session** — when a conversation ends, Wisp asks
   the model to extract any remaining durable facts from the transcript and
   folds them in, deduplicating against what's already known. Skipped
   silently when no model is reachable.

## File format

One fact per line in `facts.md`, with provenance in a trailing HTML comment
(invisible when the Markdown is rendered):

```markdown
- Prefers keyboard-driven workflows; asks for shortcuts first  <!-- id:b3f2c1d0 src:model at:2026-07-23T10:00:00Z -->
- Working on a Swift package called "aurora" with strict concurrency  <!-- id:91ac4e77 src:distilled at:2026-07-24T09:12:00Z -->
```

`src` is `model` (inline tag), `distilled` (post-session), or `user`. Lines
you add by hand — a plain `- fact` with no comment — are picked up as facts
too, and duplicates are ignored case-insensitively.

## How memory is used

Before each conversation, Wisp builds a digest of your facts — newest first,
deduplicated, trimmed to a token budget (default **500**, configurable as
`memoryTokenBudget` in `~/.wisp/config.json`) — and injects it into the
system prompt. More facts never means unbounded prompt growth.

## Recall — memory the model can search

The digest keeps prompts small, which means most of what Wisp knows is
*not* in the prompt. When you refer to something the model can't see —
*"that error from yesterday"*, *"the site I showed you"* — it replies with
a single `[[recall:search terms]]` tag. Wisp then searches facts, session
transcripts, and the activity log locally (token-frequency scoring with a
recency boost — no embeddings, no network), injects the best few hits, and
re-sends your question once. At most one recall per question; if nothing
relevant exists, Wisp says so instead of guessing.

The same search is available directly: `wisp memory search "query"`.

## The activity log

With `"activityLogEnabled": true` (the default), Wisp keeps a local log of
which app and window had your focus and for how long — one Markdown file
per day in `~/.wisp/memory/activity/`:

```markdown
- 14:03–14:21 Xcode — "wisp — CompanionEngine.swift" (18m)
- 14:21–14:24 Safari — "Swift Forums" (3m)
```

Spans shorter than 15 seconds are dropped as noise. The log feeds recall
("what was I doing yesterday afternoon?") and gives distillation a sense of
what you actually work on. It is written and read only on your Mac: lines
are only ever sent to a model as recall hits for a question *you* asked.
Set `"activityLogEnabled": false` to turn it off, or delete the folder at
any time.

## Custom instructions

Standing preferences live in config as `customInstructions` and are
injected into every system prompt — set them with
`wisp instructions set "…"` or from the menu bar panel. Good for things
that are policy, not fact: "answer in Hindi", "assume I use Vim", "never
suggest paid tools".

## Editing and deleting

- Edit `facts.md` directly — it's yours. Delete a line to forget it.
- `wisp memory list` prints all facts with their ids.
- `wisp memory clear` deletes all facts (asks for confirmation).
- Delete `~/.wisp/memory/` to reset everything.

## Privacy

Memory — facts, session transcripts, and the activity log — never leaves
your machine except as part of a prompt sent to the model endpoint you
configured, and activity lines only travel as recall results for questions
you asked. With a local model, nothing leaves at all. There is no sync, no
server, no telemetry.
