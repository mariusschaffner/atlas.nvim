# Plan: issue Activity tab redesign (timeline + inline composers)

## Context

The four mockups in `doc/activity_ui_*.png` define the new look of the issue detail **Activity** tab.

Today the tab draws every comment as a bordered box (`bordered_box`, 80% width), joined by `│` connector lines. Activity rows read `HH:MM - DD.MM.YY - Name - label`. A 3-line orange box acts as the composer. Navigation uses `active_id` with j/k.

The target is a flat, day-grouped timeline:
- a compact row per system event
- comment headers with an avatar and badges
- tree-guided replies
- inline composers with a left accent bar, a mode badge and key hints
- a "write a new comment…" bar pinned to the bottom of the window

You want the parts built as reusable components so the milestone view and the codediff inline review can use them later. This change touches the issue side only. Pulls and diff keep their current code until a later change moves them over.

### Decisions you made
- The new-comment bar is a docked float pinned to the bottom of the content window, shown on the **Activity tab only**. `c` focuses it and expands it upward into the big composer.
- Avatars are **colored initials only**: ` MS ` with a background color per person (`dynamic_for_bg`).
- Comment bodies wrap at about **80% of the width**. The comment under the cursor gets a dim, right-aligned hint on the cursor line (`gc reply · gE edit · gD delete · gr react · gX resolve`), in the same style as the Description tab's `x toggle` hint.
- **No `C-p` preview and no `⏎ diff`**: they are removed from the design. The description-change row is a plain event row.
- `C-e` "full buffer" turns the **whole Activity tab into one large edit box**, the same way description editing works (`ui/inline_edit.lua`).
- **j/k move line by line as usual.** Reply, edit, delete, react, resolve and fold all act on the comment under the cursor.
- New keymap config entries are approved:

  | Config entry | Default |
  |---|---|
  | `ui.comments.submit_resolve` | `<C-r>` |
  | `ui.comments.full_buffer` | `<C-e>` |
  | `ui.comments.toggle_resolved` | `gX` |
  | `issues.expand_activity` | `<CR>` |

### What the mockups pin down
- **Day divider.** A dim label followed by a `─` rule to the right edge: `08.10.2026`, `YESTERDAY · 21.10.2026`, `TODAY · …`.
- **Event row.** A colored icon, then the actor in bold, the verb dim, and objects in bright or link color. The local time `HH:MM` is right-aligned.
  - Examples: `@ assigned to @x`, `⇄ moved from group/proj#1235`, `✎ changed the description`, `☑ checked <item>`, `@ assigned @a, unassigned @b`.
- **Collapsed run.** `··· 5 more changes · ⏎ expand`.
- **Comment.**
  - Header: `[MS] Author  [you]  ◷ unresolved thread …… 07:43`.
  - The body is indented under the author name.
  - While editing, the header chip becomes `✎ editing`.
- **Reply.**
  - The tree guide is `┆` for a middle reply and `└` for the last one.
  - Header: `[MM] Author …… 09:10`, with the body indented under it.
- **Inline composer** (reply and edit). A left accent bar `▎` on a darker background.
  - Optional title row: `↩ Reply to thread`.
  - Text rows: real text, or a dim italic placeholder.
  - Footer row: `INSERT`, then key hints (`C-s post`, `C-r post & resolve`, `Esc cancel`, `C-e full buffer`), then `● unsaved` on the right when the text has changed.
  - For a reply composer, the tree guide and the current user's avatar are drawn in orange.
- **Docked composer.**
  - Collapsed: `[MS] › write a new comment…  …… c focus` inside a rounded border.
  - Expanded, top to bottom:
    1. a `─── · NOW · ───` divider row
    2. a box with a header (`[MS] [Comment]` on the left, `Esc cancel` on the right)
    3. a text area with the placeholder `write a comment · markdown, @ to mention, # to link an issue`
    4. a separator
    5. a footer (`INSERT  C-s post  C-e open in full buffer`)

---

## Reusable components (new, domain-agnostic)

All of these are pure renderers: they take data and return `lines, spans, line_map, regions`. That shape works both in a buffer (`utils.apply_spans`) and as virt_lines (`ui/components/virtual_lines.lua`), which is how codediff could use them later.

New files go under `lua/atlas/ui/components/timeline/` and `lua/atlas/ui/components/composer/`.

1. **`ui/components/avatar.lua`** (extend). Add `M.chip(name) -> text, spans`, which returns ` MS ` highlighted with `highlights.dynamic_for_bg(name)`. Reuse the existing `M.initials`.

2. **`ui/components/keyhints.lua`** (new).
   - `M.format_key("<C-s>") -> "C-s"`.
   - `M.render(segments, opts) -> text, spans`. Each segment is `{action_id, label}`, rendered as the key in `AtlasKeyHint` followed by the label in dim text. Separators are `" "` or `" · "`.
   - Keys always come from `core/keymaps.resolve`; nothing is hardcoded. Segments with disabled keys are skipped.
   - Used by the composer footers, the docked bar's `c focus` and the cursor-line hint.

3. **`ui/components/mode_badge.lua`** (new). `M.render(mode) -> text, spans` gives ` INSERT ` or ` NORMAL `, with background-filled highlight groups.

4. **`ui/components/timeline/day_divider.lua`** (new).
   - `M.render(label, width) -> lines, spans`: the label plus a rule to the edge.
   - `M.render_centered(label, width)`: produces `── · NOW · ──` for the docked composer.

5. **`ui/components/timeline/event_row.lua`** (new). `M.render(event, width, opts)`.
   - `event = { icon, icon_hl, segments = {{text, hl}...}, time, action_hint? }`.
   - Produces one line, with segments truncated so the right-aligned time always fits. Wrapping onto a second line is not needed.
   - The `···` gap row (`5 more changes · ⏎ expand`) is the same component, using a keyhint segment.

6. **`ui/components/timeline/comment.lua`** (new). `M.render(node, width, opts) -> lines, spans, line_map, regions`.
   - The node holds the display model:

     ```
     { id, author, author_key, is_you, time, body_lines (raw markdown),
       reactions_text/spans, badges, children, collapsed, truncated }
     ```

   - Options: `depth`, `guide` (`"mid"`, `"last"`, `"composer"`), `body_width_ratio = 0.8`, `editing` (the header chip switches to `✎ editing` and the body is replaced by a composer frame), `composer` (a reply composer rendered after the last child).
   - Draws:
     - the header row: avatar chip, author in bold `person_hl`, the `you` badge, status chips, and the time on the right
     - the wrapped body, using `utils.wrap_line` and mention spans moved over from the current renderer's `mention_spans`
     - an optional reactions line (`emojis.format`) and an optional `... (za to expand)` line
     - each child recursively, with the tree guide in the gutter
   - Records `regions["comment:<id>"]` (the body interior) and `regions.composer`, just as `state.regions` does today. Every row maps in `line_map` to `{comment, root, entity_kind="comment", row_kind="header"|"body"}`.

7. **`ui/components/composer/frame.lua`** (new).
   - `M.render(opts) -> lines, spans, text_region`.
   - Options: `width`, `indent`, `title?` (with icon), `text_lines`, `height`, `placeholder`, `mode`, `hints` (keyhint segments), `dirty`, `bar=true|false`, `border=false|"rounded"`, `header_left?/header_right?` (for the docked variant).
   - Draws the accent bar plus background rows (`line_hl_group`-style spans), the title, the text area and the footer (mode badge, hints, `● unsaved`).
   - The same frame serves reply, edit and the docked composer. The docked variant sets `bar=false, border="rounded"` and the header and separator options.

8. **`ui/components/composer/session.lua`** (new). This is the controller that turns a frame plus `inline_field_edit` into a working composer.
   - Opens the overlay on `text_region` and passes `submit_keys`, `close_keys` and the extra keys `submit_resolve` and `full_buffer`.
   - **Grows automatically.** On `TextChanged`/`TextChangedI`, it computes the wrapped line count. When that changes, it calls `on_resize(height)`; the host re-renders, and the overlay is resized and moved.
   - **Shows the current mode.** On `ModeChanged` in the overlay buffer, it calls `on_mode(mode)`, which redraws only the footer's mode badge through an extmark, not a full re-render.
   - **Tracks unsaved changes.** It compares the text with `seed_text` and sets `dirty`.
   - **Shows the placeholder** as overlay virt_text in the overlay buffer while it is empty.
   - **Completes @mentions.** It adapts the sync `AtlasMarkdownCompletionProvider` (`providers/gitlab/completion/author.lua`) to the async `AtlasFieldCompletionProvider` that `inline_field_edit` expects, so `@` completes in inline composers too.
   - **Keeps the draft** for `C-e`. `get_text()` lets the host hand the draft to the full-buffer editor.

9. **`ui/inline_field_edit.lua`** (small, additive changes).
   - `M.resize({height, row})` for the active overlay.
   - `extra_keys = { [keys] = fn }`.
   - `on_change(text)` and `on_mode(mode)` hooks.
   - `winhighlight` that uses the composer background.
   - An opt-out of the border recolor (`recolor_border=false`), because frame-based composers have no box border.
   - Existing callers do not change.

10. **`ui/detail.lua`**: add a generic dock API.
    - `M.set_content_dock(spec|nil)`, where `spec = {buf, height, focusable}`. It opens a float `relative="win"` to the content window, pinned to the bottom rows, at a higher zindex.
    - It re-syncs in the same places as `sync_content_float` (resize, header resize, sidebar collapse).
    - `M.content_dock_win()` returns the dock window.
    - The host adds `height` padding lines at the end of the buffer so the last timeline item can scroll clear of the dock.

11. **`ui/components/composer/dock.lua`** (new). The docked new-comment composer, reusable by any host that has the `ui/detail` dock.
    - Collapsed: a 3-row rounded box drawn with `frame.lua` (`border="rounded"`, one row: avatar, `› write a new comment…`, `c focus`).
    - Expanded: the NOW divider plus the full frame. A `session.lua` overlay sits on the text area.
    - API: `M.attach({host_win, avatar_name, placeholder, hints, on_submit, on_full_buffer})`, `M.focus()`, `M.collapse()`, `M.detach()`.
    - Its augroup is `"AtlasComposerDock" .. win`. Its request scope is cancelled on detach.

12. **Highlights** (`ui/shared/highlights.lua`, new groups only, no renames):
    - Timeline: `AtlasTimelineDay`, `AtlasTimelineRule`, `AtlasTimelineTime`, `AtlasTimelineVerb`, `AtlasTimelineObject`, `AtlasTimelineRef`, `AtlasTimelineGuide`
    - Event icons: `AtlasTimelineIconAssign`, `AtlasTimelineIconMove`, `AtlasTimelineIconEdit`, `AtlasTimelineIconTask`, `AtlasTimelineIconLabel`, `AtlasTimelineIconState`, `AtlasTimelineIconDefault`
    - Badges: `AtlasBadgeYou`, `AtlasBadgeUnresolved`, `AtlasBadgeEditing`
    - Composer: `AtlasComposerBg`, `AtlasComposerBar`, `AtlasComposerTitle`, `AtlasComposerPlaceholder`, `AtlasComposerDirty`
    - Mode badges and hints: `AtlasModeInsert`, `AtlasModeNormal`, `AtlasKeyHintLabel`

13. **Time helpers** (`ui/shared/utils.lua`, next to the existing date helpers).
    - `local_time(iso) -> "HH:MM"`: converts UTC to local with `utc_epoch` and `os.date("*t")`. The current helpers print raw UTC hours.
    - `local_day_key(iso)` returns the local `YYYY-MM-DD`.
    - `day_label(iso, now)` returns `TODAY · dd.mm.yyyy`, `YESTERDAY · dd.mm.yyyy` or `dd.mm.yyyy`.

## Issue-side wiring

### Data (GitLab), `issues/providers/gitlab/api/notes.lua` + `mapper.lua` + `issues/types.lua`
- **Query.** Extend `GQL_DISCUSSIONS`:
  - add `resolvable resolved resolvedBy { username name }` on the discussion
  - add `systemNoteIconName` on each note
  - add `discussions(first: 100)` for safety
- **Types.** Add `IssueComment.resolvable`, `IssueComment.resolved` (thread level, set on the root) and `IssueActivityEntry.icon_name`.
- **New API.** `M.set_thread_resolved(issue, root, resolved, on_done)` sends `PUT …/issues/:iid/discussions/:id?resolved=…`. It is modeled on `pulls/providers/gitlab/api/comments.lua:633`.
- **Wiring.** Expose the API as `capabilities.comments.resolve_thread` in `issues/providers/gitlab/init.lua`.

### Event formatting: `issues/ui/detail/tabs/conversation/events.lua` (new, pure)
Converts an `IssueActivityEntry` into the `event_row` model.
- **Icon.** Chosen from `icon_name`, falling back to a text match:

  | Event | Icon |
  |---|---|
  | `user` / assignee | `@` |
  | moved | `⇄` |
  | `pencil` (description or title) | `✎` |
  | `task-done` / checklist | `☑` / `☐` |
  | label | label icon |
  | milestone | milestone icon |
  | `status_*` | state icon |
  | anything else | `•` |

- **Text segments.**
  - Text is dim by default.
  - `@handle` gets `person_hl`.
  - `group/proj#123`, `#123` and `!12` refs get `AtlasTimelineRef`.
  - `**bold**` text gets `AtlasTimelineObject`, with the markers stripped.
- **Rewrites.**
  - `marked the checklist item **X** as completed` becomes `checked X`.
  - `… as incomplete` becomes `unchecked X`.

### Renderer: rewrite `issues/ui/detail/tabs/conversation/renderer.lua`
This replaces its copied box code.
- `build_timeline` keeps merging comments and activity in oldest-first order. It now also cuts activity runs at **local-day boundaries** and inserts a `day` entry wherever the day changes.
- The collapse rule stays `components/activity.lua`'s (more than 4 events → keep 2, gap, keep 2). The rows now render through `event_row`.
- `issues/ui/detail/components/activity.lua` becomes a thin adapter over `event_row`, or is deleted if nothing else uses it. I'll grep before deleting.
- Comment threads render through `timeline/comment.lua`, using an issue adapter that maps `IssueComment` to the comment node: `is_you` from `actions.is_own_comment`, and an unresolved badge when the thread is `resolvable and not resolved`.
- Reply and edit composers are drawn inline with `composer/frame.lua`, at the size the active `session` reports.
- When the dock is shown, padding lines are appended at the end of the buffer.
- The `active_id`, `navigable`, `collect_navigable` and `state.move_active` code is removed.

### Keymaps: `conversation/keymaps.lua`, `state.lua`, `actions.lua`
- **Cursor targeting.** A helper `comment_at_cursor()` reads `detail.state.line_map[cursor]` and returns the comment and its thread root.
  - It replaces `state.active_comment()` for reply (`gc`), edit (`gE`), delete (`gD`), react (`gr`) and fold (`za`, `zA`).
  - The `ui.next_item` and `ui.previous_item` overrides are removed. I'll confirm `navigation.lua` doesn't hijack j/k here; if it does, `is_selectable_line` will return true for every line.
- **Cursor hint.** On `CursorMoved`, a right-aligned virt_text (built with `keyhints.render`) is drawn on the cursor line when it is inside a comment. If the cursor is on a header row, where the time sits on the right, the hint goes on the first body row instead. Edit and Delete are listed only for your own comments, as today.
- **`gX`** (`ui.comments.toggle_resolved`) calls `actions.toggle_resolved(root)`. It updates optimistically and is hidden when the thread isn't resolvable.
- **`<CR>`** (`issues.expand_activity`) on an `activity_gap` row calls `state.toggle_run(run_id)`. This also hooks up the toggle that exists today but is never called.
- **`c` and `i`** focus the dock, which expands it. The old `start_add` box at the end of the buffer goes away.
- **Reply and edit** use `composer/session.lua`. In the reply composer, `C-r` posts and then resolves with `actions.reply` followed by `actions.toggle_resolved`. The edit composer has no `C-r` and shows `Esc discard`.
- **`C-e` from any composer** keeps the draft and closes the overlay. It then calls `ui/inline_edit.start({ buf, text = draft, on_save = <the same post/save action>, on_cancel = <reopen the composer with the draft> })`, so the whole tab becomes one large edit box like the Description tab.
- **"You" detection.** If `issues.state.current_user` is nil (the detail view was opened without the dashboard), `on_select` fetches it once through the existing `users_api.get_user` path.
- **Help.** All new keys are registered with `help.register("Detail", …)` and removed again in `teardown` / `deactivate`. The dock is detached there too.

### Config: `config.lua` + `core/keymaps.lua` types/ids
Add the four approved entries: `ui.comments.submit_resolve`, `ui.comments.full_buffer`, `ui.comments.toggle_resolved` and `issues.expand_activity`.

## Implementation order (feature branch `feat/activity-timeline`, one commit each)
1. `feat(ui)`: avatar chip, keyhints, mode badge, time helpers, highlight groups.
2. `feat(ui)`: `timeline/day_divider`, `timeline/event_row`, `timeline/comment`.
3. `feat(ui)`: `composer/frame`, the `inline_field_edit` additions, `composer/session`.
4. `feat(ui)`: `ui/detail` dock API + `composer/dock`.
5. `feat(issues)`: GraphQL fields, types, resolve API, `events.lua`.
6. `feat(issues)`: renderer rewrite and the switch to cursor targeting.
7. `feat(issues)`: keymaps, config entries, wiring for the composers, `C-e` and the dock.

## Verification
- **Before every commit:** the headless load check from CLAUDE.md. Also stylua, selene and busted if they are on `PATH`; they were missing last time.
- **busted specs** for the pure modules: `events.lua` (icon and segment classification, the checklist rewrite), the time helpers (`day_label` across midnight with local time), `keyhints.format_key` and `render`, and `day_divider`.
- **Headless render script** (in the scratchpad). It builds fixture `IssueConversationItem`s that copy the mockup data, calls `renderer.render` at width 100, and prints the lines, so the layout can be compared against the screenshots line by line. It also covers the editing and reply states and a collapsed run.
- **Manual check in Neovim** against a real GitLab issue:
  - browse the timeline; check the cursor hint, `gX` resolve and `<CR>` expand
  - `gc` reply: the composer grows while typing, the INSERT/NORMAL badge follows the mode, `C-s` posts and `C-r` posts and resolves
  - `gE` edit: `● unsaved` appears, `Esc` discards
  - `c` opens the dock; `C-e` switches to the full-tab editor and back
  - resize the window and toggle the sidebar while the dock is open
