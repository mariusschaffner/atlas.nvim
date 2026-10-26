# Milestone detail view — redesign spec (M4: document + sidebar + timeline)

Refactor the existing milestone detail view to this layout. This is the
companion to `DESIGN-detail-view.md` (issue detail view), which is already
implemented. **Reuse the components and highlight groups built for the issue
view**: header, tab bar, sidebar field, colour tokens. Don't create parallel
versions of them. Keep the data layer (GitLab API calls, caching, editors and
pickers) as it is; this is a presentation refactor plus the small behaviours
listed below.

A screenshot of the target design is attached separately (`milestone-view-M4.png`).
Where the screenshot and this spec disagree, this spec wins. Issue titles in
the screenshot are placeholders.

---

## 1. Layout

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│ atlas / semesterarbeit › milestones › %630        group milestone · updated 1d  │ header
│ ● Active  Entwicklung & Deployment  %630                                        │
├─────────────────────────────────────────────────────────────────────────────────┤
│ │20.10.        │27.10.        │03.11.        │10.11.              16.11.│       │ timeline
│ ━━━━━━┃──────────────────────────────────────────────────────────────────       │ strip
│     today                                                     gs gd dates       │
├──────────────────────────────────────────────────────────┬──────────────────────┤
│ Description   Work items 12   Merge requests 0  ⇥ switch │ PROGRESS             │
│ ───────────                                              │ ▰▰▱▱▱▱▱▱▱▱▱▱         │
│ Meilenstein                                              │ 0/12 closed          │
│ ┌──────────────────────────────────────────────┐         │                      │
│ │ ◎ Vertec Webaccess 2.0 funktioniert und …    │         │ WORK ITEMS           │
│ └──────────────────────────────────────────────┘         │ ○ To do          10  │
│                                                          │ ◐ Doing           2  │
│ Beschreibung                                             │ ✓ Done            0  │
│ Dieser Sprint dient der technischen Umsetzung …          │ unassigned        3  │
│                                                          │                      │
│ Mit Abschluss dieses Sprints ist …                       │ MERGE REQUESTS       │
│                                                          │ none linked yet      │
│                                                          │ ──────────────────── │
│                                                          │ IN PROGRESS          │
│                                                          │ #17 sprint-2 pl… 4/6 │
│                                                          │ #18 Ansible rol… 1/3 │
└──────────────────────────────────────────────────────────┴──────────────────────┘
```

| Region | Content | Sizing |
|---|---|---|
| Header | meta line + state pill, title, `%<iid>` | fixed, 2 lines + padding, full width |
| Timeline strip | date ticks, progress bar, today marker, key hint | fixed, 3 lines, full width, border below |
| Main pane | tab bar + active tab content (scrolls) | all remaining width |
| Sidebar | metadata fields | same fixed width as the issue view sidebar |

**No statusline in this view.** Key hints live next to the things they act
on (timeline strip, sidebar labels, tab bar).

### Narrow terminals
Same breakpoint as the issue view (~100 columns): hide the sidebar and show
one meta strip under the timeline:
`0/12 closed · 2 doing · 3 unassigned · 0 MRs`

## 2. Removed from the current design
- Bordered boxes around title, start date, due date and progress.
- The `[ ███ ] 0% (0/12)` progress box (replaced by the sidebar PROGRESS field).
- Separate Start date / Due date boxes (replaced by the timeline strip).
- The `[i] - Edit` label in the bottom border.
- Raw markdown markers (`**Zeitplan**:` etc.) in the description.

## 3. Header
1. **Meta line** (dim): `<group> / <project> › milestones › %<iid>` left;
   `<group|project> milestone · updated <relative time>` right.
2. **Title line**: state pill, then title (bold, bright), then `%<iid>` dim.
   - `● Active`: green, tinted background
   - `● Upcoming`: blue (start date in the future)
   - `● Closed`: purple
   - `● Overdue`: red (past due and not closed)

No chip row: progress lives in the sidebar, dates in the timeline strip.

## 4. Timeline strip
Full width under the header. Three lines:

1. **Date ticks**: a dim `│` plus `DD.MM.` at the start date and at every
   Monday after it. The due date goes right-aligned at the end of the strip,
   followed by a closing `│`. **No calendar week numbers.** If two labels
   would overlap, drop the earlier label (the tick stays).
2. **Bar**: one line, the full strip width.
   - `cols_per_day = width / (due - start + 1)`
   - filled from start to today: cyan (`━`)
   - rest: border colour (`─`)
   - today: bright `┃` at today's column
3. **Labels**: `today` centred under the marker (bright). Right-aligned:
   `gs gd dates` (keys yellow, text dim).
   **No pace or "expected by today" hint.**

Edge cases:
| State | Bar | Label line |
|---|---|---|
| before start | empty | `starts in N days` instead of `today` |
| after due, open | fully filled, **red** | `N days overdue` instead of `today` |
| closed | fully filled, dim | `closed DD.MM.` |
| no start or due date | hide lines 1–2 | `+ set dates  gs gd` (dim) |
| only due date | treat start as creation date | — |

`gs` / `gd` open the existing date pickers. The strip redraws immediately after a change.

## 5. Sidebar fields
Use the sidebar field component from the issue view (label in dim small caps,
optional key hint right-aligned, value below).

| Field | Key | Value |
|---|---|---|
| PROGRESS | — | segmented bar, one segment per issue (cap at 20 segments and scale above that): **green** = closed, **purple** = doing, **dim** = to do. Below it: `<closed>/<total> closed` |
| WORK ITEMS | — | rows `○ To do` (blue), `◐ Doing` (purple), `✓ Done` (green) with right-aligned counts; then `unassigned` (dim label, count orange if > 0, row hidden if 0) |
| MERGE REQUESTS | — | `!<iid> <title>` per linked MR (max 3, then `+N more`); empty: `none linked yet` (dim) |
| — divider — | | |
| IN PROGRESS | — | issues in the doing state: `#<iid>` dim, title truncated with `…`, checklist `n/m` right (yellow when partly done). Hide the field if none |

"Doing" / "To do" / "Done" map to the existing WF labels (`WF:Doing`, etc.);
closed issues count as Done regardless of label. Put the mapping in one place.

## 6. Main pane

### Tab bar
Same component as the issue view: `Description`, `Work items <count>`,
`Merge requests <count>`, right-aligned dim hint `⇥ switch tab`.
`<Tab>` / `<S-Tab>` cycle tabs. Only the main pane changes; header, strip and
sidebar stay put.

### Description tab (rendered markdown)
- `**Heading**:` / `**Heading**` lines on their own line render as section
  headings (bold accent, no asterisks, no trailing colon).
- **Goal block**: a section named `Meilenstein` (or `Milestone` / `Goal`)
  is rendered first, as a highlighted block: subtle background, yellow `◎`,
  bright text.
- A `Zeitplan` section that only repeats the start/due dates is **hidden**,
  because the timeline strip shows them. Any other content stays.
- Remaining sections render in their original order; paragraphs wrap at
  ~80 columns.
- `i` edits the raw markdown, as in the issue view.

### Work items / Merge requests tabs
Keep the existing content for now, restyled with the shared tokens (no
boxes, dim metadata, bright titles). `⏎` on an issue opens its detail view.

## 7. Keymaps
| Key | Action |
|---|---|
| `gt` | edit title |
| `gs` / `gd` | start / due date |
| `i` | edit description |
| `<Tab>` / `<S-Tab>` | next / previous tab |
| `⏎` | open issue/MR under cursor (list tabs) |
| `gx` | open milestone in browser |
| `?` | key help |

## 8. Colours
Use the highlight groups from `DESIGN-detail-view.md` §8. New usages only:
- timeline fill → `cyan`
- today marker + label → `fg_bright`
- PROGRESS segments → `green` / `purple` / `progress_empty`
- goal block background → `#1f2335` (add as token `bg_highlight` if missing)

## 9. Done when
- [ ] The milestone view matches §1 at ≥100 columns and collapses to the meta strip below that.
- [ ] Header, tab bar, sidebar fields and colours reuse the issue view components (no duplicates).
- [ ] The timeline strip handles every edge case in §4 and redraws after `gs`/`gd`.
- [ ] PROGRESS and WORK ITEMS counts agree with the Work items tab.
- [ ] Existing tests pass; new pure logic (timeline column maths, WF-label mapping, markdown section parsing) has unit tests.
