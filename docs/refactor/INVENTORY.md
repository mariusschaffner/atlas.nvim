# atlas.nvim — API layer inventory and extraction design

This inventory covers commit `ac6dd51` on `claude/nvim-gitlab-api-inventory-wp2unf`. No source file was changed to produce it.

**Purpose.** The GitLab API layer will move into a new standalone plugin. This document maps what exists today so the move doesn't lose behavior:
- §1 entry points (commands, keymaps, autocmds, public modules)
- §2 every GitLab call and which entry points reach it
- §3 dead code
- §4 the UI and its data needs
- §5 smells
- §6 a proposed design for the API layer

## Conventions

- **Paths** are relative to `lua/atlas/` unless they start with `plugin/`, `spec/`, `doc/` or `docs/`.
- **`enc(x)`** means `client.url_encode(x)` (`providers/gitlab/client.lua:142`). It percent-encodes everything except `[A-Za-z0-9-_.~]`.
- **`client`** means `providers/gitlab/client.lua`. Most API files import it under the name `service`.
- **Bare file names** (`comments.lua:110`, `issues.lua:160`, `pipelines.lua:174`, …) mean the GitLab API file of that name: `{issues,pulls,pipelines}/providers/gitlab/api/<name>`. Ambiguous names are qualified, e.g. `pulls/…/api/pipelines.lua` versus `pipelines/…/api/pipelines.lua`.
- **"S"** in a pagination column means only one page is fetched, so results are silently truncated.
- **"unwired"** means the code works but no entry point reaches it today.

Confidence levels for dead code:

| Level | Meaning |
|---|---|
| **certain** | No reference anywhere, including requires built from strings and capability-table lookups. |
| **likely** | Referenced only by tests, by other dead code, or through a capability that GitLab (the only provider) never supplies. |
| **unsure** | Dynamic dispatch could still reach it. |

## Decisions confirmed with the maintainer

| Topic | Decision |
|---|---|
| Boundary of the new plugin | Transport, endpoints, pagination, caching **and the mappers**. It returns the same domain objects (`PullRequest`, `Issue`, …) the UI uses today. `core/git` (clone, checkout, remote lookup) stays in atlas. |
| Async style | Callbacks (`fn(args, cb(result, err)) -> { cancel }`) **and** coroutine wrappers, both from day one. |
| Code used only by tests | Counts as dead, confidence *likely*. |
| Truncation and missing pagination | Flagged as smells with **intent unconfirmed**. The design keeps today's limits as explicit parameters that callers can override. |
| Endpoints that work but are unreachable (repo detail, PR-tab pipeline retry/cancel, `add_reaction`) | Kept in the design and marked *unwired*. |
| Bug-like behavior | Flagged in §5. The design fixes it, and every deviation from today is listed in §6.8. |

---

## 1. Entry points

### 1.1 Bootstrap

- `plugin/atlas.lua` only sets `vim.g.loaded_atlas`. It registers nothing, so **no command exists until the user calls `require("atlas").setup(opts)`**.
- `init.lua:9` `setup(opts)` runs three things:
  - `config.setup` (`config.lua:389`): merges options, runs `migrate_legacy`, and **sets `vim.opt.laststatus = 3` globally** unless `ui.statusline == false`.
  - `commands.setup()` (`commands/init.lua:328`).
  - `logger.clear()`.
- `init.lua:75` `open(domain, provider_id, opts)`:
  1. Looks up the provider (`providers/init.lua`).
  2. Calls `ui.dashboard.open(domain, id)`.
  3. Calls `require("atlas." .. domain).init(provider, opts)`, or `.activate(provider)` if the dashboard was already initialized.

### 1.2 User commands

| Command | Scope | Defined at | Handler → effect |
|---|---|---|---|
| `:Atlas` (no args) | global, `nargs=*` | `commands/init.lua:332` | `pick_command()` (`:231`): a picker over every subcommand × provider/argument |
| `:Atlas pulls [provider]` | | `commands/init.lua:79` | `atlas.open("pulls")` → pulls dashboard |
| `:Atlas issues [provider]` | | `:90` | `atlas.open("issues")` → issues dashboard |
| `:Atlas pipelines [provider]` | | `:101` | `atlas.open("pipelines")` → pipelines dashboard |
| `:Atlas search [provider]` | | `:112` | `commands/search/init.lua:95`. Runs the provider's hidden `search` action: for pulls, a project search (`GET /projects?search=`); for issues, `issues_api.search_issues_picker`. Then `commands.open.open(url)`. |
| `:Atlas open <url\|#n\|.>` | | `:123` | `commands/open/init.lua:112`. `.` opens the current repo's view; `#n` tries pulls then issues `core.fetch_by_refs`; a URL goes through `providers.resolve`, then the matching detail view. |
| `:Atlas create <pr\|issue\|milestone>` | | `:134` | `pulls/create/gitlab/init.lua:393` `start()`, or `issues/create/init.lua:31` `start()` → create form |
| `:Atlas diff <range\|url>` | | `:162` | `pulls/diff/init.lua:469` `open_argument` |
| `:Atlas review [url]` | | `:170` | `commands/review.lua:17`. Without a URL: `core.fetch_pullrequests` picker with a `core.fetch_pullrequest` preview, then `pulls.diff.open_pr`. |
| `:Atlas clear [cache]` | | `:183` | Clears the disk and memory caches (`core/cache`, `core/memory_cache`), and the logs unless `cache` is given. Confirms first. |
| `:Atlas logs` | | `:223` | `ui/logs.lua` `toggle()` |
| `:AtlasDiff <target>` | global, `nargs=1` | `commands/init.lua:340` | `pulls/diff/init.lua:469` `open_argument` |
| `:AtlasCreateQuit` | buffer-local (create form) | `ui/create/init.lua:292` | Closes the form. It also adds `cnoreabbrev <buffer> q/quit` (`:293-298`). |

`ui/popups/help.lua:171` `register_command` only creates buffer commands for items that have a `callback`. Its one caller (`init.lua:23`, the "Commands" help group) passes none, so nothing is created; the commands only appear in the `g?` popup.

### 1.3 Keymaps — mechanism

- **Resolver** (`core/keymaps.lua`):
  - `from_config(id)` (`:327`) walks `config.options.keymaps` along a dotted id.
  - `normalize` (`:295`) turns `false`, `nil` or `""` into disabled, and a string into a one-element list.
  - `M.item(id, def)` (`:350`) fills in `def.key`, or returns nil when the action is disabled. Callers wrap it in `utils.insert_if`.
  - `M.remove_item` (`:365`) builds the entry used for teardown.
  - `M.validate()` (`:414`) detects duplicate keys for `:checkhealth`, apart from an `ALLOWED_CONFLICTS` list (`:417-510`).
- **Binder:** `ui/popups/help.lua:109` `register(group, items, {buffer})` calls `vim.keymap.set` (`:130`) **buffer-locally** and records the item for the `g?` popup and the footer hints.
  - `help.remove` (`:190`) deletes maps without restoring whatever they shadowed, so detail views re-register their general layer on every tab switch (`pulls/ui/detail/init.lua:130`).
- **Bound directly with `vim.keymap.set`** (still using config keys unless noted):

  | File | What it binds |
  |---|---|
  | `ui/notifications/init.lua:318-357` | Notification keys, plus hardcoded `<Esc>` |
  | `ui/picker/atlas.lua:422-439` | `picker.*` in `i` and `n` modes |
  | `ui/logs.lua:293-305` | Logs window keys |
  | `ui/inline_edit.lua:129-138` | Submit and close |
  | `ui/inline_field_edit.lua:525-555` | Submit, close, completion cycling |
  | `ui/components/composer/session.lua:261-272` | Submit, close, `ui.comments.submit_resolve` |
  | `ui/popups/editor/init.lua:168, 365-405` | Completion trigger, close, submit, per-editor actions |
  | `ui/popups/live.lua:72-82` | Close (cancels the output) |
  | `ui/popups/help.lua:616-617` | Hardcoded `q` and `<ESC>` |
  | `pulls/diff/ui/loading.lua:205-207` | Close (cancels loading) |
  | `pulls/diff/ui/comments.lua:664-683` | Thread popup keys, plus hardcoded `<Esc>` |

- **Hardcoded keys (not configurable):**
  - `j`/`k` reply cycling on diff buffers (`pulls/diff/keymaps.lua:195-214`)
  - `<Esc>` in notifications and in the thread popup
  - `q`/`<ESC>` in the help popup
  - dashboard view keys `views[].key`, which are bound raw rather than through the resolver

### 1.4 Keymaps — per view

All maps are buffer-local. The "API reached" column names the provider capability and the API function it ends in; "—" means no API call.

**Dashboard, general layer** — `ui/keymaps.lua`, registered by `ui/dashboard.lua:322`

| Config key | Default | Effect | API reached |
|---|---|---|---|
| `ui.next_item` / `ui.previous_item` | `j` / `k` | Move the cursor; after 150 ms the item is selected (`ui/navigation.lua:33-45`), which refreshes the detail view if it is open | detail loads (§4) |
| `ui.first_item` / `ui.last_item` | `gg` / `G` | Jump | — |
| `ui.next_page` / `ui.previous_page` | `gp` / `gP` | Page through the rows already loaded | — |
| `ui.inspect` | `i` | `<domain>.ui.dashboard.toggle_detail()` → open or close the detail view | detail loads |
| `ui.next_panel_tab` / `ui.previous_panel_tab` | `<Tab>` / `<S-Tab>` | Cycle issues → pulls → pipelines (`ui/dashboard.lua:341-367`) | dashboard loads |
| `ui.notifications.open` | `N` | Notifications float | `notifications.fetch` → `GET /todos` |
| `ui.help` / `ui.close` | `g?` / `q` | Help / close | — |

`ui.select` (`<CR>`) is **not** bound on the dashboard.

**Pulls dashboard** — `pulls/ui/dashboard/keymaps.lua`

| Key (default) | Effect → API |
|---|---|
| `views[].key` | `controller.switch_view` → `core.fetch_pullrequests` → `pullrequests.fetch_pullrequests` |
| `ui.filter` (`/`) | Filter bar edit → re-fetch; completion of the user filter goes through `users.list_members` **directly** (`ui/filter_completion.lua:22`) |
| `ui.clear_filter` (`\`) | Reset the filter → re-fetch |
| `pulls.create_pr` (`c`) | `pulls.create.gitlab.start()` (create form). Bound only if `core.create_pr` exists. |
| `ui.refresh` (`r`) | `core.fetch_by_refs` (GraphQL `MR_SUMMARIES_QUERY`) |
| `ui.refresh_view` (`R`) | `fetch_pullrequests` with `force_load` |

**Issues dashboard** — `issues/ui/dashboard/keymaps.lua`

| Key (default) | Effect → API |
|---|---|
| `views[].key` | `core.fetch_issues` → `issues.list_issues`. For project-scoped, non-compact views also `core.fetch_milestones` → `milestones.list`. Missing parents → `core.fetch_by_refs`. |
| `ui.filter` / `ui.clear_filter` | Same as pulls |
| `issues.create_issue` (`c`) | `create_issue` action → create form |
| `ui.toggle_fold` / `ui.toggle_all_folds` (`za` / `zA`) | Fold milestone groups (local) |
| `ui.refresh` (`r`) | `core.fetch_by_refs` → `issues.fetch_by_refs` (→ `list_issues` with `iids[]`) |
| `ui.refresh_view` (`R`) | Calls `core.refresh` if present (GitLab doesn't define it), then reloads |

**Pipelines dashboard** — `pipelines/ui/dashboard/keymaps.lua`

| Key (default) | Effect → API |
|---|---|
| `views[].key`, `ui.filter`, `ui.refresh_view` (`R`) | `core.fetch_pipelines` → `pipelines.fetch_pipelines` (GraphQL) |

**Pull request detail, general layer** — `pulls/ui/detail/keymaps.lua`

| Key (default) | Effect → API |
|---|---|
| `ui.select` (`<CR>`) | The active tab's `on_enter` |
| `ui.refresh` / `ui.refresh_view` (`r` / `R`) | `detail.refresh()` → `fetch_pullrequest`, `fetch_by_refs`, `data.load_pr` (§4) |
| `ui.open_actions` (`A`) | Actions picker:<br>• Approve → `reviews.approve`<br>• Merge → `pullrequests.merge`<br>• Decline → `pullrequests.decline`<br>• Reopen → `pullrequests.set_state`<br>• Mark as ready → `pullrequests.set_draft`<br>• Copy ID / Copy URL / Open in browser<br>• `custom_actions` from config |
| `pulls.open_diff` (`gd`) | `pulls.diff.open_pr` (§4 diff) |
| `pulls.edit_title` (`gt`) | `pullrequests.update_title` |
| `pulls.edit_reviewers` (`gr`) | `fetch_default_reviewers` (members + `reviews.fetch_reviewers`) → `update_reviewers` |
| `pulls.edit_assignees` (`ga`) | Registry calls the API directly: `fetch_pullrequest` (if details are missing), `users.list_members`, `update_assignees` |
| `pulls.edit_labels` (`gl`) | `labels.list` → `update_labels` |
| `pulls.edit_milestone` (`gM`) | `milestones.list` → `update_milestone` |
| `pulls.edit_target_branch` (`gB`) | `pullrequests.list_branches` → `update_target_branch` |
| `pulls.toggle_remove_source_branch` (`gb`) | `update_remove_source_branch` |
| `pulls.open_pipeline` (`gp`) | Pipeline detail view |
| `ui.open_in_browser` (`gx`) | — |
| `ui.next_panel_tab` / `ui.previous_panel_tab`, `ui.help`, `ui.close` | — |

Actions hidden from the `A` picker but present in the registry: request_changes, the `edit_*` actions, search, `toggle_subscription` (**calls `client.request` directly**), open_diff, convert_to_draft, edit_description.

**Pull request detail, per tab**

| Tab | Key (default) | Effect → API |
|---|---|---|
| Description | `ui.edit_description` (`i`) | `fetch_description` (REST) → inline edit → `update_description` |
| Activity (shared `ui/detail_tabs/activity/keymaps.lua:477-544`) | `ui.comments.add` (`i`) | `comments.add_comment` |
| | `ui.comments.reply` (`gc`) | `add_comment` with a parent |
| | `ui.comments.edit` (`gE`) | `edit_comment` |
| | `ui.delete` (`gD`) | `delete_comment` |
| | `ui.comments.toggle_resolved` (`gX`) | `set_thread_resolved` |
| | `ui.comments.submit_resolve` (`<C-r>`) | Reply, then resolve |
| | `issues.expand_activity` (`<CR>`), `za`, `zA` | Local folding |
| Changes | `pulls.toggle_file_viewed` (`v`) | Local file under `stdpath('data')/atlas/viewed`, no API |
| Changes / Commits | `<CR>` | open_diff |
| Pipelines (`tabs/pipelines/keymaps.lua`) | `za` | Expand a pipeline → `pipelines.fetch_details` (REST jobs), or a job → `fetch_job_log` (REST trace) |
| | `pulls.pipeline_retry` / `pulls.pipeline_cancel` (`gR` / `gX`) | **Broken.** They look up `capabilities.pipelines.retry/cancel/retry_job/cancel_job` (`:167-179`), but GitLab only exposes `fetch`, `fetch_details`, `fetch_job_log` and `actions` (`pulls/providers/gitlab/init.lua:279-284`), so they always warn "not supported". |
| | `<CR>` | Pipeline detail view |

**Issue detail** — `issues/ui/detail/keymaps.lua` and its tabs

| Key (default) | Effect → API |
|---|---|
| `ui.open_actions` (`A`) | Close/reopen → `issues.set_state`; manage templates (local); browse; copy key/URL; `custom_actions` |
| `issues.edit_issue` (`gt`) | `issues.update_title` |
| `issues.change_assignee` (`ga`) | `issues.get_assignees` (GraphQL) + `users.list_members` → `set_assignee_ids` |
| `issues.change_label` (`gl`) | `fetch_issue_labels` (GraphQL) + `labels.list` → `update_labels` |
| `issues.change_milestone` (`gM`) | `milestones.list` → `set_milestone_id` |
| `issues.change_start_date` / `issues.change_due_date` (`gs` / `gd`) | `update_issue_dates` (GraphQL `workItemUpdate`) |
| `issues.create_branch` (`gb`) | `fetch_project_branches` → picker → `create_branch` |
| `issues.go_to_pull` (`gp`) | Pull request detail for a linked MR |
| `issues.create_pull_for_issue` (`gP`) | Create form for a PR |
| `issues.go_to_milestone` (`gm`) | Milestone view |
| `ui.edit_description` (`i`), `issues.toggle_task_item` (`x`) — Description tab | `issues.update_description` |
| Activity tab (`issues.add_comment` = `i`, plus the shared keys) | `notes.add_comment`, `reply_comment`, `edit_comment`, `delete_comment`, `set_thread_resolved` (GraphQL) |

**Milestone view** — `issues/ui/detail/milestone/keymaps.lua`

| Key (default) | Effect → API |
|---|---|
| `ui.open_actions` (`A`) | `milestones.set_state` |
| `issues.change_milestone_title` (`gt`) | `milestones.update_title` |
| `ui.edit_description` (`i`, Description tab) | `milestones.update_description` |
| `issues.change_milestone_start_date` / `_due_date` (`gs` / `gd`) | `milestones.update_start_date` / `update_due_date` |
| `ui.inspect` (`i`, Work items / Merge requests tabs) | Issue detail / pull request detail |

**Pipeline detail** — `pipelines/ui/detail/keymaps.lua`

All actions go through `pipeline_state.Store:run_action` (`pipelines/pipeline_state.lua:433`) → `capabilities.detail.*`.

| Key (default) | Effect → API |
|---|---|
| `pipelines.retry_failed` (`R`) | `retry_pipeline` |
| `pipelines.cancel_pipeline` (`gX`) | Confirm, then `cancel_pipeline` |
| `pipelines.retry_job` / `play_job` / `cancel_job` (`r` / `p` / `X`) | `retry_job` / `play_job` / `cancel_job` |
| `pipelines.follow` (`F`) | Follow the log |
| `pipelines.fullscreen` (`gz`) | Hide or show the graph |
| `pipelines.previous_stage` / `next_stage` (`h` / `l`), `ui.next_item` / `ui.previous_item` | Navigate the graph |
| `ui.select` (`<CR>`) / `pipelines.focus_graph` (`<Esc>`) | Switch between graph and log |
| `ui.toggle_fold` | Fold a log section |

**Create form** — `ui/create/keymaps.lua`

| Key (default) | Effect → API |
|---|---|
| `ui.create.field_type` / `field_title` (`T` / `gt`) | Edit type / title |
| Issue fields (`ga`, `gl`, `gM`, `gs`, `gd`, `gT`) | Completion from `users.list_members`, `labels.list`, `milestones.list` (called directly); templates are local |
| Merge request fields (`gs`, `gB`, `ga`, `gl`, `gr`, `gw`) | Source/target branch from local git; members and labels via the API directly |
| `:w` (BufWriteCmd, `ui/create/init.lua:264-287`) | Pull request: `git push` if needed, then `pullrequests.create_pr`.<br>Issue: `issues.create_issue`, then `fetch_issue_dates` + `update_issue_dates`.<br>Milestone: `milestones.create`. |

**Diff and review overlay** — `pulls/diff/keymaps.lua:65-298`, on AtlasDiff, Diffview and CodeDiff buffers

| Key (default) | Effect → API |
|---|---|
| `ui.refresh` (`r`) | `reviews.fetch` + `core.fetch_user` |
| `pulls.review.approve` / `request_changes` (`ga` / `gr`) | Review editor → `reviews.approve` / `request_changes` (both use `draft_notes/bulk_publish`; approve also calls `/approve`) |
| `pulls.review.submit_review` (`gs`) | `reviews.submit`. Bound only while drafts are pending. |
| `pulls.review.diff.add_comment` / `submit_comment` (`c` / `C`) | `comments.add_comment` as a draft (`pending`) or published |
| `pulls.review.diff.add_suggestion` / `submit_suggestion` (`s` / `S`) | Same, with a suggestion fence |
| `pulls.review.diff.toggle_resolved` (`gX`) | `comments.set_thread_resolved` |
| `ui.comments.edit` / `ui.delete` (`gE` / `gD`) | `edit_comment` / `delete_comment` |
| `pulls.review.diff.toggle_review_panel` (`gR`) | Review panel |
| `pulls.review.diff.toggle_detail_panel` (`gP`) | Pull request detail |
| `ui.open_actions` (`A`) | Review actions picker (`pulls/diff/actions.lua:107`); discard → `reviews.discard` |
| `ui.show_details` (`gK`) | Thread popup |
| Comment navigation, toggles, folds, help (`g?`, or `gA` in external viewers) | — |
| Native AtlasDiff (`pulls/diff/atlas/keymaps.lua`): hunks, files, explorer, commits panel (`r`/`R` → `core.fetch_commits`), toggle file reviewed (`-`, local only) | |
| Review panel (`pulls/diff/ui/review_panel.lua:856-1008`) and thread popup (`pulls/diff/ui/comments.lua:664`) | Reply, edit, delete, resolve → `comments.*` |

**Notifications float** — `ui/notifications/init.lua:318-357`

| Key (default) | Effect → API |
|---|---|
| `ui.refresh_view` (`R`) | `notifications.fetch` → `GET /todos` |
| `ui.notifications.mark_read` (`r`) | `POST /todos/:id/mark_as_done` |
| `ui.notifications.mark_done` (`d`) | `POST /todos/:id/mark_as_done` (`mark_read` is an alias of `mark_done`, `providers/gitlab/notifications.lua:109`) |
| `ui.open_in_browser` (`gx`), `ui.close`, `<Esc>` | — |

### 1.5 Autocmds and augroups

| File:line | Event | Target | Augroup | Purpose |
|---|---|---|---|---|
| `ui/dashboard.lua:41,395` | VimResized, WinResized, TabEnter | global | `AtlasDashboardResize` (created at module load) | Re-render |
| `ui/dashboard.lua:215,225,236,274,285` | BufWinLeave, BufWinEnter, BufDelete (once), WinClosed (once), TabClosed | dashboard buf/win, global | `AtlasDashboard<session>` | Session lifecycle |
| `ui/navigation.lua:64-81` | CursorMoved; BufDelete/BufWipeout | dashboard buf | `AtlasUINavigation<buf>` | Debounced select → detail loads |
| `ui/detail.lua:206` | WinClosed (once) | single-layout win | — | Deactivate the detail view |
| `ui/detail.lua:443-453` | WinEnter | global | `AtlasDetailHeaderFocusGuard<tab>` | Keep focus off the header and sidebar |
| `ui/detail.lua:482-484` | WinClosed (once) ×3 | content, header, spacer wins | — | Tear down the split layout |
| `ui/detail.lua:768` | VimResized | global | `AtlasDetailResize` (module load) | Re-layout |
| `ui/popups/help.lua:52` | BufWipeout (once) | each registered buf | — | Drop that buffer's help registry |
| `ui/popups/help.lua:629-638` | CursorMoved, InsertEnter, BufLeave; also `vim.on_key` at `:620` | global | `AtlasHelpUI` | Auto-close the help popup |
| `ui/popups/info.lua:125` | CursorMoved(I), BufLeave (once) | source buf | — | Close the info popup (module is dead, §3) |
| `ui/popups/live.lua:84` | BufWipeout (once) | output buf | — | Cleanup |
| `ui/popups/editor/init.lua:178,304,314,331` | BufWipeout, CursorMoved, VimResized, WinClosed | editor buf/win | `AtlasMarkdownEditor<buf>` | Markdown editor |
| `ui/notifications/init.lua:418` | WinClosed (once) | float | — | Delete the buffer |
| `ui/picker/atlas.lua:443-461` | TextChanged(I), VimResized, WinClosed | picker buf/wins | — | Native picker |
| `ui/inline_edit.lua:71` | BufWipeout (once) | content buf | — | Clear state |
| `ui/inline_field_edit.lua:378,516,564,576` | WinScrolled/WinResized, TextChangedI/P, BufWipeout | overlay | `AtlasInlineFieldEdit<buf>` | Anchor, completion, cleanup |
| `ui/components/composer/session.lua:134,278,291,306,320` | TextChanged*, ModeChanged, WinLeave, BufWipeout | composer buf | `AtlasComposerSession<buf>` | Comment composer |
| `ui/detail_tabs/activity/keymaps.lua:534-541` | CursorMoved | content buf | `Atlas<host>Hint<buf>` | Comment hints |
| `issues/ui/detail/tabs/overview/init.lua:237-246` | CursorMoved | content buf | `AtlasIssuesDetailOverviewHint<buf>` | Task-toggle hint |
| `pulls/ui/detail/tabs/commits/init.lua:418` | CursorMoved | content buf | `AtlasPullsCommitsCursor<buf>` | Commit hint |
| `pipelines/ui/detail/log_view.lua:296-310` | CursorMoved | log buf | `AtlasPipelineLog<buf>` | Stop following the log when moving up |
| `ui/create/init.lua:285` | **BufWriteCmd** | create buf | `AtlasCreateWrite<buf>` | `:w` submits (API) |
| `pulls/diff/keymaps.lua:74,162` | CursorMoved | diff bufs | `AtlasDiffActiveComment<session>` | Active thread |
| `pulls/diff/ui/loading.lua:131,208-227` | VimResized/WinResized, TabClosed, BufWipeout | loading tab | `AtlasLoading<tab>` | Redraw / cancel |
| `pulls/diff/ui/comments.lua:684` | WinClosed (once) | thread popup | — | Reset |
| `pulls/diff/atlas/init.lua:433-487` | TabClosed, WinClosed, WinResized/TabEnter | global | `AtlasDiffNative<tab>` | Native diff lifecycle |
| `pulls/diff/atlas/explorer.lua:530` | CursorMoved | explorer buf (only if `explorer.preview`) | session | Preview a file |
| `pulls/diff/diffview/init.lua:414,427` | User `DiffviewDiffBufWinEnter`, `DiffviewViewPostLayout`, `DiffviewViewClosed` | — | `AtlasDiffview<tab>` | Adapter |
| `pulls/diff/codediff/init.lua:467,481,491,505,627` | User `CodeDiffFileSelect`, `CodeDiffVirtualFileLoaded`, `CodeDiffClose`, `CodeDiffOpen`; WinClosed | — | `AtlasCodeDiff<session>` | Adapter |

**`User` events emitted** (`core/events.lua:14`):

| Event | Emitted at |
|---|---|
| `AtlasUIClosed` | `ui/dashboard.lua:209` |
| `AtlasDiffOpened` | `pulls/diff/atlas/init.lua:586` |
| `AtlasDiffClosed` | `pulls/diff/atlas/init.lua:45` |
| `AtlasReviewAttached` | `pulls/diff/session.lua:277` |
| `AtlasReviewDetached` | `pulls/diff/session.lua:332` |

### 1.6 Public modules and surface

| Surface | Where | Notes |
|---|---|---|
| `require("atlas").setup(opts)` | `init.lua:9` | Documented |
| `require("atlas").open(domain, provider_id, {initial_view})` | `init.lua:75` | Undocumented; used internally |
| `:checkhealth atlas` | `health.lua:152` | Checks Neovim ≥ 0.10, git and curl, the pulls config, GitLab `base_url`/`token` (https), views, and `keymaps.validate()` |
| `require'atlas.ui.statusline'.current(N)` | `ui/statusline.lua` | Must stay public: it is referenced from window `statusline` expressions via `v:lua` |
| `pipelines/ui/detail/log_view.lua:248` `foldtext` | | Referenced via a `v:lua` string (`:16`) |
| `User` events | §1.5 | Documented in README and `doc/atlas.txt` |
| Config options | `config.lua` | Documented in README and `doc/atlas.txt`, with drift (below) |

**Where the docs disagree with the code.** README.md and doc/atlas.txt both omit `:Atlas pipelines` and `:Atlas create milestone`. Documented keymap defaults differ from `config.lua`:

| Action | README / doc/atlas.txt | Actual default |
|---|---|---|
| `ui.delete` | `dd` | `gD` |
| `ui.comments.add` | `a` / `i` | `i` |
| `ui.comments.reply` | `c` | `gc` |
| `ui.comments.edit` | `e` | `gE` |
| `ui.show_details` | `K` | `gK` |
| `issues.edit_issue` | `ge` | `gt` |
| `pulls.edit_title` | `T` | `gt` |
| `pulls.review.diff.toggle_detail_panel` | `gD` | `gP` |
| `pulls.review.diff.toggle_resolved` | `x` | `gX` |
| `pulls.pipeline_retry` / `pipeline_cancel` | `t` / `x` (doc/atlas.txt only) | `gR` / `gX` |

The docs also list options and keys that don't exist: `ui.search`, `pulls.edit_description`, `pulls.filters.*`, `issues.filters.*`, `pulls.delete_notes`.

---

## 2. API usage

### 2.1 Transport — how URL and token are built

```
config.options.providers.gitlab = { base_url, token, cache_ttl }      (config.provider_options("gitlab"))
        │
client.request(method, endpoint, data, on_done, ctx)            providers/gitlab/client.lua:154
client.request_text(method, endpoint, on_done, ctx, {headers})  :213   (job traces, raw files)
client.graphql(query, variables, on_done, ctx)                  :242
client.fetch_all_pages(endpoint, on_done, ctx)                  :272
        │  URL  = base_url():gsub("/+$","") .. "/api/v4" .. endpoint      (:65-68, :180, :227)
        │  GQL  = base_url() .. "/api/graphql"                            (:252)
        │  hdrs = PRIVATE-TOKEN: <token>, Content-Type/Accept: application/json  (:71-77)
        ▼
core/http.lua curl_request / curl_text_request
        curl -sS [-L for text] -X M -H … [--data-raw <json>] -w __ATLAS_HTTP_CODE:%{http_code} <url>
        run with vim.fn.jobstart; callback runs via vim.schedule
```

- **Auth check:** every entry point checks that `base_url` and `token` are set (`client.lua:155,214,243`). If not, it calls `on_done(nil, "Missing GitLab credentials in config")` synchronously and returns nil.
- **Endpoint strings** are concatenated by each API module. The project segment is `enc(path)` everywhere on REST, except the README fetch, which uses the numeric project id. GraphQL passes the raw `fullPath` as a variable, which is correct.
- **Error pipeline:**
  1. curl exits non-zero → `"curl exited with code N: <stderr>"`.
  2. Empty body → `"Empty response from server"`, unless the status is 2xx, which yields `{__http_status}`.
  3. Non-2xx → `"HTTP <code>: <body on one line>"`. This happens **before** JSON decoding.
  4. JSON decode failure → `"Failed to parse JSON response …"`.
  5. On a 2xx table response, `client.request` also treats a `message`, `error_description` or `error` field as a failure (`client.lua:190-200`).
  6. GraphQL: any `errors[]` entry fails the call, using `errors[1].message` (`:258`).
  7. Every failure is logged via `core/logger`.
- **Caches** (all keyed manually by each API module):
  - Memory: `core/memory_cache.lua`, one module-level store, 20 entries, first-in-first-out.
  - Disk: `core/cache.lua`, JSON files under `stdpath("cache")/atlas/cache`, synchronous I/O.
  - TTL is `providers.gitlab.cache_ttl` (default 300 s). Setting it to 0 or less disables both caches.
- **Pagination helpers:**
  - `client.fetch_all_pages` adds `per_page=100` and fetches `page=1,2,…` one after another until a page has **fewer than 100** items.
  - `core/pagination.lua` `run()` is used only by the issues dashboard, and only ever gets one page (§5.2).
  - Two hand-written GraphQL cursor loops (§5.4).

### 2.2 Call sites

All 82 `client.*` call sites are listed (checked with `grep -rnE "(service|client)\.(request|request_text|graphql|fetch_all_pages)\("`).

The **Reached by** column uses these abbreviations:

| Abbreviation | Meaning |
|---|---|
| D-PR, D-IS, D-PL | Pulls, issues, pipelines dashboard load, view switch or filter |
| PRD, ISD, MS, PLD | Pull request detail, issue detail, milestone view, pipeline detail |
| DIFF | `:Atlas diff`, `:Atlas review`, `:AtlasDiff`, `gd` |
| CR | Create form |
| NT | Notifications |
| OPEN | `:Atlas open` |
| SRCH | `:Atlas search` |
| REV | `:Atlas review` |

#### Issues — `issues/providers/gitlab/api/issues.lua`

| Line | Function | Method | Path / GraphQL operation | Encoding | Pagination | Cache | Errors | Reached by |
|---|---|---|---|---|---|---|---|---|
| 160 | `list_issues` (also `fetch_by_refs` :180/201) | GET | `/projects/:id/issues?…` or `/issues?…` | `enc(view.project)`; values encoded, **keys not** (`build_query` :85-111) | `per_page=max_results` (default 50), S, `is_last` always true | disk `gitlab:issues:list:v3:<endpoint>`, 300 s | `(nil, err)` | D-IS, `r`, OPEN `#n`, PR Description tab (closing refs), ISD refresh |
| 250 | `fetch_issue` | POST GQL | `ISSUE_DETAILS_GQL`: `project(fullPath).issue(iid){description assignees(first:100) labels(first:100) milestone…}` | raw path | `first:100` | memory `gitlab:issue-details:<p>#<iid>` | `(nil, err)`; "Issue not found" | ISD |
| 282 | `get_assignees` | GQL | `issue.assignees(first:100)` | raw | `first:100` | — | `(nil, err)` | ISD `ga` |
| 327 | local `update_issue` → `update_description`, `update_title`, `set_state`, `update_labels`, `set_assignee_ids`, `set_milestone_id` | PUT | `/projects/:id/issues/:iid` | enc | — | deletes details; clears the disk list prefix (sync scan) | `(false, err)` | ISD edits, `A` |
| 397 | `fetch_issue_labels` | GQL | `issue.labels(first:100)` | raw | `first:100` | — | `(nil, err)` | ISD `gl` |
| 484 | `create_issue` | POST | `/projects/:id/issues` | enc | — | clears the disk list prefix | `(nil, err)` | CR |
| 548 | `fetch_related_merge_requests` | GET | `/projects/:id/issues/:iid/related_merge_requests` | enc | **no `per_page` → GitLab default 20**, S | memory `gitlab:issue-linked-mrs:…` | `(nil, err)` | ISD, `gp` |
| 594 | local `fetch_cached_branches` → `fetch_related_branches`, `fetch_project_branches` | GET | `/projects/:id/repository/branches?per_page=100` | enc | S (related branches filtered client-side by `<iid>-` prefix) | memory, 2 keys for the same data | `(nil, err)` | ISD, `gb` |
| 704 | `create_branch` | POST | `/projects/:id/repository/branches?branch=&ref=` | enc; branch and ref encoded | — | deletes linked-branches key only | `(nil, err)` | ISD `gb` |
| 740 | `fetch_issue_dates` | GQL | `namespace(fullPath).workItem(iid){widgets{…StartAndDueDate}}` | raw | — | memory `gitlab:issue-dates:…` | `(nil, err)` | ISD, CR |
| 799 | `update_issue_dates` | GQL mutation | `workItemUpdate(input)` | work-item GID | — | deletes dates | `(nil, err)` + payload `errors` | ISD `gs`/`gd`, CR |
| 844 | `search_issues_picker` | GET | `/issues?scope=all&state=all&search=&per_page=30&order_by&sort` | values encoded | S (30) | — | `(nil, err)` | SRCH |

#### Other issues-side files

| File:line | Function | Method | Path / operation | Encoding | Pagination | Cache | Errors | Reached by |
|---|---|---|---|---|---|---|---|---|
| `issues/…/api/list_helper.lua:22` | `fetch_list` (used by labels and milestones) | GET | `string.format(endpoint, enc(path))` | enc | caller's | — | `(nil, err)` | — |
| `issues/…/api/labels.lua:10` | `list` | GET | `/projects/:id/labels?per_page=100` | enc | S | — | | ISD `gl`, CR |
| `issues/…/api/milestones.lua:41` | `list` | GET | `/projects/:id/milestones?per_page=100&state=active` | enc | S | — | | D-IS (grouped), ISD `gM`, CR |
| `issues/…/api/milestones.lua:59` | `get` | GET | `/projects/:id/milestones/:mid` | enc | — | — | | MS |
| `issues/…/api/milestones.lua:91` | `list_issues` | GET | `/projects/:id/milestones/:mid/issues?per_page=100` | enc | S | — | | MS |
| `issues/…/api/milestones.lua:129` | `list_merge_requests` | GET | `/projects/:id/milestones/:mid/merge_requests?per_page=100` | enc | S | — | | MS |
| `issues/…/api/milestones.lua:182` | `create` | POST | `/projects/:id/milestones` | enc | — | — | | CR (milestone) |
| `issues/…/api/milestones.lua:210` / `:232` | `update_description`; local `update_field` → `update_title`, `update_start_date`, `update_due_date`, `set_state` | PUT | `/projects/:id/milestones/:mid` | enc | — | **none** | `(ok, err)` | MS |
| `issues/…/api/notes.lua:70` | local `fetch_discussions` → `list_conversation` | GQL | `issue.discussions{nodes{… notes{nodes{… awardEmoji}}}}` | raw | **no `first` / cursor** (server default 100) | memory `gitlab:discussions:…` | `(nil, err)` | ISD Activity |
| `issues/…/api/notes.lua:153` | `add_comment` | POST | `/projects/:id/issues/:iid/discussions` | enc | — | deletes discussions | | ISD Activity |
| `issues/…/api/notes.lua:197` | `reply_comment` | POST | `…/discussions/:did/notes` | enc; **did raw** | — | same | | ISD Activity |
| `issues/…/api/notes.lua:252` | `edit_comment` | PUT | `…/discussions/:did/notes/:nid` or `…/notes/:nid` | **did, nid raw** | — | same | | ISD Activity |
| `issues/…/api/notes.lua:282` | `delete_comment` | DELETE | same | same | — | same | `(false, err)` | ISD Activity |
| `issues/…/api/notes.lua:326` | `set_thread_resolved` | GQL mutation | `discussionToggleResolve` (`gid://gitlab/Discussion/<did>`) | — | — | same | + payload errors | ISD Activity |
| `issues/…/api/users.lua:17` | `get_user` | GET | `/user` | — | — | **disk** `gitlab:user:me`, never invalidated | | D-IS, CR (called directly) |
| `issues/…/api/users.lua:47` | `list_members` | GET | `/projects/:id/members/all?per_page=100[&query=]` | enc; query encoded | S | — | | ISD `ga`, CR, filter completion (called directly) |
| `issues/…/actions/registry.lua:639` | local `toggle_subscription` | POST | `/projects/:id/issues/:iid/{subscribe\|unsubscribe}` | enc | — | **none**; mutates `issue.is_subscribed` in place | `notify.error` + `done(nil, err)`; a 304 becomes the error "HTTP 304" | **unwired** (hidden action, key `ui.toggle_subscription` unbound) |
| `providers/gitlab/notifications.lua:76` | `fetch` | GET | `/todos?per_page=N[&state=]` | **state raw** | S | memory `gitlab:todos:…`, **60 s** | `(nil, err)` | D-PR / D-IS (unread count), NT |
| `providers/gitlab/notifications.lua:97` | `mark_done` (= `mark_read`) | POST | `/todos/:id/mark_as_done` | id raw | — | **todos cache not invalidated** | `(false, err)` | NT `r`/`d` |

#### Pipelines — `pipelines/providers/gitlab/api/pipelines.lua`

| Line | Function | Method | Path / operation | Encoding | Pagination | Cache | Errors | Reached by |
|---|---|---|---|---|---|---|---|---|
| 174 | `fetch_pipelines` | GQL | `PROJECT_PIPELINES_QUERY` `project.pipelines(first:50){… stages(first:20)}` or `MR_PIPELINES_QUERY` | raw | `first:50` | memory `gitlab_pipelines:list:…` | `({}, nil, true, err)` | D-PL |
| 225 | `fetch_pipeline_details` | GET | `/projects/:id/pipelines/:pid/jobs?per_page=100` | enc | `fetch_all_pages` | — | | **unwired** (`core.fetch_pipeline_details` never read) |
| 278 | `fetch_job_log` | GET text | `/projects/:id/jobs/:jid/trace` | enc | — | — | follows redirects | **unwired** |
| 455 | `fetch_pipeline` | GET | `/projects/:id/pipelines/:pid` | enc | — | — | | PLD |
| 483 | `fetch_pipeline_graph` | GQL | `project.pipeline(iid){… [mergeRequest] stages{nodes{groups{nodes{jobs{nodes…}}}}}}` | raw | none (server caps) | — | if the error mentions `mergeRequest`, sets a module flag and retries without the field | PLD (polling) |
| 536 | `fetch_job_trace` | GET text | `/projects/:id/jobs/:jid/trace` + `Range: bytes=N-` | enc | incremental | — | 416 → `""` | PLD (polling) |
| 554 | local `post_action` → `retry_pipeline`, `cancel_pipeline`, `retry_job`, `cancel_job`, `play_job` | POST | `/projects/:id/pipelines/:pid/{retry,cancel}`, `/projects/:id/jobs/:jid/{retry,cancel,play}` | enc | — | **pipeline list not invalidated** | `(ok, err)` | PLD keys |

#### Pull requests — `pulls/providers/gitlab/api/pullrequests.lua`

| Line | Function | Method | Path / operation | Encoding | Pagination | Cache | Errors | Reached by |
|---|---|---|---|---|---|---|---|---|
| 132 | `fetch_pullrequests` | GET | `/projects/:id/merge_requests?…`, `/groups/:id/merge_requests?…` or `/merge_requests?…` | enc; values encoded, keys not | `per_page=pagelen` (≤100), S | **disk** `gitlab_pulls:merge_requests:<endpoint>`, **never invalidated** | `({}, err)` | D-PR, REV |
| 183 | `fetch_by_refs` | GQL | `MR_SUMMARIES_QUERY` `project.mergeRequests(iids, first:100){… reviewers(first:100)}` | raw | `first:100` | memory `gitlab_pulls:refs:…`, never invalidated | | D-PR `r`, PRD, OPEN, DIFF |
| 242 | `fetch_pullrequest` | GQL | `MR_DETAILS_QUERY` `mergeRequest{description subscribed assignees labels milestone}` | raw | `first:100` | memory `gitlab_pulls:details:…` | | PRD, REV preview, `ga` |
| 279 | `fetch_description` | GET | `/projects/:id/merge_requests/:iid` | enc | — | — | | PRD `i` |
| 314 | local `update` → `set_state`, `decline`, `update_title`, `update_description`, `update_target_branch`, `update_labels`, `update_milestone`, `update_remove_source_branch`, `set_draft`, `update_reviewers`, `update_assignees` | PUT | `/projects/:id/merge_requests/:iid` | enc | — | deletes details, reviewers and review_metadata; **not** refs, merge-checks or the disk list | `(false, err)` | PRD keys, `A` |
| 384 | `list_branches` | GET | `/projects/:id/repository/branches?per_page=100` | enc | S | **none** (re-fetched on every completion) | | PRD `gB` |
| 485 | `fetch_default_reviewers` | GET | `/projects/:id/members/all?per_page=100`, plus `reviews.fetch_reviewers` | enc | S | — | | PRD `gr` |
| 601 | `merge` | PUT | `/projects/:id/merge_requests/:iid/merge` | enc | — | invalidates details | | PRD `A` |
| 670 | `create_pr` | POST | `/projects/:id/merge_requests` | enc | — | **list not invalidated** | | CR |

#### Pull request comments and reviews

| File:line | Function | Method | Path / operation | Encoding | Pagination | Cache | Errors | Reached by |
|---|---|---|---|---|---|---|---|---|
| `comments.lua:110` | `fetch_review_comments` | GET | `…/merge_requests/:iid/discussions?per_page=100` | enc | `fetch_all_pages` | memory `review-comments` | | DIFF |
| `comments.lua:117` | same | GET | `…/draft_notes?per_page=100` | enc | `fetch_all_pages` | same | | DIFF |
| `comments.lua:198` | `fetch_conversation_comments` | GQL | `mergeRequest.notes(filter:ONLY_COMMENTS, first:100, after)` | raw | **cursor loop** | memory `conversation-comments` | | PRD Activity |
| `comments.lua:369` | local `add_positioned_comment` | POST | `…/draft_notes` or `…/discussions` with a position payload | enc | — | invalidate | **`result.notes[1]` indexed without a nil check (:379)** | DIFF `c`/`C`/`s`/`S` |
| `comments.lua:402` | (diff-refs fallback) | GET | `…/versions?per_page=1` | enc | 1 | — | | DIFF |
| `comments.lua:470` | `add_comment` (pending) | POST | `…/draft_notes` | enc | — | invalidate | | DIFF |
| `comments.lua:500` | `add_comment` | POST | `…/discussions[/:did/notes]` | did encoded | — | invalidate | `notes[1]` nil risk (:505) | PRD Activity, DIFF |
| `comments.lua:569` | `edit_comment` | PUT | `…/draft_notes/:id`, `…/discussions/:did/notes/:nid` or `…/notes/:nid` | did encoded | — | invalidate | | PRD Activity, DIFF |
| `comments.lua:614` | `delete_comment` | DELETE | same | same | — | invalidate | `(false, err)` | PRD Activity, DIFF |
| `comments.lua:652` | `set_thread_resolved` | PUT | `…/discussions/:did` `{resolved}` | did encoded | — | invalidate | | PRD Activity, DIFF |
| `comments.lua:696` | `add_reaction` | POST | `…/notes/:nid/award_emoji?name=` | name encoded | — | invalidate | | **unwired** (`ui.comments.react` unbound) |
| `reviews.lua:168` | local `fetch_metadata` → `fetch` | GQL | `REVIEW_METADATA_QUERY` `mergeRequest{diffRefs reviewers(first:100) approvedBy(first:100) notes(ONLY_ACTIVITY, first:100, after)}` | raw | **cursor loop**; reviewers re-fetched on every page | memory `review_metadata` | | DIFF, review reload `r` |
| `reviews.lua:366` / `:352` | `discard` | GET then DELETE ×N | `…/draft_notes?per_page=100` then `…/draft_notes/:id` | id raw | `fetch_all_pages`; deletes run one after another | invalidate at end | stops at the first error | DIFF `A` → discard |
| `reviews.lua:410` | local `publish` → `submit`, `request_changes`, `approve` | POST | `…/draft_notes/bulk_publish` `{note, reviewer_state}` | enc | — | invalidate | `(false, err)` | DIFF, PRD `A` |
| `reviews.lua:434` | local `approve_pull_request` | POST | `…/merge_requests/:iid/approve` | enc | — | deletes details only | | DIFF / PRD approve |
| `reviews.lua:515` | `fetch_reviewers` | GQL | `mergeRequest{reviewers(first:100) approvedBy(first:100)}` | raw | | memory `reviewers` | | PRD load, `gr` |
| `activity.lua:85` | `fetch_activity` | GET | `…/merge_requests/:iid/notes?sort=asc&order_by=created_at&per_page=100` | enc | `fetch_all_pages` | memory `activity` | | PRD Activity |
| `changes.lua:37` | `fetch_commits` | GET | `…/merge_requests/:iid/commits?per_page=100` | enc | S | memory `commits` | | PRD Commits tab, native diff commits panel |
| `changes.lua:109` | `fetch_diff` / `fetch_diffstat` | GET | `…/merge_requests/:iid/changes` (deprecated by GitLab in favor of `/diffs`) | enc | — | memory `diff` | | PRD load (diffstat) |
| `checks.lua:232` | `fetch` → local `run` | GQL | `MERGE_STATUS_QUERY`; on **any** error, one retry with `MERGE_CHECKS_QUERY` (:255-261) | raw | — | memory `merge-checks`, never invalidated | | PRD load |
| `pulls/…/api/pipelines.lua:90` | `fetch` | GQL | `mergeRequest.pipelines(first:50){… stages(first:100)}` | raw | `first:50` | memory `pipelines` | | PRD load / Pipelines tab |
| `pulls/…/api/pipelines.lua:209` | `fetch_details` | GET | `/projects/:id/pipelines/:pid/jobs?per_page=100` | enc | `fetch_all_pages` | — | | PRD Pipelines `za` |
| `pulls/…/api/pipelines.lua:252` | `fetch_job_log` | GET text | `/projects/:id/jobs/:jid/trace` | enc | — | — | follows redirects | PRD Pipelines `za` |
| `pulls/…/api/pipelines.lua:269-293` | `retry`, `cancel`, `retry_job`, `cancel_job` | POST | delegate to the pipelines `post_action` | | | | | **unwired** (§1.4 broken `gR`/`gX`) |
| `pulls/…/api/labels.lua:16` | `list` | GET | `/projects/:id/labels?per_page=100` | enc | S | — | | PRD `gl`, CR |
| `pulls/…/api/milestones.lua:19` | `list` | GET | `/projects/:id/milestones?per_page=100&state=active` | enc | S | — | | PRD `gM` |
| `pulls/…/api/users.lua:17` | `fetch_user` | GET | `/user` | — | — | **disk** `gitlab_pulls:user:me` | | D-PR, DIFF, PRD Activity |
| `pulls/…/api/users.lua:47` | `list_members` | GET | `/projects/:id/members/all?per_page=100[&query=]` | enc | S | — | | PRD `ga`, CR, filter completion |
| `pulls/…/actions/registry.lua:582` | local `search` | GET | `/projects?search=&per_page=20&order_by=last_activity_at` | encoded | S (20) | — | | SRCH (pulls) |
| `pulls/…/actions/registry.lua:650` | local `toggle_subscription` | POST | `/projects/:id/merge_requests/:iid/{subscribe\|unsubscribe}` | enc | — | mutates the cached details | `notify` + `done(nil, err)`; 304 → error | **unwired** (hidden action, key unbound) |

#### Repository — `pulls/providers/gitlab/api/repositories.lua` (whole view unwired, §3.2)

| Line | Function | Method | Path | Encoding | Pagination | Cache | Errors |
|---|---|---|---|---|---|---|---|
| 66 | `fetch_detail` | GET | `/projects/:id?statistics=true` | enc | — | memory `gitlab:repo_details:<p>` | |
| 118 | `fetch_detail` (README) | GET text | `/projects/:numeric_id/repository/files/:file/raw?ref=` | **numeric id**; file and ref encoded | — | stored inside `repo_details` | **error swallowed** (`function(body, _)` :123) |
| 158 | local `fetch_refs` → `fetch_branches`, `fetch_tags` | GET | `/projects/:id/repository/{branches,tags}?per_page=100` | enc | S | memory | |
| 232 | `fetch_issues` | GET | `/projects/:id/issues?state=%s&per_page=50&…` | **state raw** | S | — | |
| 240 | `fetch_issues` (statistics) | GET | `/projects/:id/issues_statistics` | enc | — | — | **error swallowed** (:246 checks only `errors.issues`) |
| 297 | `delete_branch` | DELETE | `/projects/:id/repository/branches/:branch` | branch encoded | — | deletes branches key | `(false, err)` |

### 2.3 Provider capability → API function map

**Issues** (`issues/providers/gitlab/init.lua:134-182`)

| Capability | API function |
|---|---|
| `core.fetch_user` | `users.get_user` |
| `core.fetch_issues` | `issues.list_issues` (via a local wrapper) |
| `core.fetch_by_refs`, `fetch_issue`, `update_description`, `update_title` | `issues.*` of the same name |
| `core.fetch_linked_merge_requests` | `fetch_related_merge_requests` |
| `core.fetch_linked_branches` | `fetch_related_branches` |
| `core.fetch_issue_dates`, `update_issue_dates`, `fetch_project_branches`, `create_branch` | `issues.*` |
| `core.fetch_milestones` / `fetch_milestone` / `fetch_milestone_issues` / `fetch_milestone_merge_requests` | `milestones.list` / `get` / `list_issues` / `list_merge_requests` |
| `core.update_milestone_{title,description,start_date,due_date}`, `set_milestone_state`, `create_milestone` | `milestones.update_*`, `set_state`, `create` |
| `comments.fetch_conversation` | `notes.list_conversation` |
| `comments.add_comment`, `reply_comment`, `edit_comment`, `delete_comment`, `set_thread_resolved` | `notes.*` |
| `comments.comment_completion` | `completion/author.for_issues` |
| `notifications` | `providers/gitlab/notifications` |
| `actions` | `issues/…/actions` (the registry also calls the API directly) |

**Pulls** (`pulls/providers/gitlab/init.lua:227-293`)

| Capability | API function |
|---|---|
| `core.fetch_user` | `users.fetch_user` |
| `core.fetch_pullrequests` | local wrapper → `pullrequests.fetch_pullrequests`, once per state, results merged |
| `core.fetch_by_refs`, `fetch_pullrequest`, `create_pr`, `update_*`, `list_branches`, `set_draft`, `decline`, `fetch_description`, `fetch_default_reviewers` | `pullrequests.*` |
| `core.fetch_reviewers` | `reviews.fetch_reviewers` |
| `core.fetch_merge_checks` | `checks.fetch` |
| `core.fetch_diffstat`, `fetch_commits`, `fetch_diff` | `changes.*` |
| `comments.fetch_conversation` | `activity.fetch_activity` + `comments.fetch_conversation_comments` |
| `comments.add_comment`, `edit_comment`, `delete_comment`, `set_thread_resolved`, `add_reaction` | `comments.*` |
| `reviews.fetch`, `submit_review`, `approve`, `request_changes`, `discard_review` | `reviews.fetch`, `submit`, `approve`, `request_changes`, `discard` |
| `repository.fetch_details`, `fetch_branches`, `fetch_tags`, `fetch_issues`, `delete_branch` | `repositories.*` |
| `pipelines.fetch`, `fetch_details`, `fetch_job_log` | pulls `api/pipelines.*` |
| `pipelines.actions` | `actions/pipelines.lua` (never read) |
| `notifications`, `actions`, `ui` | |

Called only through the actions registry: `merge`, `set_state`, `update_labels`, `update_milestone`, `update_assignees`, `labels.list`, `milestones.list`, `users.list_members`.

**Pipelines** (`pipelines/providers/gitlab/init.lua:18-41`)

| Capability | API function |
|---|---|
| `core.fetch_pipelines` | `fetch_pipelines` |
| `core.fetch_pipeline_details`, `core.fetch_job_log` | `fetch_pipeline_details`, `fetch_job_log` (unwired) |
| `detail.fetch_pipeline`, `fetch_pipeline_graph`, `fetch_job_trace` | same names |
| `detail.retry_pipeline`, `cancel_pipeline`, `retry_job`, `cancel_job`, `play_job` | same names |

**Code that bypasses the provider and calls the API modules or client directly** (the new plugin must serve these too; they should be re-routed during the port):

| File | What it calls directly |
|---|---|
| `ui/filter_completion.lua:16-24` | `{issues,pulls}.providers.gitlab.api.users` (required from a string) |
| `ui/create/init.lua:345` | `issues…api.users.get_user` |
| `pulls/create/gitlab/init.lua:14-18` | `pullrequests_api`, `users_api`, `labels_api` |
| `issues/create/gitlab/init.lua:12-18` | `issues_api`, `milestones_api`, `users_api`, `labels_api` |
| `issues/ui/detail/milestone/renderer.lua:21` | requires `issues.providers.gitlab.wf_state` (a mapper helper, no HTTP) |
| Both actions registries (`pulls/…/actions/registry.lua`, `issues/…/actions/registry.lua`) | Build UI (pickers, inline edits) **and** call API modules and `client.request` directly |

### 2.4 How the project path is determined

1. **From the local repository** (`core/git/init.lua:313`, `local_repository`):
   - Runs `git -C <dir> remote get-url origin` **synchronously**; only `origin` is considered. The directory is the current buffer's directory or `getcwd()`.
   - The URL then goes through `parse_remote_url` → `providers.resolve` (`providers/init.lua:88`) → `providers/url.lua` `parse` → `providers/gitlab/resolve.lua`.
   - The host must equal the configured `base_url` host, or `gitlab.com` when none is configured (`resolve.lua:29-35`). Because `url.lua:28` keeps the port in the host, an SSH remote with a port (`host:2222`) never matches.
   - The base path prefix is stripped, which supports a relative URL root. Then a leading `/` and `.git` are removed, and the path must look like `group/…/repo`.
2. **Views** (`providers/gitlab/views_helper.lua:12-45`): a view with `current_repo=true` gets `project = repo_full_name`. `current_repo_project()` does the same lookup for the filter bar. Both run the synchronous git call.
3. **Per entity:**
   - Issues: `project_path` comes from `references.full` (`^(.-)#%d+$`) or a `web_url` regex (`issues/…/api/mapper.lua:128-134`).
   - Pull requests: `repo_full_name` comes from `references.full` (`!`) or `web_url` (`pulls/…/api/mapper.lua:112-121`). `MR_SUMMARIES_QUERY` doesn't request `references`, so `fetch_by_refs` results always use the `web_url` regex, which would capture a relative-root prefix (`gitlab/group/repo`).
   - Repositories use `repo.id` or `owner/repo_name` (`repositories.lua:27-38`).
   - Issue creation tries `ctx.project_path`, then `issue.project_path`, then the `origin` remote, then a `vim.ui.input` prompt (`issues/…/actions/registry.lua:548-601`).
4. **Web URLs** are built three different ways:

   | Where | How |
   |---|---|
   | `resolve.lua:18` | `url.base_url` |
   | Pipelines (`pipelines.lua:92`, `pulls/…/pipelines.lua:62`) | Origin of the base URL + path |
   | Issues mapper milestones (`mapper.lua:76`) | `base_url() .. webPath`, which doubles a relative root |

---

## 3. Dead code candidates

### 3.1 Requires built from strings (checked before declaring anything dead)

These all resolve to existing modules, so they don't hide dead code:

| Require | Where |
|---|---|
| `"atlas." .. domain` | `init.lua:64`, `ui/dashboard.lua:145,331` |
| `… .. ".ui.dashboard"` | `ui/navigation.lua:42`, `ui/keymaps.lua:10` |
| `… .. ".ui.dashboard.controller"` | `ui/dashboard.lua:376` |
| Provider modules by name | `providers/init.lua:76,123-131` |
| `STATE_MODULES` / `USERS_API_MODULES` | `ui/filter_bar.lua:16-18`, `ui/filter_completion.lua:16-23` |
| Picker backends | `ui/picker/init.lua:31-33` |

Diff adapters are required statically (`pulls/diff/init.lua:17-19`).

### 3.2 Modules and views

| Candidate | Confidence | Evidence |
|---|---|---|
| `ui/components/box.lua`, `ui/components/header.lua`, `ui/components/navbar.lua` | certain | No reference to the module name anywhere |
| `ui/popups/info.lua` | likely | Only called from `show_pr_details` / `show_issue_details`, which are dead |
| `pulls/ui/dashboard/popup.lua`, `issues/ui/popup.lua` | likely | Only required inside those same dead functions |
| `pulls/providers/gitlab/actions/pipelines.lua` | likely | Stored as `capabilities.pipelines.actions` (`pulls/providers/gitlab/init.lua:283`); nothing reads `.pipelines.actions` |
| **Repository detail view**: `pulls/ui/repo_detail/**`, `pulls/providers/gitlab/ui/repo_detail/init.lua`, and `repositories.lua` (6 calls) | likely, **unwired** | `repo_detail.open` (`pulls/ui/repo_detail/init.lua:230`) has no caller. Only `is_open`, `select` and `close` are referenced (`pulls/ui/dashboard/init.lua:57`, `controller.lua:238-258`). The keys `pulls.toggle_repo_panel` (`o`) and `pulls.toggle_repo_issue_state` (`t`) are only bound inside the view. Kept in the design. |
| `*/provider.lua`, `*/types.lua`, `*/providers/gitlab/config.lua`, `ui/notifications/types.lua` | not dead | Annotation-only files for the Lua language server |
| `ui/components/threadsv2.lua` | not dead | Live (`pulls/ui/components/review_threads.lua:5`). There is no v1, so the `v2` suffix is only a stale name. |

### 3.3 Functions

| Function | File:line | Confidence | Evidence |
|---|---|---|---|
| `show_pr_details` | `pulls/ui/dashboard/controller.lua:308` | certain | The name appears nowhere else |
| `show_issue_details` | `issues/ui/dashboard/controller.lua:411` | certain | Same |
| `logwarn` | `core/logger.lua:118` | certain | No callers |
| `delete` | `core/cache.lua:144` | certain | The client calls only `memory_cache.delete` |
| `clear_prefix` | `core/memory_cache.lua:80` | certain | The client's `clear_cache` uses the disk cache's `clear_prefix` |
| `commit_range`, `commits_for_range`, `diff_stat` | `core/git/init.lua:232,243,266` | certain | No callers; they look like leftovers from the undocumented `pr_template` feature |
| `diff_revisions`, `rev_exists` | `core/git/init.lua:207,170` | likely | Only called by the dead functions above |
| `checkout_branch`, `checkout_new_branch` | `core/git/init.lua:434,452` | certain | No callers |
| `find_hunk` | `core/git/diff_parser.lua:331` | certain | No callers |
| `window_hunk` | `core/git/diff_parser.lua:256` | likely | Only `find_hunk` calls it |
| `select_tab` (issues) | `issues/ui/detail/init.lua:577` | certain | Every `select_tab` caller targets the pulls detail |
| `popup_is_open` | `pulls/diff/ui/comments.lua:475` | certain | |
| `pr_state_fg_hl` | `pulls/ui/presentation.lua:108` | certain | |
| `timestamp_end` | `pulls/ui/pipelines/logs.lua:100` | certain | The local `log_timestamp_end` is used instead |
| `render_gauge` | `ui/components/progress_bar.lua:48` | certain | |
| `multi_select` | `ui/picker/init.lua:109` | certain | Also makes the multi-select code in `ui/picker/atlas.lua` (`:252, 391-437`) and `fzf_lua.lua` (`:25-69, 126-135, 183`) unreachable |
| `issues_priority` (and `ICONS.issues.priority`) | `ui/shared/icons.lua:148` (`:84`) | certain | |
| `get_version` (and `_cached_version`) | `ui/shared/utils.lua:255` (`:7`) | certain | The only `vim.fn.system` call in the plugin |
| `format_datetime_short`, `encode_pretty_json` | `ui/shared/utils.lua:423,613` | certain | |
| `Store:selected_trace`, `Store:active_timers` | `pipelines/pipeline_state.lua:223,252` | likely | Only `spec/pipelines/pipeline_state_spec.lua` uses them |
| `to_pipeline_state` (pipelines copy) | `pipelines/providers/gitlab/api/pipelines.lua:78` | likely | Duplicate; `checks.lua:159` uses the copy in pulls `api/pipelines.lua:48` |

Several functions are exported but only used inside their own file (and sometimes in tests). They are live, just exported more widely than needed, so they aren't listed above. Examples: `checkout.validate_repo_paths`, `timeline.days_between`, `pipeline_state.trace_delta`, `graph_layout.junction`, `strip.node_columns`, `inline_field_edit.parse_multi_value`, `logs.clean_lines`, `map_pipeline_graph`.

### 3.4 API functions and capability keys never reached

| Item | File:line | Confidence | Design |
|---|---|---|---|
| `comments.add_reaction` (capability `comments.add_reaction`) | `pulls/…/api/comments.lua:672` | likely | keep (unwired) |
| `fetch_pipeline_details`, `fetch_job_log` (capabilities `core.*`) | `pipelines/…/api/pipelines.lua:216,267` | likely | merge with the pulls copies |
| `retry`, `cancel`, `retry_job`, `cancel_job` (pulls) | `pulls/…/api/pipelines.lua:269-293` | likely | keep and wire to `gR`/`gX` |
| Capability `core.search_query` (pulls :234, issues :142) | | likely | UI-side concern |
| Capability `core.create_milestone` (issues :163) | | likely (the create form calls `milestones.create` directly) | keep |
| Capability `core.fetch_diff` (pulls :253) | | likely (`fetch_diff` itself is live through `fetch_diffstat`) | keep |
| Subscribe toggles in both registries | §2.2 | likely (hidden action, key unbound) | keep (unwired) |

### 3.5 Contract features GitLab never provides (dead UI branches)

The UI checks for these capabilities before using them, but the GitLab provider never supplies them, so the guarded code never runs.

| Contract field | UI code that can't run | Confidence |
|---|---|---|
| `reviews.edit_review` (`pulls/provider.lua:80`) | `pulls/actions/review.lua:379`, `review_panel.lua:669,905` | likely |
| `reviews.fetch_review_context` (:81) | `pulls/diff/review.lua:47-49` | likely |
| `reviews.start_review` (:82) | `pulls/actions/review.lua:581`, `actions/init.lua:486`, `diff/actions.lua:73` | likely |
| `reviews.set_file_reviewed` (:87) | `pulls/diff/atlas/init.lua:239-260` | likely |
| `tasks.*` (:32, 89-92); GitLab `reviews.fetch` always returns `tasks = {}` (`reviews.lua:320`) | `pulls/actions/review.lua:284,342,418,483`, `review_panel.lua:662-666` | likely |
| `pipelines.fetch_commit_status` (:103) | contract only | likely |
| Issues `core.refresh` (`issues/provider.lua:73`) | `issues/ui/dashboard/controller.lua:326-329` | likely |
| Issues `comments.fetch_activity` (:76) | contract only | likely |

These may matter for a future second provider. Whether they should be kept is listed as an open question (§6.9).

### 3.6 Config options

| Option | Status | Confidence |
|---|---|---|
| `pulls.repo_config.settings[*].pr_template` (`config.lua:26`) | Never read, yet documented (README.md:319, doc/atlas.txt:273,339) | certain |
| `issues.with_relationships` | Read (`issues/ui/dashboard/controller.lua:98`) but ignored by GitLab `fetch_issues` (TODO at `issues.lua:165`). README promises parent/sub-issue fetching. | certain (no effect) |
| `issues.max_results`, `issues.with_relationships` | Read, but have no default: `issues = nil` in the defaults; the code falls back to 100 and true | n/a |
| pipelines view `current_repo` | Used by the default view (`pipelines/providers/gitlab/init.lua:12`) but not declared in `AtlasGitLabPipelinesViewConfig` | n/a |
| Keymap `ui.toggle_subscription`, `ui.copy_id`, `ui.copy_url`, `pulls.review.add_task`, `issues.toggle_description_mode` | Defined in the defaults, never bound | certain |
| Keymap `ui.comments.react`, `issues.transition_issue`, `issues.change_reporter` | Only mentioned in the `validate` conflict lists | likely |
| Keymap `picker.toggle` | Only bound in multi-select mode, which nothing uses | likely |
| `migrate_legacy` (`config.lua:349`, "TODO: Remove with 0.8.0") | **Live** (called from `setup`) | not dead |

Every other option is read: `ui.*`, `git_transport`, `default_merge_method`, `default_delete_branch`, `comment_templates.*`, `diff.*`, `review_panel.height`, `repo_config.paths`, `settings.readme`, `custom_actions`, the GitLab view fields, and `base_url`/`token`/`cache_ttl`.

### 3.7 Files outside `lua/`

- **`issues/…/api/gitlab.http` and `pulls/…/api/gitlab.http`** are scratch request files that nothing loads. They use numeric project ids. They document endpoints the code doesn't use:
  - issues file: `DELETE` issue, issue `award_emoji`, `resource_label_events`, `resource_state_events`
  - pulls file: `raw_diffs`, `/merge_requests/:iid/pipelines`, `unapprove`, `approval_state`
- **`milestone_redesing_helper/`** (misspelled, at the repo root) and **`doc/ui_design_mergerequest_helpers/`** are referenced nowhere. All three helper folders carry identical vendored React builds.
- **Broken screenshot references:** `doc/DESIGN-milestone-view.md` → `milestone-view-M4.png` and `doc/DESIGN-merge-request-view.md` → `merge-request-view-R4.png` don't exist, while `doc/ui_design_milestone.png` and `doc/ui_design_mergerequest.png` are referenced nowhere.

---

## 4. UI elements

The shared detail host is `ui/detail.lua`. `open(kind, …)` (`:505`) builds one of two layouts:
- **split:** a new tab with a sticky header split, a spacer, a floating content window and an optional sidebar float (`:378-485`).
- **single:** a `vsplit` beside the dashboard. Only the repository detail view uses it.

| UI | Entry | Reached by | Window | Data needed | Fed by (capability → API) |
|---|---|---|---|---|---|
| Dashboard shell | `ui/dashboard.lua:300` `open`; body `ui/dashboard_body.lua:109` | `:Atlas pulls/issues/pipelines`, `:Atlas` picker, `:Atlas open .`, `<Tab>` | New tab, buf `Atlas`, ft `atlas` | `ui.state.line_map` | per domain below |
| Pulls dashboard | `pulls/ui/dashboard/init.lua:77` (`init`), `:136` (`activate`); `renderer.lua`, `providers.lua` | as above | dashboard | PR id, title, repo_full_name, comments_count, reviewers, state, detailed_merge_status, updated_on; unread count | `core.fetch_user` → `users.fetch_user`; `core.fetch_pullrequests` → `fetch_pullrequests`; `fetch_by_refs`; `notifications.fetch` |
| Issues dashboard | `issues/ui/dashboard/init.lua:109`; `controller.lua` (uses `core/pagination.run` :283) | as above | dashboard | key, type, story_points, duedate, project_path, parent; milestone groups | `core.fetch_user` → `users.get_user`; `fetch_issues` → `list_issues`; `fetch_milestones` → `milestones.list`; `fetch_by_refs`; `notifications.fetch` |
| Pipelines dashboard | `pipelines/ui/dashboard/init.lua:59`; `controller.lua:48` | as above | dashboard | id, key, project_path, status/state, ref, sha, user, created/started/finished, duration, web_url, stages | `core.fetch_pipelines` → `fetch_pipelines` (GraphQL) |
| Filter bar and completion | `ui/filter_bar.lua:67`, `ui/filter_completion.lua:88`, `ui/filter_query.lua` | `/`, `\` | text in the dashboard; edit float (`inline_field_edit`) | `filter_text`, unread count, members | `users.list_members` **called directly** (`me` is offered as a literal item) |
| Pull request detail | `pulls/ui/detail/init.lua:318` (`open`), `:297` (`select`); `renderer.lua:271`, `sidebar.lua`, `readiness.lua`, `closing_refs.lua`, `data.lua` | dashboard `i`, OPEN, issue `gp`, milestone MR tab `i`, diff `gP`, back from the pipeline view | split + sidebar + boxed header | `PullRequest` + details (description, assignees, labels, milestone, subscribed), diffstat, pipelines, reviewers/approvals, merge checks | `fetch_pullrequest` (GraphQL), `fetch_by_refs`, then `data.load_pr` (`data.lua:15`): `fetch_diffstat` → `changes.fetch_diff`, `pipelines.fetch`, `fetch_reviewers`, `fetch_merge_checks` → `checks.fetch` |
| ↳ Description tab | `tabs/overview/init.lua:290` | default tab | content float (markdown) | description, closing-issue cards | issues `core.fetch_by_refs` (cross-domain); edit via `fetch_description`, `update_description` |
| ↳ Activity tab | `tabs/conversation/init.lua` + `ui/detail_tabs/activity/*` | `<Tab>` | content float, dock composer float, inline composer | comments, threads, system activity, reactions | `comments.fetch_conversation` → `activity.fetch_activity` + `comments.fetch_conversation_comments`; writes via `comments.*`; `fetch_user`; `completion/author.for_pulls` |
| ↳ Changes tab | `tabs/changes/init.lua:96` (+ `model.lua`, `viewed.lua`) | `<Tab>` | content float | diffstat files, local viewed set | from `data.load_pr` |
| ↳ Commits tab | `tabs/commits/init.lua:121` (+ `model.lua`) | `<Tab>` | content float | commit sha, title, message, author, date | `core.fetch_commits` → `changes.fetch_commits` |
| ↳ Pipelines tab | `tabs/pipelines/init.lua:134`, `renderer.lua`, `pulls/ui/pipelines/logs.lua` | `<Tab>` | content float | pipelines, jobs per pipeline, job logs | `pipelines.fetch`, `fetch_details`, `fetch_job_log` |
| Issue detail | `issues/ui/detail/init.lua:359` (`open`), `:369` (`open_ref`), `:313` (`select`); `renderer.lua:545` | dashboard `i`, OPEN, PR closing-issue `<CR>`, milestone work item `i` | split + sidebar + boxed header | issue + details (description, assignees, labels, milestone), linked MRs, branches, start/due dates | `fetch_issue` (GraphQL), `fetch_linked_merge_requests`, `fetch_linked_branches`, `fetch_issue_dates`, `fetch_by_refs` |
| ↳ Description / Activity tabs | `tabs/overview/init.lua`, `tabs/conversation/init.lua` | | content float | description, tasks; discussions | `update_description`; `notes.list_conversation` (GraphQL) and `notes.*` |
| Milestone view | `issues/ui/detail/milestone/init.lua:126`; `renderer.lua` (tabs Description / Work items / Merge requests), `timeline.lua`, `state.lua` | dashboard `i` on a milestone row (project-scoped view), issue `gm` | split + sidebar + boxed header | milestone (title, dates, state, description, web_url), issues, MRs | `fetch_milestone` → `milestones.get`, `list_issues`, `list_merge_requests`, `update_*`, `set_state`. The renderer requires `wf_state` directly. |
| Repository detail (**unreachable**) | `pulls/ui/repo_detail/init.lua:230`; tabs Overview / Issues / Branches / Tags | none | single (vsplit) | project details + README, branches, tags, issues + statistics | `repository.*` → `repositories.*` |
| Pipeline detail | `pipelines/ui/detail/init.lua:127` (`open`), `:83` (`select`); `renderer.lua` (`render_header` :285 graph, `render_log` :395); `components/graph.lua`, `graph_layout.lua`, `log_view.lua`, `log_model.lua`; store `pipelines/pipeline_state.lua` (timers) | pipelines dashboard `i`, PR `gp`, PR Pipelines tab `<CR>` | split + boxed header (graph), log content float | pipeline, stage/group/job graph (status, retryable, cancelable, manual, playable), incremental trace | `detail.fetch_pipeline` (REST), `fetch_pipeline_graph` (GraphQL, **polled**), `fetch_job_trace` (Range, **polled**), action functions |
| Create form | `ui/create/init.lua:310`; `renderer.lua`, `state.lua`, `keymaps.lua`; domain logic in `pulls/create/gitlab/init.lua`, `issues/create/gitlab/init.lua` | `:Atlas create`, dashboard `c`, issue `gP` | split, `buftype=acwrite` | type, title, description, assignees, labels, reviewers, milestone, dates, branches, draft | **called directly:** `users.get_user`, `users.list_members`, `labels.list`, `milestones.list`, `milestones.create`, `issues.create_issue`, `fetch_issue_dates`, `update_issue_dates`, `pullrequests.create_pr`; local git (push, branches) |
| Notifications | `ui/notifications/init.lua:375` (`open`), `:440` (`refresh`); `renderer.lua`, `state.lua` | `N` | centered float | todos (id, title, subtitle, timestamp, icon, unread, url) | `notifications.fetch`, `mark_done` |
| Help popup | `ui/popups/help.lua:567,642` | `g?` / `gA` | bottom float, zindex 250 | the buffer's key registry | — |
| Info popup (**dead**) | `ui/popups/info.lua` | none | cursor float | | — |
| Live output | `ui/popups/live.lua` | `custom_actions` `ctx.output` | centered float | streamed text | local jobs only |
| Markdown editor | `ui/popups/editor/init.lua:189` | review body, suggestions, issue templates | 80%×80% float with preview | text | callers (`comments.*`, `reviews.*`) |
| Inline edit / inline field edit | `ui/inline_edit.lua`, `ui/inline_field_edit.lua:298` | descriptions; title / assignee / label / milestone / branch / date fields; filter | in-place / anchored float | completion items | `providers/gitlab/completion/{author,labels,milestones,users}.lua` (these wrap API calls and cache per instance) |
| Comment composer and dock | `ui/components/composer/session.lua:86`, `dock.lua` | Activity tabs | floats | | activity actions |
| Pickers | `ui/picker/init.lua` (`select` :66, `find` :75, `select_with_preview` :92, `search` :152); backends `atlas.lua`, `snacks.lua`, `fzf_lua.lua` (chosen by `ui.picker`, auto = snacks → fzf-lua → native) | commands, actions, branch / MR choice, find file | float (+ preview) | | callers (SRCH: `client.request` directly / `search_issues_picker`; REV: `fetch_pullrequests` + `fetch_pullrequest`) |
| Logs | `ui/logs.lua` | `:Atlas logs` | `botright 12split` | `core/logger` entries | — |
| Statusline | `ui/statusline.lua` (`new` :315, `attach` :451, `notify` :498) | dashboard / detail / diff windows; `core/notify.lua:22` | window-local `statusline` expression | hints, notices, spinner | — |
| Diff loading | `pulls/diff/ui/loading.lua` | each diff open | tab | progress | — |
| Diff session | `pulls/diff/init.lua` (`open_pr` :501, `open_pull_request` :419, `open_range` :464, `open_argument` :469); `session.lua`, `review.lua`, `comments.lua`, `position.lua` | `gd`, `:Atlas diff/review`, `:AtlasDiff`, `<CR>` in Changes/Commits | — | PR, diff refs, review threads, drafts, approvals, reviewers, user | `fetch_by_refs`; `core/git/checkout.lua` (local clone, git only); `reviews.fetch` (`comments.fetch_review_comments` + `fetch_metadata`); `fetch_user`; `fetch_commits` |
| ↳ Native AtlasDiff | `pulls/diff/atlas/init.lua:507`, `view.lua:461`, `explorer.lua`, `renderer.lua`, `git.lua`, `commits.lua` | `open_cmd = "AtlasDiff"` (default) | tab with splits | local git diff + threads | `comments.*`, `reviews.discard/submit/approve/request_changes` |
| ↳ Diffview / CodeDiff adapters | `pulls/diff/diffview/init.lua:499`, `pulls/diff/codediff/init.lua:605` | `open_cmd` | external plugin's tab | same | same |
| ↳ Review panel | `pulls/diff/ui/review_panel.lua:460,509,685` | `gR` | split below the diff | pending drafts, threads | session data → `comments.*` |
| ↳ Thread popup / inline overlays | `pulls/diff/ui/comments.lua:519`, `pulls/diff/comments.lua:849` | `gK` | float / virtual lines | threads | `comments.*` |

**Suggested port order.** Each step can be done on its own, and later steps reuse earlier resources.

| Step | UI | API resources it needs |
|---|---|---|
| 1 | Notifications | `todos` |
| 2 | Pipelines dashboard + pipeline detail | `pipelines`, `jobs` |
| 3 | Issues dashboard + milestone view | `issues`, `milestones`, `users` |
| 4 | Issue detail | `notes`, `work_items`, `branches`, `labels` |
| 5 | Pull requests dashboard + detail | `merge_requests`, `mr_checks`, `mr_changes`, `mr_pipelines`, `mr_notes` |
| 6 | Create form | creates across the resources above |
| 7 | Diff / review | `mr_discussions`, `drafts`, `reviews` |

---

## 5. Smells

### 5.1 Blocking calls

| Where | What | Impact |
|---|---|---|
| — | No `vim.wait`, `jobwait`, busy loops, or `:wait()` on HTTP; all HTTP is async via `jobstart` | — |
| `core/git/init.lua:24` `run_sync` = `vim.system(...):wait()` | Used by `repo_root`, `current_branch`, `remote_url`, `local_repository`, `default_branch`, `list_*_branches`, `is_inside_work_tree`, … | Blocks the UI thread |
| `providers/gitlab/views_helper.lua:16,40` | `git.local_repository()` runs on **every** `views()` / `current_repo_project()` call: dashboard loads and view switches (`issues/ui/dashboard/controller.lua:377,391`, `pulls/…:344,383`, `pipelines/…:108`, `pipelines/ui/dashboard/init.lua:82`) and filter completion (`ui/filter_completion.lua:45`) | A synchronous `git remote get-url` on the hot path |
| `issues/…/actions/registry.lua:555-559`, `pulls/create/gitlab/init.lua:274-287,395-413`, `commands/open/init.lua:118,131`, `commands/review.lua:23` | Synchronous git calls | Shorter stalls, on user action |
| `core/cache.lua` (disk cache) | `globpath`, `readfile`, `writefile`, `sha256` synchronously on every get and set. `clear_prefix` reads and decodes **every** cache file and runs after each issue update or create (`issues.lua:80,495`). `prune_expired` globs the directory every 300 s. | Grows with the size of the cache |
| `ui/shared/utils.lua:261` | `vim.fn.system("git describe")` in `get_version` | Dead (§3.3) |
| Many API functions | Call `on_done` **synchronously** on a cache hit or validation error, but asynchronously otherwise (e.g. `issues.lua:153-157`, `pullrequests.lua:125-129`, `changes.lua:21` vs `comments.lua:178`) | Callers can't assume the callback order |

### 5.2 Missing or partial pagination

All entries are **intent unconfirmed**. Today's numbers become explicit defaults in the design.

| Endpoint | Current limit | File:line |
|---|---|---|
| Issue related MRs | 20 (GitLab default, no `per_page`) | `issues.lua:548` |
| Labels (×2), active milestones (×2), members (×3) | 100 | `labels.lua:10`, `pulls/labels.lua:16`, `milestones.lua:41`, `pulls/milestones.lua:19`, `users.lua:47` (×2), `pullrequests.lua:485` |
| Repository branches (×3) | 100; the related-branches filter misses matches beyond that | `issues.lua:594`, `pullrequests.lua:384`, `repositories.lua:158` |
| Milestone issues / MRs | 100 | `milestones.lua:91,129` |
| MR commits | 100 | `changes.lua:37` |
| Issues list | `max_results` (default 50/100), `is_last` always true; the dashboard's `core/pagination.run` loop therefore stops after one page | `issues.lua:160`, `issues/ui/dashboard/controller.lua:283` |
| MR list | `pagelen` (≤100) per state | `pullrequests.lua:132` |
| Todos | `per_page=N` | `notifications.lua:76` |
| Issue search / project search | 30 / 20 | `issues.lua:844`, `pulls registry:582` |
| GraphQL `first:N` with no cursor | assignees, labels, reviewers, approvedBy (100), pipelines (50), stages (20/100), MR iids (100), issue discussions (none = server default) | `issues.lua`, `notes.lua:70`, `pullrequests.lua:183,242`, `reviews.lua:515`, `pipelines.lua:174`, `pulls/…/api/pipelines.lua:90` |
| `client.fetch_all_pages` | Stops when a page has fewer than **100** items, even if the caller passed a different `per_page`; ignores the `X-Next-Page` and `Link` headers (curl doesn't capture headers) | `client.lua:272-314` |

### 5.3 Encoding of project paths and other URL parts

| Item | Status |
|---|---|
| Project path on REST | **Always** `enc()`'d (consistent) |
| Project path on GraphQL | Raw `fullPath` variable (correct) |
| Repository README fetch | Numeric id (inconsistent) |
| Raw (not encoded) | todos `state` (`notifications.lua:73`), repo issues `state` (`repositories.lua:228`), `build_query` **keys** (`issues.lua:103,107`, `pullrequests.lua:58,62`, so user `extra_params` keys go out raw), issue `discussion_id` / `note_id` (`notes.lua:196,220-230`) where the pulls side does encode them (`comments.lua:496,546,650`), todo id (`notifications.lua:96`), draft id (`reviews.lua:352`) |
| Lists in `build_query` | A Lua list `labels` becomes repeated `labels=` params; GitLab documents a comma-separated string. Behavior unconfirmed. |
| Host matching | The port stays in the host (`url.lua:28`), so `ssh://git@host:2222/…` never resolves |
| Relative URL root | The `web_url` regex in the pulls mapper and `base_url() .. webPath` in the issues mapper produce wrong paths or URLs under a relative root |

### 5.4 Duplicated request code

| # | What | Where |
|---|---|---|
| 1 | Labels list | `issues/…/labels.lua:10` ≡ `pulls/…/labels.lua:15-31` |
| 2 | Active milestones | `issues/…/milestones.lua:41` ≈ `pulls/…/milestones.lua:17-31` (different mappers) |
| 3 | Project members | `issues/…/users.lua:36-67` ≈ `pulls/…/users.lua:36-65` ≈ `pullrequests.lua:482` |
| 4 | `/user` | `issues/…/users.lua:9-30` and `pulls/…/users.lua:9-30`, cached twice under different keys with different mappers |
| 5 | Repository branches | three implementations with three caches (`issues.lua:584-609` with 2 keys, `pullrequests.lua:377-401` uncached, `repositories.lua:141-184`) |
| 6 | Pipeline jobs | `pipelines.lua:216-260` ≈ `pulls/…/api/pipelines.lua:200-234` |
| 7 | Job trace | ×3 (`pipelines.lua:277,531`, `pulls/…/api/pipelines.lua:251`) |
| 8 | Pipeline status mapping | `PIPELINE_STATES`, `to_pipeline_state`, `web_url` identical in `pipelines.lua:6-19,76-94` and `pulls/…/api/pipelines.lua:7-20,46-64`; MR pipelines GraphQL overlaps (`pipelines.lua:59-74` vs `pulls/…/api/pipelines.lua:22-44`) |
| 9 | `build_query` | `issues.lua:85-111` ≈ `pullrequests.lua:52-70` |
| 10 | Subscribe toggle | `issues registry:632-657` ≈ `pulls registry:636-686` |
| 11 | Label add/remove payload and the "`{0}` clears" convention | `issues.lua:371-385,429-437`, `pullrequests.lua:407-420,553-573` |
| 12 | Assignee, label and milestone inline-edit flows | issues registry `:154-485` vs pulls registry `:159-479` |
| 13 | `project_iid` helper | ×4 (`pullrequests.lua:264`, `comments.lua:46`, `changes.lua:9`, `reviews.lua:54`), inlined ×3 more (`activity.lua:62`, `checks.lua:181`, `pulls/…/api/pipelines.lua:72`) |
| 14 | GID-tail helpers | ×5 |
| 15 | User, milestone and reaction mappers | User ×5, milestone ×3, reaction counts ×2 |
| 16 | Project path from `references.full` / `web_url` | ×3 |
| 17 | GraphQL cursor loops and cancel-handle boilerplate | Cursor loops: `comments.lua:197-294`, `reviews.lua:167-250`. `{cancelled, current}` wrappers: `client.lua:306`, `comments.lua:425`, `reviews.lua:377,475`, `pipelines.lua:505`, `checks.lua:263`. `core/requests.lua` (a request scope) already exists but the API modules don't use it. |
| 18 | GraphQL "retry without a field" fallback | `checks.lua:255-261`, `pipelines.lua:482-504` |
| 19 | `views()` / `search_query()` | ×3 provider `init.lua` files |
| 20 | Cache-invalidation lists | Overlap across `comments.lua:165`, `reviews.lua:67`, `pullrequests.lua:293` |

### 5.5 Global and shared mutable state

| State | Where | Problem |
|---|---|---|
| Memory cache | `core/memory_cache.lua:8-10`: one `store`/`order` for every domain, **20 entries, first-in-first-out** (`get` doesn't refresh the position) | One MR detail view uses about 11 keys (details, reviewers, review_metadata, review-comments, conversation-comments, activity, commits, diff, pipelines, merge-checks, refs), so entries are evicted constantly |
| Disk cache prune clock | `core/cache.lua:11` `last_prune_at` | |
| `merge_request_field` | `pipelines/…/api/pipelines.lua:349`, flipped permanently at `:489` | Process-wide feature probe |
| Provider modules | `providers/init.lua:39,77-82`: `M.load` writes `id`, `name`, `icon`, `hl_group` onto the required module table | Mutates a shared module |
| Action registries | `ACTIONS` filled at load (`issues registry:39`, `pulls registry:55`); the issues registry writes `detail_state.editing_field` (`:27`) | |
| Cached objects mutated in place | Memory-cache values are returned by reference, so these writes change the cache: `issue.title`, `issue.is_subscribed`, `details.is_subscribed`, `pr.destination.branch`, `pr.remove_source_branch`, `pr.title`, `pr.state`, `pr.diff_refs` (`pullrequests.lua:369,440,464`, `comments.lua:416`, `reviews.lua:315`, both registries) | |
| Completion providers | Cache `{}` for their lifetime after a fetch error (`completion/labels.lua:36`, `milestones.lua:37`) | |
| Credentials | Read from the global `config.options` on every request; there is no client instance, so only one GitLab host is possible | |

### 5.6 Inconsistent error handling

- **Callback shapes differ.** `(nil, err)`, `(false, err)`, `({}, err)`, `({}, nil, true, err)` (`fetch_pipelines`) and `(ok, err)` are all in use. Validation errors are sometimes synchronous and sometimes `vim.schedule`d.
- **Errors are plain strings.** A non-2xx becomes `"HTTP <code>: <raw body>"` (`http.lua:135-143`) with no structured status, so callers can't tell 401 from 404 from 409 or a network failure. `request_text` drops the body (`"HTTP %d"`).
- **`__http_status` is injected into every decoded table**, including lists (`http.lua:159`). That makes `vim.islist` false, so the "error object" check (`client.lua:190`) runs on every list. A 2xx object with a top-level `message` or `error` field would be misread as a failure.
- **GraphQL** fails the whole call if `errors[]` is non-empty, even when `data` came back (`client.lua:258`). `json_encode` isn't wrapped in `pcall` in `graphql` (`:250`), unlike `request`.
- **Errors swallowed:** README fetch (`repositories.lua:123`), `issues_statistics` (`:246`).
- **Over-broad fallback:** `checks.lua:255` retries with the fallback query on **any** error, including auth and network errors.
- **UI concerns in the API layer:** the registries call `notify.error` themselves (`issues registry:639`, `pulls registry:650`).
- **Crash risk:** `result.notes[1]` is indexed without checking `notes` (`comments.lua:379,505`).
- **Edge case:** subscribing when already subscribed returns 304, which surfaces as the error "HTTP 304".

### 5.7 Transport and security

- **No `--max-time` or `--connect-timeout`.** A request can hang forever, and so can the UI's spinner.
- **The token and request body are passed on the curl command line.** They are visible in `ps`, and bodies above about 128 KB (Linux `MAX_ARG_STRLEN`) fail.
- **`request_text` uses `-L`.** curl sends custom `-H` headers to redirect targets, so `PRIVATE-TOKEN` can leak to object storage on job-trace or raw-file redirects.
- **Every request sends `Content-Type: application/json`**, including GETs.

### 5.8 Stale caches after writes

| Write | Cache left stale |
|---|---|
| Any MR write (`update`, `merge`, `create_pr`) | MR list disk cache (300 s) |
| Any MR write | `refs` and `merge-checks` memory caches |
| `create_branch` | `project-branches` key |
| `mark_done` | Todos list (60 s) |
| Pipeline / job actions | Pipeline list |
| Subscribe toggles | Rely on mutating the cached object in place |
| `/user` on disk | Never invalidated, but expires by TTL |

---

## 6. Proposed API layer design

The working name below is **`glapi`** (placeholder; the real plugin name is an open question). Goal: everything the UI reaches today keeps working, the unwired endpoints stay available, and the smells in §5 are fixed. Each fix is listed in §6.8.

### 6.1 Module layout

```
lua/glapi/
  init.lua            -- glapi.new(opts) -> Client ; glapi.setup(opts) (default client, for atlas)
  http.lua            -- transport (curl via vim.system), no GitLab knowledge
  client.lua          -- Client: auth, base URL, rest/graphql/paginate, request scope, logging hooks
  errors.lua          -- structured error type
  path.lua            -- path and query builders (always encode)
  cache/
    init.lua          -- cache facade: get/set/tag/invalidate, TTL, disable when ttl<=0
    memory.lua        -- LRU (size per client)
    disk.lua          -- async (vim.uv fs_*) JSON store, same on-disk layout as today
  async.lua           -- coroutine wrappers: glapi.async.run, await, wrap
  resolve.lua         -- GitLab URL -> {entity, project_path, iid} (from providers/url.lua + resolve.lua)
  types/              -- the domain types (moved from pulls/issues/pipelines types.lua)
  mappers/            -- user, label, milestone, issue, merge_request, note, pipeline, job, todo, …
  resources/
    users.lua         -- current_user, project_members
    projects.lua      -- get (statistics), search, file_raw (README)
    repository.lua    -- branches.list/create/delete, tags.list
    labels.lua        -- list
    milestones.lua    -- list, get, issues, merge_requests, create, update, set_state
    issues.lua        -- list, by_iids, get_details, assignees, labels, create, update, related_mrs,
                      -- related_branches, subscribe/unsubscribe, search
    work_items.lua    -- dates.get, dates.update (GraphQL)
    issue_notes.lua   -- discussions (GraphQL), add, reply, edit, delete, set_resolved (GraphQL)
    merge_requests.lua-- list (project/group/global), by_iids, details, description, update, merge,
                      -- create, subscribe/unsubscribe, default_reviewers
    mr_changes.lua    -- commits, diff (+diffstat), versions
    mr_checks.lua     -- merge status (with schema fallback)
    mr_notes.lua      -- activity (REST notes), conversation (GraphQL cursor), discussions,
                      -- add/edit/delete/resolve, award_emoji
    mr_reviews.lua    -- metadata (GraphQL cursor), reviewers, drafts.list/discard, publish, approve
    pipelines.lua     -- list (project | MR), get, graph (GraphQL), jobs.list (paginated),
                      -- job.trace (full | Range), actions (retry/cancel pipeline; retry/cancel/play job)
    todos.lua         -- list, mark_done
```

atlas keeps `core/git` (local remote lookup, clone, checkout) and all UI. Resolving a **local** repository becomes: atlas gets the remote URL from `core/git`, then calls `glapi.resolve.remote(url)`.

### 6.2 Transport (`http.lua`)

- `vim.system({ "curl", "--config", "-" }, { stdin = cfg })`. The URL, method, headers, **token** and timeouts go in the stdin config, and the body goes through `--data-binary @-` or a temp file. Nothing sensitive appears on the command line, and there is no size limit.
- `--connect-timeout` and `--max-time` come from options (defaults e.g. 10 s / 60 s; job traces may set longer).
- Response headers are captured (`-D` to a pipe or temp file) so `X-Next-Page`, `X-Total`, `Link`, `Retry-After` and `Location` are available.
- **Redirects are followed manually.** If the target host differs from `base_url`'s host, the request is re-issued **without** `PRIVATE-TOKEN`.
- It returns `{ status, headers, body }` or an `Error`. Every callback is delivered through `vim.schedule`, **never synchronously**, including on cache hits.
- Handle: `{ cancel = fn }`. `core/requests.lua` (the request scope) moves here unchanged in behavior.

### 6.3 Errors (`errors.lua`)

```lua
---@class glapi.Error
---@field kind "config"|"network"|"timeout"|"http"|"auth"|"not_found"|"conflict"|"decode"|"graphql"|"validation"|"cancelled"
---@field status integer|nil      -- HTTP status
---@field message string          -- human readable, same text as today where possible
---@field body string|nil         -- raw body (http), or GraphQL errors table
---@field partial any|nil         -- GraphQL data returned alongside errors
```

`tostring(err)` yields today's strings (`"HTTP 404: …"`, `"Missing GitLab credentials in config"`), so the atlas adapters can keep passing strings to the UI until each piece is ported.

### 6.4 Client (`client.lua`)

```lua
local client = glapi.new({
  base_url = "https://gitlab.example.com", -- relative roots supported
  token = "...",                           -- or token = function() return ... end
  cache_ttl = 300,                         -- <= 0 disables caching (as today)
  cache = { memory_size = 200, disk_dir = vim.fn.stdpath("cache") .. "/atlas/cache" },
  timeout = { connect = 10, total = 60 },
  logger = function(level, msg, fields) end, -- atlas passes core/logger
})

client:rest(method, path, { query = {}, body = {}, headers = {}, raw = false }, cb) -> handle
client:graphql(query, variables, { paginate = "project.mergeRequest.notes" }, cb) -> handle
client:paginate(path, { query = {}, per_page = 100, limit = math.huge }, cb, on_page?) -> handle
client:graphql_paginate(query, vars, connection_path, { limit }, cb) -> handle
```

- `paginate` follows `X-Next-Page` (and falls back to `Link`). It stops at `limit`. It replaces `fetch_all_pages`, and the "fewer than 100 items" heuristic is gone.
- `graphql_paginate` replaces the two hand-written cursor loops.
- The non-list "`message`/`error` field means failure" check is applied only to non-2xx bodies, and `__http_status` is no longer injected. A response's status is exposed via `opts.raw = true`.

### 6.5 Paths, queries and caching

- `path.project(id_or_path)`: integers pass through and strings are always encoded. `path.seg(x)` encodes any other segment (discussion/note/draft/todo ids, branch names, file paths).
- `path.query(tbl)`: keys **and** values encoded, keys sorted (stable cache keys). Arrays default to today's repeated-key behavior. A per-parameter `{ join = "," }` is available so the open question on `labels` can be settled without changing the API.
- **Cache facade:**
  - `cache:get(key)`, `cache:set(key, value, { ttl, tags })`, `cache:invalidate_tag(tag)`.
  - Tags are things like `project:<p>`, `mr:<p>!<iid>`, `issue:<p>#<iid>`, `mr-list:<p>`, `issue-list:<p>`, `pipelines:<p>`, `todos`, `user:me`.
  - Every write declares the tags it invalidates, which replaces the hand-maintained key lists (§5.4 #20, §5.8).
  - Values are **deep-copied** on `get`, so callers can't mutate cached data (§5.5).
- **Memory:** a real LRU sized per client. **Disk:** the same file format, async I/O. `clear_prefix` is replaced by a tag index, so there is no scan of every file.
- Each resource keeps today's cache tier (memory vs disk), TTL and `force_load`/`force_refresh` semantics. Key strings may change, which is invisible to the UI. `:Atlas clear cache` calls `client.cache:clear()`.

### 6.6 Resources — calling convention

Every resource function has the form:

```lua
---@param client glapi.Client      -- or methods on client.issues, client.merge_requests, ...
---@param args table               -- named arguments: { project = "group/repo", iid = 12, ... }
---@param opts? { force_load?: boolean, limit?: integer, per_page?: integer, raw?: boolean }
---@param cb fun(result: any, err: glapi.Error|nil)
---@return { cancel: fun() }
client.issues.list(args, opts, cb)
```

- `result` is the **mapped domain object** (today's `Issue`, `PullRequest`, `PipelineGraph`, …). `opts.raw = true` returns the decoded JSON instead.
- Failure is always `cb(nil, err)`. A mutation that returns nothing calls `cb(true, nil)`. Each atlas adapter keeps today's per-function shape (`(false, err)`, `({}, err)`, `({}, nil, true, err)`) so nothing in the UI changes until it is ported.
- Limits are explicit. Today's values become each function's defaults: related MRs 20, members/labels/milestones/branches/commits 100, issue search 30, project search 20, pipelines `first` 50, and so on.

**Coroutine wrappers** (`async.lua`) are generated from the same table:

```lua
glapi.async.run(function()
  local mr, err = client.async.merge_requests.details({ project = p, iid = 3 })
  local checks = client.async.mr_checks.get({ project = p, iid = 3 })
end, on_finish)  -- cancelling the run cancels the request in flight
```

`client.async.<resource>.<fn>` is a `wrap` that suspends the running coroutine and resumes it with `(result, err)`. Outside a coroutine it raises a clear error instead of blocking (no `vim.wait`).

### 6.7 Function catalogue (today → glapi)

Function names are proposals. "unwired" means no UI reaches it today; it stays available.

| Today (file → function) | glapi |
|---|---|
| issues `users.get_user`, pulls `users.fetch_user` | `users.current` (one cache entry, two mappers kept until the types are merged) |
| issues/pulls `users.list_members`, `pullrequests.fetch_default_reviewers` (members part) | `users.project_members({project, query?})` |
| issues/pulls `labels.list` | `labels.list({project})` |
| issues/pulls `milestones.list` | `milestones.list({project, state="active"})` |
| `milestones.get`, `list_issues`, `list_merge_requests`, `create`, `update_*`, `set_state` | `milestones.get`, `issues`, `merge_requests`, `create`, `update({fields})`, `set_state` |
| `issues.list_issues`, `fetch_by_refs` | `issues.list({view, filter})`, `issues.by_iids({project, iids})` |
| `issues.fetch_issue`, `get_assignees`, `fetch_issue_labels` | `issues.details`, `issues.assignees`, `issues.labels` (GraphQL) |
| `issues.update_*`, `set_state`, `update_labels`, `set_assignee_ids`, `set_milestone_id` | `issues.update({project, iid, fields})` + thin helpers |
| `issues.create_issue` | `issues.create` |
| `issues.fetch_related_merge_requests` | `issues.related_merge_requests({limit=20})` |
| `issues.fetch_related_branches`, `fetch_project_branches`, pulls `list_branches`, `repositories.fetch_branches` | `repository.branches({project, limit=100})` (+ `issues.related_branches` filter) |
| `issues.create_branch`, `repositories.delete_branch` (unwired) | `repository.create_branch`, `repository.delete_branch` |
| `issues.fetch_issue_dates`, `update_issue_dates` | `work_items.dates`, `work_items.update_dates` |
| `issues.search_issues_picker` | `issues.search({query, limit=30})` |
| `notes.list_conversation`, `add_comment`, `reply_comment`, `edit_comment`, `delete_comment`, `set_thread_resolved` | `issue_notes.discussions`, `add`, `reply`, `edit`, `delete`, `set_resolved` |
| issues/pulls registry `toggle_subscription` (unwired) | `issues.set_subscribed`, `merge_requests.set_subscribed` |
| `notifications.fetch`, `mark_done` (= `mark_read`) | `todos.list({state, per_page})`, `todos.mark_done({id})` |
| `pullrequests.fetch_pullrequests` | `merge_requests.list({scope=project\|group\|global, state, query, per_page})` |
| `pullrequests.fetch_by_refs`, `fetch_pullrequest`, `fetch_description` | `merge_requests.by_iids`, `details`, `description` |
| `pullrequests.update`-family, `merge`, `create_pr` | `merge_requests.update({fields})` (+ helpers), `merge`, `create` |
| `changes.fetch_commits`, `fetch_diff`, `fetch_diffstat`, versions lookup | `mr_changes.commits`, `diff`, `diffstat`, `latest_version` |
| `checks.fetch` | `mr_checks.get` |
| `activity.fetch_activity`, `comments.fetch_conversation_comments` | `mr_notes.activity`, `mr_notes.conversation` |
| `comments.fetch_review_comments` | `mr_notes.review_threads` (discussions + drafts) |
| `comments.add_comment`, `edit_comment`, `delete_comment`, `set_thread_resolved` | `mr_notes.add`, `edit`, `delete`, `set_resolved` |
| `comments.add_reaction` (unwired) | `mr_notes.award_emoji` |
| `reviews.fetch`, `fetch_reviewers`, `discard`, `submit`, `request_changes`, `approve` | `mr_reviews.get`, `reviewers`, `discard_drafts`, `publish({state})`, `approve` |
| pipelines `fetch_pipelines`, pulls pipelines `fetch` | `pipelines.list({project \| mr})` |
| pipelines `fetch_pipeline`, `fetch_pipeline_graph` | `pipelines.get`, `pipelines.graph` |
| pipelines `fetch_pipeline_details` (unwired), pulls `fetch_details` | `pipelines.jobs` (paginated) |
| pipelines `fetch_job_log` (unwired), pulls `fetch_job_log`, `fetch_job_trace` | `jobs.trace({offset?})` |
| pipelines `retry_pipeline`, `cancel_pipeline`, `retry_job`, `cancel_job`, `play_job`; pulls `retry`, `cancel`, `retry_job`, `cancel_job` (unwired) | `pipelines.retry`, `cancel`; `jobs.retry`, `cancel`, `play` |
| `repositories.fetch_detail` (unwired) | `projects.get({statistics=true})` + `projects.file_raw({path, ref})` |
| `repositories.fetch_tags`, `fetch_issues` (unwired) | `repository.tags`, `issues.list` + `issues.statistics` |
| pulls registry `search` | `projects.search({query, limit=20})` |
| `providers/url.lua` + `providers/gitlab/resolve.lua` | `resolve.url`, `resolve.remote` |

### 6.8 Behavior deviations from today

These are intentional fixes. Each must be called out in the extraction PR.

| # | Today | glapi |
|---|---|---|
| 1 | No curl timeout | Connect and total timeouts (configurable) |
| 2 | Token and body on the command line | Passed via stdin config |
| 3 | `PRIVATE-TOKEN` forwarded on `-L` redirects | Manual redirect handling; token dropped for foreign hosts |
| 4 | String errors | `glapi.Error` (stringifies to today's text) |
| 5 | Callbacks sometimes synchronous | Always scheduled |
| 6 | `fetch_all_pages` stops on fewer than 100 items | Header-driven pagination; same default limits |
| 7 | Unencoded state, ids and query keys | Everything encoded |
| 8 | MR list, refs, merge-checks, todos, pipeline list, project branches stale after writes | Tag invalidation clears them |
| 9 | Cached objects mutated by callers | Deep copy on read; the UI updates its own state |
| 10 | 20-entry FIFO memory cache shared by all domains | Per-client LRU (default 200) |
| 11 | Sync disk I/O; `clear_prefix` scans every file | Async I/O + tag index |
| 12 | `checks` falls back on any error | Falls back only on a GraphQL schema/field error |
| 13 | GraphQL `errors[]` with `data` → hard failure | Same failure, but `err.partial` carries `data` (callers may opt in) |
| 14 | `notes[1]` nil index can throw | Nil-safe, returns a validation error |
| 15 | Subscribe on an already-subscribed item → "HTTP 304" error | 304 treated as success, no change |
| 16 | README and `issues_statistics` errors swallowed | Returned in `err` (the adapter keeps today's UI behavior of showing no README) |
| 17 | The `merge_request_field` probe is module-global | Per client |
| 18 | Port in the host breaks remote resolution | Host compared without the port |
| 19 | Relative-root `web_url` regex and doubled `base_url .. webPath` | Path derived from `references.full` / `fullPath`; URLs built by one helper |
| 20 | Every request sends `Content-Type` | Only when there is a body |

Behavior that stays the same: endpoints, default limits, cache tiers and TTLs, `cache_ttl <= 0` disables caching, mapped field names, and the GraphQL `mergeRequest` field fallback for pipelines.

### 6.9 Migration path

1. **Create the glapi plugin** with transport, client, cache, path and resolve, plus tests. The existing specs `spec/providers/gitlab/client_spec.lua`, `mapper_spec.lua`, `checks_spec.lua`, `pullrequests_update_description_spec.lua`, `wf_state_spec.lua`, `spec/pipelines/gitlab_api_spec.lua` and `spec/providers/resolve_spec.lua` move with it.
2. **Add the resources one domain at a time.** Each of today's `lua/atlas/**/providers/gitlab/api/*.lua` files becomes a **thin adapter** that calls glapi and converts errors and callback shapes back to today's contract. The capability tables and the UI stay untouched.
3. **Route the bypasses** (`ui/filter_completion.lua`, `ui/create/init.lua`, both `create/gitlab` modules, the registries' `client.request` calls) through provider capabilities backed by glapi.
4. **Wire the unwired features** if wanted: add the PR pipeline actions to `capabilities.pipelines`, which fixes `gR`/`gX`.
5. **Port the UI piece by piece** (§4 order). As each view moves, its adapter can be deleted and the view can use glapi's error type directly.
6. **Delete** `core/http.lua`, `providers/gitlab/client.lua`, `core/cache.lua` and `core/memory_cache.lua` once no adapter remains.

### 6.10 Open questions for the maintainer

1. What should the new plugin be called, and should atlas depend on it as a required dependency or vendor it?
2. `labels` filter on list endpoints: keep repeated `labels=` params, or switch to GitLab's comma-separated form?
3. Are the current limits intended?
   - Related MRs at 20.
   - The 100-item caps (members, labels, branches, commits, milestone items).
   - Issues list `max_results` with no further pages.
   - GraphQL `first:50` pipelines.
4. Should `issues.with_relationships` and `pulls.repo_config.settings[*].pr_template` be implemented in glapi, or removed from the config and docs?
5. Should the contract features GitLab never provides (`start_review`, `edit_review`, `set_file_reviewed`, `fetch_review_context`, `tasks`, issues `refresh`) stay in the provider contracts for a future second provider, or be removed?
6. Should the repository detail view, subscribe toggles and reactions get key bindings (wired), or stay unwired?
7. Should `/merge_requests/:iid/changes` (deprecated by GitLab) move to `/diffs` now, which changes the paging shape, or later?
8. Should the token come only from config, or also from an env var or a function (supported by the design, unused today)?
