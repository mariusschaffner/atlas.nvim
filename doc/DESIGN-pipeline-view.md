# Pipeline detail view

The pipeline detail view ui needs to be refactored. It is the fourth view
in the series after the issue, milestone and merge request views
(`doc/DESIGN-detail-view.md`, `doc/DESIGN-milestone-view.md`,
`doc/DESIGN-merge-request-view.md`). **Reuse their shared components and highlight
groups**: header, state pill, key-hint style, colour tokens. Don't build
parallel versions.

A screenshot of the target design is attached separately (`doc/ui_design_pipelines.png`).
Where screenshot and spec disagree, this screenshot wins. Stage/job names, runner
names and log lines in the screenshot are example data.

---

## 1. Layout

```
┌───────────────────────────────────────────────────v───────────────────────────────┐
│ atlas / semesterarbeit › pipelines › #<id>   ⎇ test · <sha> · !36 · user · 3m ago │ header
│ ◐ Running  Merge test into master  #<id>        3:05 elapsed · 4/7 jobs  R  X     │
├───────────────────────────────────────────────────────────────────────────────────┤
│  Validate ✓ 53s        Build ✓ 1:02          Test ◐ running      Deploy manual    │
│ (✓ yamllint   12s)─┬─(✓ build-agent  1:02)─┬─(✓ webhook-pytest)─┬─(▶ deploy-stag) │ graph
│ (✓ ansible-li 41s)─┘                       └─(◐ molecule  2:14)─┴─(⏸ deploy-prod) │
│ h/l stage  j/k job  ⏎ show output  r retry job  p play manual  X cancel job       │
├───────────────────────────────────────────────────────────────────────────────────┤
│ ◐ molecule-default                       ● following   F follow / search za fold  │ log header
│   1 ▸ prepare executor · 3s                                                       │
│  14 ▸ get sources · 2s                                                            │ log
│  22 ▾ step_script                                                                 │ (fills the
│  23 $ molecule test                                                               │  rest)
│  …                                                                                │
│  39 … ▌                                                                           │
└───────────────────────────────────────────────────────────────────────────────────┘
```

| Region | Content | Sizing |
|---|---|---|
| Header | meta line, title line with pill, elapsed/jobs and pipeline keys | fixed, 2 lines + padding |
| Graph | one column per stage, job pills, connectors, key hints | height = tallest stage + header + hint line |
| Log header | selected job, follow badge, log keys | 1 line |
| Log | output of the selected job | fills the remaining height |

No sidebar, no statusline, no footer under the log.

Entry points: `⏎` on a pipeline in the MR's Pipelines tab, and `gp` in the MR
view's readiness strip. Both open this view for that pipeline.

## 2. Header
1. **Meta line** (dim): `<group> / <project> › pipelines › #<id>` left. Right:
   `⎇ <ref>` (cyan) · short SHA · `!<mr iid>` (accent; only if the pipeline
   belongs to an MR) · triggering user · relative start time.
2. **Title line**: state pill, title (bold, bright), `#<id>` dim. Title = MR
   title if the pipeline belongs to an MR, else the commit title.
   Right-aligned: `<elapsed>` (in the state colour) ` elapsed · <done>/<total> jobs`,
   then key hints `R retry failed`, `X cancel`.

State pill:
| Status | Pill |
|---|---|
| running | `◐ Running` cyan |
| pending / created | `◷ Pending` yellow |
| success | `✓ Passed` green |
| failed | `✗ Failed` red |
| canceled | `⊘ Canceled` dim |
| manual (blocked on manual job) | `▶ Manual` yellow |

`elapsed` ticks every second while running; after completion show the final
duration instead (`5:41 total`).

## 3. Pipeline graph
- One **column per stage**, in pipeline order, fixed column width (~30 cells).
- **Stage header**: stage name, status icon, duration (or `running` / `manual`).
  Name colour: normal when done, state colour when running/manual.
- **Job pill**: rounded box (`╭ ╮ ╰ ╯`) containing status icon, job name
  (truncated with `…`), right-aligned duration.
  - success `✓` green · running `◐` cyan · pending `◷` yellow · failed `✗` red ·
    canceled `⊘` dim · skipped `»` dim
  - manual: dashed border, yellow `▶`, right text `p play`
  - blocked manual (waits for another manual job): dashed dim border, `⏸`, `blocked`
  - allowed-to-fail failure: `!` yellow instead of `✗`
- **Selected job**: thick border (`┏ ┓ ┗ ┛`) in cyan, subtle background,
  bold bright name.
- **Connectors** between neighbouring stage columns, drawn with box-drawing
  characters: a horizontal stub out of every job in stage N, a vertical spine
  in the gap, and a stub into every job of stage N+1. Neutral border colour.
  If jobs use `needs:`, still draw stage-to-stage connectors (no DAG edges).
- **Hint line** under the graph (dim, keys yellow): `h/l stage · j/k job ·
  ⏎ show output · r retry job · p play manual · X cancel job`.

Navigation: `h/l` moves to the previous/next stage (keeps the closest row),
`j/k` moves within a stage. Moving the selection switches the log below
immediately (no extra `⏎` needed); `⏎` moves focus into the log.

Overflow: if the stages don't fit the window width, the graph scrolls
horizontally to keep the selected job visible, with dim `‹ n more` / `n more ›`
markers at the edges.

## 4. Log
- **Log header**: status icon + job name (bold), right-aligned
  `● following` badge (cyan tint, only while following), then hints
  `F follow · / search · za fold · gz fullscreen`.
- **Body** (slightly darker background), line numbers dim and right-aligned:
  - GitLab section markers (`section_start:…` / `section_end:…`) become
    foldable section lines `▸ <name> · <duration>` / `▾ <name>` in accent
    colour; finished sections are folded by default, the running one open.
  - ANSI colours from the job output are rendered; lines containing
    `WARNING` get a yellow tint, `ERROR` / failing lines a red tint.
  - While the job runs: new lines append at the bottom, cursor block on the
    last line.
- **Follow mode**: on by default for running jobs; scrolling up turns it off,
  `F` turns it back on and jumps to the end.
- `/` searches within the log, `n`/`N` next/previous match.
- `gz` toggles fullscreen log (graph hidden), same key to return.
- Finished jobs open scrolled to the end; failed jobs open at the first error line.

## 5. Actions
| Key | Scope | Action |
|---|---|---|
| `R` | pipeline | retry failed jobs |
| `X` | pipeline (in graph header context) / job (selected) | cancel |
| `r` | job | retry selected job |
| `p` | job | play selected manual job |
| `⏎` | job | focus the log |
| `h/l`, `j/k` | graph | move selection |
| `F`, `/`, `za`, `gz` | log | follow, search, fold, fullscreen |
| `q` / back | view | return to where it was opened from |

Destructive actions (`X` cancel pipeline) ask a one-line y/n confirmation.

## 6. Data and refresh
- Pipeline + jobs: poll every 3–5 s while the pipeline is running/pending,
  stop polling when it finishes.
- Job log: fetch the trace of the selected job; while it runs, fetch
  incrementally (only append new content) every 1–2 s.
- Keep this logic out of the view: a small pipeline-state module that the
  view subscribes to. Put stage/column layout, connector drawing, section
  parsing and status mapping in pure functions with unit tests.

## 7. Colours
Use the shared highlight groups. Usages:
- running → `cyan`; success → `green`; manual/pending/warning → `yellow`;
  failed/error → `red`; canceled/skipped/blocked → `dim`
- connectors → `border`; key letters → `yellow`
- log background → `bg_dark`; section lines → `accent`

## 8. Done when
- [ ] The view matches §1 and opens from both entry points.
- [ ] Header, pill and key hints reuse the shared components.
- [ ] Every status in §2–§3 renders correctly (test with a running, a passed,
      a failed and a manual-blocked pipeline).
- [ ] Graph connectors are correct for stages with 1, 2 and 3+ jobs; wide
      pipelines scroll horizontally.
- [ ] Selecting a job switches the log immediately; follow mode, search,
      folding and fullscreen work; running logs append without flicker.
- [ ] Polling stops when the pipeline finishes.
- [ ] Unit tests cover layout/connector maths, section parsing and status mapping;
      existing tests still pass.
