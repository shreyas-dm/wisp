# Evaluating models

Wisp's central claim — *any model can drive it, including open-source
ones* — should be measured, not asserted. `wisp eval` is a built-in
benchmark that runs the same interaction protocol the app uses against any
configured profile and reports how well the model actually drives it.

```bash
wisp eval                    # active profile
wisp eval --profile glm      # any profile from ~/.wisp/config.json
```

## What the suite covers

The built-in suite is ~10 fixture tasks over synthetic Semantic Screen
Snapshots — a browser form, a mail inbox, a settings pane, a code editor,
and an OCR-style screen (t-prefixed elements, the way canvas/video content
appears after local recognition). No screen capture or permissions are
involved; fixtures ship with Wisp, so results are comparable across
machines and models.

Each task sends one turn (system prompt + serialized fixture + question)
and scores the reply on:

- **Pointing** — did the model point (`[[point:…]]`) at an acceptable
  element for the task? Tasks accept one or more IDs; any match counts.
- **Comprehension** — does the reply contain enough of the task's expected
  keywords (case-insensitive)?
- **Invented IDs** — element IDs referenced that don't exist in the
  fixture. The most important honesty signal: a model that invents IDs
  will point at nothing on a real screen.
- **Latency** and **output tokens** — how the model feels in use.

## Reading the table

```
$ wisp eval --profile kimi
Running 10 tasks against Kimi (Moonshot)…

  task              point  comprehend  latency
  browser-form      ✓      ✓           1.2s
  ocr-video         ✗      ✓           1.6s
  …

  pointing 8/9 · comprehension 6/6 · invented IDs 0 · mean latency 1.3s
```

- `pointing 8/9` — of the 9 tasks with a point target, 8 pointed at an
  acceptable element.
- `invented IDs 0` — no hallucinated elements anywhere in the run. Treat
  anything above 0 seriously.
- A `–` cell means the task doesn't score that dimension.

## Caveats

This is a smoke benchmark, not a leaderboard. Ten synthetic tasks measure
whether a model follows Wisp's protocol reliably — they say little about
general capability, and a fixture suite this small is easy to overfit in
your head. Use it to answer practical questions: *is this cheap model good
enough to point reliably? did switching profiles break anything? is the
latency livable?* For real judgment, use the model for a day with
`wisp ask --timing` and look at `~/.wisp/metrics.jsonl`.
