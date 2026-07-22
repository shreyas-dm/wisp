# Memory

Wisp's continual learning is deliberately boring: **plain Markdown files on
your disk**, readable and editable with any editor. Nothing is embedded,
uploaded, or hidden.

```
~/.wisp/memory/
  facts.md        # one durable fact per line
  sessions/       # transcripts of past conversations (for distillation)
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

## Editing and deleting

- Edit `facts.md` directly — it's yours. Delete a line to forget it.
- `wisp memory list` prints all facts with their ids.
- `wisp memory clear` deletes all facts (asks for confirmation).
- Delete `~/.wisp/memory/` to reset everything.

## Privacy

Memory never leaves your machine except as part of the system prompt sent to
the model endpoint you configured. With a local model, it never leaves at
all. There is no sync, no server, no telemetry.
