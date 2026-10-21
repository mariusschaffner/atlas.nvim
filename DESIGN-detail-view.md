# Issue detail view — redesign spec

Refactor the existing issue detail view to this layout. Keep the data layer as it is;
this is a presentation refactor plus a few small behaviours listed below.

A screenshot of the target design is attached separately (`ui_design.png`).
Where the screenshot and this spec disagree, this screenshot wins.

---

## 1. Layout

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│ atlas / semesterarbeit › issues › #17          opened by M. Schaffner · 2h ago  │  header
│ ● Open  feat(docs): add sprint-2 planning  #17                                  │
│ WF:Doing   ◆ Entwicklung & Deployment  │  ▰▰▰▰▱▱ 4/6 criteria                   │
├──────────────────────────────────────────────────────────┬──────────────────────┤
│ Description   Activity 12   Merge requests 0  ⇥ switch   │ ASSIGNEE          ga │
│ ───────────                                              │ (MS) Marius Schaffner│
│ #SCS                                                     │                      │
│                                                          │ LABELS            gl │
│ As the main developer,                                   │ WF:Doing             │
│ I want to have a proper sprint planning,                 │                      │
│ so that the backlog is ready …                           │ MILESTONE         gm │
│                                                          │ ◆ Entwicklung & De…  │
│ Acceptance criteria                        4 of 6 done   │                      │
│ ✓ Milestone is defined          x toggle · e edit  ◀──   │ START → DUE    gs gd │
│ ✓ Sprint start & end is planned                          │ not scheduled        │
│ ○ Sprint planning is documented in the main README       │ ──────────────────── │
│ …                                                        │ DEVELOPMENT    gb gp │
│                                                          │ + link branch        │
│ Implementation                                           │ + link merge request │
│ • Create a milestone object in GitLab                    │                      │
│   – start / end date, description                        │                      │
│                                                          │ Opened by M. Schaff… │
├──────────────────────────────────────────────────────────┴──────────────────────┤
│ NORMAL  #17 › description        i edit  c comment  x toggle  gx browser  ? keys│ statusline
└─────────────────────────────────────────────────────────────────────────────────┘
```

Three regions plus a statusline:

| Region | Content | Sizing |
|---|---|---|
| Header | breadcrumb + meta line, state pill + title + `#iid`, chip row | fixed height (3 lines + padding), full width |
| Main pane | tab bar + the active tab's content (scrolls) | takes all remaining width |
| Sidebar | metadata fields | fixed 32–36 columns, does not resize with the main pane |
| Statusline | mode, location, context key hints | 1 line, full width |

### Narrow terminals
Below ~100 columns, hide the sidebar and show its values as a single
meta strip under the title instead:
`● Open · Marius Schaffner · WF:Doing · ◆ Milestone · due — · no branch`

## 2. Removed from the current design
- The bordered box around every field, and the full-width box around the title.
- Key hints inside box titles (`[gl] - Labels`, `[gm|gM] - Milestone`).
- The separate Author box (author moves to the header meta line and a footer line in the sidebar).
- "None" as a value. Empty fields use the empty state in §4.
- The `[i] - Edit` label in the bottom border (moves to the statusline).

## 3. Header
1. **Meta line** (dim): `<group> / <project> › issues › #<iid>` on the left; `opened by <author> · updated <relative time>` on the right.
2. **Title line**: state pill (`● Open` green / `● Closed` purple, tinted background), title in bold, bright text, `#<iid>` dim after it.
3. **Chip row**: label chips (tinted background in the label's colour), milestone as `◆ <name>` in cyan, a dim `│` separator, then the **checklist progress**: 6-segment bar + `n/m criteria`.
   - Progress = count of `- [x]` vs all `- [ ]`/`- [x]` task items in the description.
   - Recompute whenever the description changes (including toggling with `x`), so the header updates immediately.
   - Hide the progress block if the description has no task items.

## 4. Sidebar fields
Each field is the same component — implement it once and reuse it:

```
LABEL (dim, small caps, letter-spaced)        keyhint (yellow, right-aligned)
value line(s)
```

| Field | Key(s) | Value rendering | Empty state |
|---|---|---|---|
| Assignee | `ga` | avatar initials in a circle + name; multiple assignees stack | `+ assign` |
| Labels | `gl` | tinted chips, wrapping | `+ add label` |
| Milestone | `gm` / `gM` | `◆ <name>` in cyan, truncated with `…` | `+ set milestone` |
| Start → Due | `gs` `gd` | `<start> → <due>`; due date turns orange when ≤ 2 days, red when overdue | `not scheduled` (dim italic) |
| — divider — | | | |
| Development | `gb` `gp` | linked branch names / `!<mr-iid> <title>` | `+ link branch`, `+ link merge request` |
| footer | | `Opened by <author>` (dim, pinned to bottom) | |

Pressing a field's key on an **empty** field opens its picker directly.

## 5. Main pane

### Tab bar
`Description`, `Activity <count>`, `Merge requests <count>`. Active tab: bright,
bold, 2px-style underline in the accent colour. Inactive: dim label, count in
normal text. `<Tab>` / `<S-Tab>` cycle tabs. Switching tabs only swaps the main
pane's content — header and sidebar stay unchanged.

### Description tab (rendered markdown)
- Headings (`#`, `##`) render as bold accent-coloured text, without the `#`.
- Hashtags like `#SCS` render in orange.
- User-story lines starting with **As / I want / so that** get the keyword in bold accent.
- Task items:
  - done: green `✓`, text slightly dimmed
  - open: yellow `○`, text bright
  - the section heading line shows `n of m done` right-aligned, dim
- Nested list items keep their indent (`•` top level, `–` second level).
- Cursor line: subtle highlighted background; on a task item, show dim
  italic virtual text at the right end: `x toggle · e edit`.
- `i` enters edit mode on the raw markdown; leaving edit mode re-renders.

### Activity tab
Reverse-chronological list: relative time (dim, fixed width) + event text,
with referenced labels/milestones/items coloured as in the header. A comment
input line at the bottom (`› write a comment…  c`).

## 6. Statusline
`NORMAL` mode block (accent background, dark text) · `#<iid> › <active tab>` ·
right-aligned context hints. Hints change with context:
- on a task item: `x toggle  e edit`
- default: `i edit  c comment  x toggle  gx browser  ? keys`

Key letters yellow, descriptions dim.

## 7. Keymaps (unchanged unless noted)
| Key | Action |
|---|---|
| `gt` | edit title |
| `ga` | assignee picker |
| `gl` | labels picker |
| `gm` / `gM` | milestone picker / (existing gM behaviour) |
| `gs` / `gd` | start / due date |
| `gb` / `gp` | link branch / link MR |
| `i` | edit description |
| `x` | toggle task item under cursor (**new**) |
| `c` | comment (**new**, Activity input) |
| `gx` | open issue in browser (**new**) |
| `<Tab>` / `<S-Tab>` | next / previous tab (**new**) |
| `?` | key help (**new**) |

## 8. Colours
Define these as named highlight groups / theme tokens (don't hard-code hex in
the view code), so they can follow the user's colour scheme later.

| Token | Hex | Use |
|---|---|---|
| `bg` | `#1a1b26` | background |
| `bg_dark` | `#16161e` | statusline |
| `cursorline` | `#283050` | cursor line |
| `border` | `#2f3549` | dividers, sidebar border |
| `fg` | `#c0caf5` | body text |
| `fg_bright` | `#e6eaff` | title, open task items, active tab |
| `fg_done` | `#a9b1d6` | done task items |
| `dim` | `#7f87ad` | labels, meta, hints (keeps ≥4.5:1 contrast on `bg`) |
| `accent` | `#7aa2f7` | headings, active tab underline, mode block |
| `green` | `#9ece6a` | open state, ✓, progress fill |
| `yellow` | `#e0af68` | key hints, ○ open task |
| `orange` | `#ff9e64` | hashtags, due-soon |
| `purple` | `#bb9af7` | label chips, closed state |
| `cyan` | `#7dcfff` | milestone |
| `progress_empty` | `#3b4261` | empty progress segments |

## 9. Done when
- [ ] Detail view matches the layout in §1 at ≥100 columns, and collapses to the meta strip below that.
- [ ] No bordered field boxes and no "None" values remain.
- [ ] Header progress updates immediately after toggling a task with `x`.
- [ ] All existing keymaps still work; new ones from §7 are added.
- [ ] Sidebar field is a single reusable component.
- [ ] Colours come from named highlight groups / tokens.
