# Merge request detail view — redesign spec (R4: readiness strip + changes tab)

Refactor the existing merge request detail view to this layout. This is the
third view in the series after `DESIGN-detail-view.md` (issues) and
`DESIGN-milestone-view.md` (milestones), both already implemented.
**Reuse their components and highlight groups**: header, tab bar, sidebar field,
colour tokens, and the strip pattern from the milestone timeline. Don't build
parallel versions. Keep the data layer (GitLab API calls, caching, pickers) as
it is; this is a presentation refactor plus the small behaviours listed below.

A screenshot of the target design is attached separately (`merge-request-view-R4.png`).
Where the screenshot and this spec disagree, this spec wins. File names and
numbers in the screenshot are example data.

---

## 1. Layout

```
┌───────────────────────────────────────────────────────────────────────────────────────┐
│ atlas / semesterarbeit › merge requests › !36    opened by marius.schaffner · 3h      │ header
│ ● Open  Merge test into master  !36                                                   │
├───────────────────────────────────────────────────────────────────────────────────────┤
│  (✓)━━━━━━━━━━━━━(✓)━━━━━━━━━━━━━━(◷)──────────────────────(⇣)                        │ readiness
│  Pipeline passed   No conflicts    Review · mose.mueller    Merge into master         │ strip
│  gp pipeline                       waiting for approval            gM blocked         │
├──────────────────────────────────────────────────────────────────┬────────────────────┤
│ Description  Activity  Changes 7  Commits  Pipelines  2/7 viewed │ BRANCHES  gB gd    │
│                                                                  │ ⎇ test             │
│    FILE                                  ADD   DEL  CHANGE       │ ↳ ⎇ master         │
│ ✓  .gitlab-ci.yml                        +27   −9   ▰▰▰▰         │                    │
│ ✓  README.md                             +12   −0   ▰            │ ASSIGNEE        ga │
│ ○  ansible/roles/webaccess/tasks/main.yml +112  −0  ▰▰▰▰▰▰▰      │ (MS) marius.sch…   │
│ ○  webhook/app.py                        +71  −29   ▰▰▰▰▰▰       │                    │
│ ───────────────────────────────────────────────────────────      │ REVIEWERS       gr │
│    7 files changed                       +297  −41               │ (MM) mose.m… ◷     │
│                                                                  │ LABELS          gl │
│                                                                  │ WF:Review          │
│                                                                  │ ────────────────── │
│                                                                  │ ON MERGE        gb │
│                                                                  │ ○ Delete src branch│
│                                                                  │ ● Close #22        │
└──────────────────────────────────────────────────────────────────┴────────────────────┘
```

| Region | Content | Sizing |
|---|---|---|
| Header | meta line + state pill, title, `!<iid>` | fixed, 2 lines + padding |
| Readiness strip | merge gates as nodes on a line, labels, hints | fixed, 3 lines, border below |
| Main pane | tab bar + active tab content (scrolls) | all remaining width |
| Sidebar | metadata fields | same fixed width as the other views |

**No statusline.** Key hints live next to what they act on.

### Narrow terminals
Same breakpoint as the other views (~100 columns): hide the sidebar and
collapse the strip to one line, `✓ pipeline · ✓ no conflicts · ◷ review · gM blocked`.

## 2. Removed from the current design
- Bordered boxes around title, assignees, reviewers, labels, branches and merge readiness.
- The `Source Branch (+297, −41)` box: the diff stats live only in the Changes tab.
- The `[gb] - Merge Readiness` box (split into the readiness strip and the ON MERGE field).
- The `[i] - Edit` label in the bottom border.

## 3. Header
1. **Meta line** (dim): `<group> / <project> › merge requests › !<iid>` left;
   `opened by <author> · updated <relative time>` right.
2. **Title line**: state pill, then title (bold, bright), then `!<iid>` dim.
   - `● Open`: green · `● Draft`: dim/grey · `● Merged`: purple · `● Closed`: red

No chip row; everything else is in the strip and the sidebar.

## 4. Readiness strip
Same visual pattern as the milestone timeline strip: full width, three lines.

1. **Nodes and segments.** One node per gate, in this order, followed by a
   final merge node:

   | Gate | Passed | Pending | Failed |
   |---|---|---|---|
   | Pipeline | `✓` Pipeline passed | `◷` Pipeline running | `✗` Pipeline failed |
   | Conflicts | `✓` No conflicts | `◷` Checking… | `✗` Conflicts with `<target>` |
   | Review | `✓` Approved · `<name>` | `◷` Review · `<reviewer(s)>` | `✗` Changes requested · `<name>` |
   | Threads (only if any blocking threads exist) | `✓` Threads resolved | — | `✗` `<n>` unresolved threads |
   | Draft (only if MR is draft) | — | — | `✗` Marked as draft |
   | Merge node | `⇣` green: Ready to merge | `⇣` dim: Merge into `<target>` | — |

   - Node colours: green = passed, yellow = pending (with a 1-cell outline),
     red = failed, dim = merge node while blocked.
   - Segment between two nodes: green if the node on its left passed,
     otherwise the border colour.
   - Gates that don't apply (no pipeline configured, no reviewers) are hidden,
     not shown as passed.
   - Merged MR: all nodes green, merge node purple `● Merged into <target>`.
2. **Labels**: the text from the table, under each node. The first label is
   left-aligned, the last right-aligned, the others centred under their node.
   The current blocking gate's label is yellow/red; the rest normal text.
3. **Hints** (dim, 12px-style): `gp pipeline` under the pipeline node,
   `waiting for approval` / reason text under the blocking node, and under the
   merge node `gM merge` (enabled) or `gM blocked` (disabled).

Prefer GitLab's `detailed_merge_status` field (if the API version provides it)
to decide which gate is blocking, so the strip matches what GitLab itself says.
Put the gate derivation in one pure function.

`gM` when blocked: show a short message naming the blocking gate instead of
calling the API.

## 5. Sidebar fields
Use the shared sidebar field component.

| Field | Key | Value | Empty state |
|---|---|---|---|
| BRANCHES | `gB` source / `gd` target | two lines: `⎇ <source>` (cyan), then dim `↳ ` + `⎇ <target>` (purple) | — |
| ASSIGNEE | `ga` | avatar initials + username; multiple stack | `+ assign` |
| REVIEWERS | `gr` | avatar + username + state right-aligned: `◷ pending` (yellow), `✓ approved` (green), `✗ changes` (red) | `+ add reviewer` |
| LABELS | `gl` | tinted chips | `+ add label` |
| — divider — | | | |
| ON MERGE | `gb` | `○ / ● Delete source branch` (toggle with `gb`), then one `● Close #<n>` line per issue the MR closes (from `Closes #n` in the description) | hide the close lines if none |

No diff stats in the sidebar.

## 6. Main pane

### Tab bar
Shared component: `Description`, `Activity`, `Changes <file count>`,
`Commits`, `Pipelines`. Right-aligned dim info for the active tab
(Changes: `<viewed> of <total> viewed`). `<Tab>` / `<S-Tab>` cycle tabs;
only the main pane changes.

Default tab when opening an MR: **Changes**.

### Changes tab
- Column header row (dim small caps): `FILE · ADD · DEL · CHANGE`.
- One row per file:
  - viewed marker: `✓` green (viewed) / `○` yellow (not viewed)
  - path: directory dim, file name normal; viewed files fully dim;
    truncate the directory part from the left with `…` if too long
  - `+<added>` green, `−<deleted>` red, right-aligned fixed width
  - change bar: 10 cells, scaled to the largest file in the MR; green cells
    for additions, red for deletions, the rest empty
- Cursor row: highlighted background.
- Footer row under a divider: `<n> files changed` dim, total `+` / `−` in bold.
- Keys: `j/k` move, `⏎` open the file's diff (keep the current diff behaviour
  for now; the diff viewer gets its own redesign later), `v` toggle viewed,
  `c` comment on file.
- Viewed state is stored locally per MR and head commit SHA, so it resets
  when new commits arrive (GitLab does the same).

### Description tab
- Render markdown as in the issue view.
- `Closes #<n>` / `Fixes #<n>` lines render as issue cards: state dot,
  `#<n>`, issue title, WF label chip; `⏎` opens the issue detail view.
- Empty description: dim italic `No description.` with `i add one`.

### Activity tab
Reuse the issue view's Activity tab component as-is.

### Commits / Pipelines tabs
Keep the existing content, restyled with the shared tokens (no boxes, dim
metadata, bright titles). `⏎` on a pipeline opens the pipeline view.

## 7. Keymaps
| Key | Action |
|---|---|
| `gt` | edit title |
| `ga` / `gr` / `gl` | assignee / reviewers / labels |
| `gB` / `gd` | source / target branch |
| `gb` | toggle delete source branch on merge |
| `gp` | open the MR's latest pipeline |
| `gM` | merge (or explain what's blocking) |
| `i` | edit description |
| `<Tab>` / `<S-Tab>` | next / previous tab |
| `v` | toggle viewed (Changes tab) |
| `gx` | open in browser |
| `?` | key help |

## 8. Colours
Use the shared highlight groups. New usages only:
- strip passed node/segment → `green`; pending → `yellow`; failed → `red` (`#f7768e`, add as a token if missing)
- source branch → `cyan`, target branch → `purple`
- change bar additions → `green`, deletions → `red`, empty → `border`
- state pill Merged → `purple`, Closed → `red`

## 9. Done when
- [ ] The MR view matches §1 at ≥100 columns and collapses as described below that.
- [ ] Header, tab bar, sidebar fields and colours reuse the shared components (no duplicates).
- [ ] The readiness strip renders every state in §4 correctly (passed, pending, failed, merged, gates hidden when not applicable), and `gM` explains the blocker when blocked.
- [ ] The Changes tab is the default tab; bars scale to the largest file; viewed state persists per MR + head SHA.
- [ ] `Closes #n` renders as issue cards and feeds the ON MERGE field.
- [ ] Existing tests pass; new pure logic (gate derivation, change-bar scaling, `Closes #n` parsing, viewed-state key) has unit tests.
