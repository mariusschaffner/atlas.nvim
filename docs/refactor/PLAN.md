# Plan: write `docs/refactor/INVENTORY.md` (docs only; no code changes)

_Status: executed — see [INVENTORY.md](INVENTORY.md)._

## Context
atlas.nvim (~54k lines Lua) is a GitLab Neovim plugin whose API layer is spread across
`lua/atlas/{issues,pulls,pipelines}/providers/gitlab/api/*.lua`, `lua/atlas/providers/gitlab/*`,
the action registries and a few UI modules. The user wants to extract the API layer into a new
standalone plugin and later port the UI piece by piece. This session produces only an inventory
and a design proposal. **Only `docs/refactor/INVENTORY.md` and `docs/refactor/PLAN.md` (this plan)
are created; no existing file is changed.**

User decisions (from Q&A, recorded in the doc's "Decisions" header):
- Boundary: new plugin = transport + endpoints + pagination + caching **+ mappers** (it returns
  the same domain objects as today). `core/git` (clone/checkout/remote) stays in atlas.
- Async: callback API `fn(args, cb(result, err)) -> {cancel}` **and** coroutine wrappers from day one.
- Test-only references count as dead, confidence `likely`.
- Truncation/missing pagination: flag as a smell, "intent unconfirmed"; design keeps today's
  limits as explicit, overridable parameters.
- Unreachable-but-implemented endpoints (repo detail, PR-tab pipeline retry/cancel, add_reaction):
  keep them in the design, marked "unwired".
- Bug-like behavior: flag in Smells; design fixes it and lists each deviation from today explicitly.

Research was gathered read-only with three parallel code sweeps (API calls; entry points + UI; dead code).
Key claims were spot-checked against the source (PR pipelines capability missing retry/cancel at
`pulls/providers/gitlab/init.lua:279-284`; `repo_detail.open` has no caller; `show_*_details`,
`multi_select`, `pr_template` unreferenced; non-2xx turned into errors before JSON parsing in `core/http.lua:135`).

## Document structure (`docs/refactor/INVENTORY.md`)
0. **Header**: purpose, scope, commit SHA inventoried (`ac6dd51`), decisions above, confidence legend,
   conventions (paths relative to `lua/atlas/`, `enc()` = `client.url_encode`).
1. **Entry points**
   - User commands: `:Atlas` + 10 subcommands (`commands/init.lua`), `:AtlasDiff`, buffer-local
     `:AtlasCreateQuit`; note commands exist only after `setup()` (`plugin/atlas.lua` only sets a guard).
   - Keymaps: how `config.keymaps.*` resolves (`core/keymaps.lua` from_config/item/validate) and binds
     (`ui/popups/help.lua` register); per-view tables (dashboard general/pulls/issues/pipelines, PR detail +
     tabs, issue detail + tabs, milestone, pipeline detail, create, diff/review overlay, native diff,
     review panel, thread popup, notifications, picker, logs) with config key → default → handler →
     provider/API call. Hardcoded keys listed separately.
   - Autocmds/augroups table (≈35 entries) + emitted `User` events (`core/events.lua`).
   - Public modules: `atlas.setup/open`, `atlas.health`, `atlas.ui.statusline.current` (used via `v:lua`),
     `foldtext` via `v:lua`; global side effect `laststatus=3`. Docs-vs-defaults keymap mismatch table.
2. **API usage**
   - Transport: URL = `base_url (trailing / stripped) .. "/api/v4" .. endpoint` / `"/api/graphql"`;
     token = `PRIVATE-TOKEN` header from `providers.gitlab.token`; curl flags; error pipeline.
   - Full call-site tables per file (file:line | function | method | path/GraphQL op | encoding |
     pagination | cache key/TTL | error style) — ~75 call sites across issues, notes, milestones,
     labels, users, notifications(todos), pipelines, pullrequests, comments, changes, reviews,
     repositories, activity, checks, pulls pipelines, both action registries.
   - Reachability column: which entry points reach each call (command / keymap / view load), derived by
     joining the provider-method map with the keymap & UI tables; unreachable ones marked "unwired".
   - Provider capability → API function map; direct bypasses of the provider (create modules,
     filter_completion, create/init `get_user`, milestone renderer `wf_state`, registries calling `client.request`).
   - Project-path resolution (`providers/url.lua`, `providers/gitlab/resolve.lua`, `views_helper`,
     mappers' `references.full`/`web_url` regex) and web-URL building inconsistencies.
3. **Dead code candidates** (name | file:line | confidence | evidence)
   - Modules: `ui/components/{box,header,navbar}.lua` (certain); `ui/popups/info.lua`,
     `pulls/ui/dashboard/popup.lua`, `issues/ui/popup.lua`, `pulls/providers/gitlab/actions/pipelines.lua` (likely).
   - Unreachable view: `pulls/ui/repo_detail/*` + repositories API (likely; "unwired").
   - Functions with no callers (logger.logwarn, cache.delete, memory_cache.clear_prefix, git
     commit_range/commits_for_range/diff_stat/checkout_branch/checkout_new_branch, diff_parser.find_hunk,
     picker.multi_select, utils.get_version/format_datetime_short/encode_pretty_json, …) and test-only
     (`pipeline_state` selected_trace/active_timers → likely).
   - API functions reachable only via unused capability keys (add_reaction, pipelines fetch_pipeline_details/
     fetch_job_log, pulls pipelines retry/cancel*, `core.search_query`, `create_milestone`, `fetch_diff` key).
   - Contract fields guarded in UI but never provided by GitLab (start_review, edit_review,
     set_file_reviewed, fetch_review_context, tasks.*, issues core.refresh) → dead branches (likely/unsure).
   - Config: `pulls.repo_config.settings[*].pr_template` never read (certain, but documented);
     `issues.with_relationships` read but ignored; unbound keymap ids (toggle_subscription, copy_id,
     copy_url, review.add_task, issues.toggle_description_mode certain; comments.react,
     transition_issue, change_reporter, picker.toggle likely). `migrate_legacy` live (TODO 0.8.0).
   - Non-Lua: `.http` scratch files, unreferenced design helper folders, broken screenshot refs.
4. **UI elements**: one row per view/window/picker (entry fn, how reached, window type, data fields,
   feeding provider → API functions), incl. dashboards, filter bar, PR detail + 5 tabs, issue detail + tabs,
   milestone view, repo detail (unreachable), pipeline detail (graph+log, polling store), create form,
   notifications float, help/info/live/editor popups, inline edits, composer, pickers (3 backends), logs,
   statusline, diff loading, diff session + native/Diffview/CodeDiff adapters, review panel, thread popup.
   Plus a "port order" hint: which UI pieces depend on which API modules.
5. **Smells** (each with file:line, impact, and "intent unconfirmed" where it is a limit)
   - Blocking: no `vim.wait`; but `vim.system():wait()` in `core/git` reached from every `views()` /
     `current_repo_project()` (main thread), sync disk-cache I/O incl. `clear_prefix` decoding every file,
     `vim.fn.system` in `get_version` (dead).
   - Pagination: single-page truncation list (related MRs at 20, labels/milestones/members/branches/
     commits/milestone issues & MRs at 100, issues list = max_results, GraphQL first:N without cursors,
     `fetch_all_pages` stops on `#page < 100` regardless of per_page; issues dashboard pagination
     loop always single page).
   - Encoding: project path encoded consistently via `enc()` for REST; GraphQL uses raw fullPath (OK);
     unencoded: todos `state`, repositories `state`, `build_query` keys, issue discussion/note ids,
     todo id, draft id; labels list encoded as repeated params; host-with-port and relative-root issues.
   - Duplication: the 20-item list (labels, milestones, members×3, `/user`×2, branches×3, jobs×2,
     trace×3, pipeline state mapping, build_query×2, subscribe×2, inline-edit flows, id helpers,
     mappers, cursor loops, cancel boilerplate, GraphQL fallback, views()).
   - Global state: shared 20-entry FIFO memory cache, `merge_request_field` flag, provider module
     mutation in `providers.load`, cached objects mutated in place, completion caching `{}` on error.
   - Error handling: non-2xx → `"HTTP n: <body>"` string; `__http_status` injected into lists;
     GraphQL any-error fails; sync vs scheduled callbacks; `on_done(false, err)` vs `(nil, err)` vs
     `({}, err)` vs `({}, nil, true, err)`; swallowed errors (README, issues_statistics); notify from
     API layer; `checks` retry on any error; `notes[1]` nil index; 304 on subscribe.
   - Transport/security: no timeouts; token and body on argv; `-L` forwards PRIVATE-TOKEN to redirect hosts.
   - Stale caches after writes (list of each).
6. **Proposed API layer design** (new plugin; placeholder name `gitlab.nvim-api`/`<glapi>` — name TBD by user)
   - Layers: `http` (curl via `vim.system`, timeouts, token+body via stdin/`--config -`, captured
     response headers, manual redirect follow without token to foreign hosts, structured error
     `{kind=network|timeout|auth|http|decode|graphql, status, message, body}`) → `client`
     (instance `Client.new{base_url, token, cache_ttl}`; `rest(method, path, {query, body})`,
     `graphql(query, vars, {paginate=path})`, `paginate(path, {limit, per_page})` using
     `X-Next-Page`/`Link`; request scope from current `core/requests.lua`) → `path`/`query` builders
     (always encode project ids and segments; GitLab array conventions) → `cache` (injectable store,
     memory LRU sized per client, async disk store, tag-based invalidation e.g. `mr:<path>!<iid>`,
     `cache_ttl<=0` disables as today) → `resources/*` (projects, merge_requests, mr_notes/discussions/
     drafts, mr_reviews, mr_changes, mr_checks, issues, issue_notes, work_items, milestones, labels,
     members/users, repository (branches/tags/files), pipelines/jobs, todos) each owning its mapper and
     returning today's domain types (`pulls/types.lua`, `issues/types.lua`, `pipelines/types.lua`) →
     `resolve` (GitLab URL → entity/project path; local git remote lookup stays in atlas).
   - Async: every resource fn has callback form; `<glapi>.async` wraps them for coroutines
     (`await(fn, ...)`, `run(fn)`), cancellation propagates.
   - Function catalogue: table mapping every current API/provider function → new resource function,
     preserving signatures' data, marking "unwired" ones.
   - Migration path: existing `*/providers/gitlab/api/*.lua` become thin adapters to the new plugin so
     capability tables and UI stay unchanged; then port UI module by module; remove bypasses.
   - "Behavior deviations" table: every fix vs today (cache invalidation, 304 handling, checks fallback
     only on schema errors, nil-safe notes, timeouts, redirect token, encoding fixes, error shape).
   - Open questions list for the user (e.g. plugin name, labels param convention, related-MR limit intent,
     whether `with_relationships`/`pr_template` should be implemented or removed).

## Execution steps
1. Re-verify each file:line in the three research reports with Grep/Read while writing (agent line
   numbers occasionally reference `commands/init.lua` with offsets; correct as found).
2. Compute the "reached by" column by joining tables A2b/B (UI report) with section 2 (API report).
3. Write `docs/refactor/INVENTORY.md` (create `docs/refactor/`). Markdown tables; no code edits.
3b. Copy this plan into the repo as `docs/refactor/PLAN.md` (user request).
4. Commit on `claude/nvim-gitlab-api-inventory-wp2unf` ("docs(refactor): add API layer inventory")
   and `git push -u origin claude/nvim-gitlab-api-inventory-wp2unf`. No PR.

## Verification
- `git status` / `git diff --stat HEAD~1` shows exactly two added files: `docs/refactor/INVENTORY.md`
  and `docs/refactor/PLAN.md`.
- Spot-check ≥15 random file:line citations in the doc with `sed -n`.
- Grep-check every REST path in `lua/` (`grep -rn '"/projects\|"/user\|"/todos\|"/issues\|"/merge_requests\|_GQL\|QUERY ='`)
  appears in section 2; every `nvim_create_user_command`/`nvim_create_autocmd` appears in section 1.
- Optional: render markdown tables (e.g. `npx markdownlint` not required) — just eyeball in the app.
