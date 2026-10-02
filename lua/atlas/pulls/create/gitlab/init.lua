-- Merge-request-specific half of the unified create view: owns the Source/
-- Target branch/Reviewers/Assignees/Labels/Draft field editors (writing
-- into the draft in `ui.create.state` instead of PUTing to GitLab) and the
-- final `create_pr` API call, including the push-the-local-branch-first
-- dance the old `pulls/create/pr.lua` form used to do. The generic shell
-- (`:w`/`:q`, Type/Title/Description editing) lives in `atlas.ui.create`.
local M = {}

local shell = require("atlas.ui.create")
local state = require("atlas.ui.create.state")
local notify = require("atlas.core.notify")
local logger = require("atlas.core.logger")
local git_branch = require("atlas.core.git")
local pullrequests_api = require("atlas.pulls.providers.gitlab.api.pullrequests")
local users_api = require("atlas.pulls.providers.gitlab.api.users")
local labels_api = require("atlas.pulls.providers.gitlab.api.labels")
local users_completion = require("atlas.providers.gitlab.completion.users")
local labels_completion = require("atlas.providers.gitlab.completion.labels")

---@type table<string, PullsAuthor>
local assignee_by_username = {}

---@type table<string, PullsAuthor>
local reviewer_by_username = {}

---@param root string
---@return AtlasFieldCompletionProvider
local function local_branches_completion(root)
	return {
		fetch = function(query, on_items)
			local q = vim.trim(query):lower()
			local items = {}
			for _, name in ipairs(git_branch.list_local_branches(root)) do
				if q == "" or name:lower():find(q, 1, true) == 1 then
					table.insert(items, { name = name })
				end
			end
			on_items(items)
		end,
	}
end

---@param root string
---@return AtlasFieldCompletionProvider
local function remote_branches_completion(root)
	return {
		fetch = function(query, on_items)
			local q = vim.trim(query):lower()
			local items = {}
			for _, name in ipairs(git_branch.list_remote_branches(root, "origin")) do
				if q == "" or name:lower():find(q, 1, true) == 1 then
					table.insert(items, { name = name })
				end
			end
			on_items(items)
		end,
	}
end

--- Edits the Source branch field. Completion-backed (local branches) when a
--- local git repo was resolved (the common case, either from the pulls
--- dashboard's own "c" or a successful `try_apply_git_defaults`); otherwise
--- falls back to a plain text field so it's still usable.
function M.edit_source_branch()
	local root = state.repo_root
	if not root then
		shell.edit_text_field("source_branch", "Source branch")
		return
	end
	shell.edit_completion_field("source_branch", {
		label = "Source branch",
		seed_text = state.fields.source_branch,
		seed_resolved = state.fields.source_branch ~= "" and { state.fields.source_branch } or {},
		completion = local_branches_completion(root),
		on_save = function(text, done)
			state.fields.source_branch = vim.trim(text)
			done(true)
		end,
	})
end

--- Edits the Target branch field. Completion-backed (remote branches) when a
--- local git repo was resolved; otherwise a plain text field.
function M.edit_target_branch()
	local root = state.repo_root
	if not root then
		shell.edit_text_field("target_branch", "Target branch")
		return
	end
	shell.edit_completion_field("target_branch", {
		label = "Target branch",
		seed_text = state.fields.target_branch,
		seed_resolved = state.fields.target_branch ~= "" and { state.fields.target_branch } or {},
		completion = remote_branches_completion(root),
		on_save = function(text, done)
			state.fields.target_branch = vim.trim(text)
			done(true)
		end,
	})
end

--- Edits the Assignees field. Draft-local mirror of
--- `pulls/providers/gitlab/actions/registry.lua`'s `edit_assignees` action:
--- same completion source, but `on_save` writes into the draft instead of
--- PUTing to GitLab.
function M.edit_assignees()
	local path = state.project_path
	if not path or path == "" then
		notify.warn("Assignee field is not visible")
		return
	end

	local seed_names = {}
	for _, a in ipairs(state.fields.assignees) do
		local username = tostring(a.username or "")
		if username ~= "" then
			table.insert(seed_names, username)
			assignee_by_username[username:lower()] = a
		end
	end

	local completion = users_completion.for_project(users_api.list_members, path, function(user)
		local username = tostring(user.username or "")
		if username == "" then
			return nil
		end
		return {
			name = username,
			display = string.format("%s (@%s)", user.name or username, username),
			menu = "member",
		}
	end, function(users)
		for _, user in ipairs(users) do
			local username = tostring(user.username or "")
			if username ~= "" then
				assignee_by_username[username:lower()] = user
			end
		end
	end)

	shell.edit_completion_field("assignee", {
		label = "Assignees",
		seed_text = table.concat(seed_names, ", "),
		multi_value = true,
		seed_resolved = seed_names,
		completion = completion,
		on_save = function(text, done)
			local selected = {}
			for _, segment in ipairs(vim.split(text, ",", { plain = true })) do
				local trimmed = vim.trim(segment)
				if trimmed ~= "" then
					local user = assignee_by_username[trimmed:lower()]
					if user then
						table.insert(selected, user)
					end
				end
			end
			state.fields.assignees = selected
			done(true)
		end,
	})
end

--- Edits the Labels field.
function M.edit_labels()
	local path = state.project_path
	if not path or path == "" then
		notify.warn("Labels field is not visible")
		return
	end

	local seed_names = {}
	for _, l in ipairs(state.fields.labels) do
		local name = tostring(l.name or "")
		if name ~= "" then
			table.insert(seed_names, name)
		end
	end

	local completion = labels_completion.for_project(labels_api.list, path)

	shell.edit_completion_field("labels", {
		label = "Labels",
		seed_text = table.concat(seed_names, ", "),
		multi_value = true,
		seed_resolved = seed_names,
		completion = completion,
		on_save = function(text, done)
			local selected = {}
			for _, segment in ipairs(vim.split(text, ",", { plain = true })) do
				local trimmed = vim.trim(segment)
				if trimmed ~= "" then
					table.insert(selected, { name = trimmed })
				end
			end
			state.fields.labels = selected
			done(true)
		end,
	})
end

--- Edits the Reviewers field. Draft-local mirror of `M.edit_assignees`: same
--- project-members completion source, typed and editable like every other
--- field, writing into the draft instead of PUTing to GitLab.
function M.edit_reviewers()
	local path = state.project_path
	if not path or path == "" then
		notify.warn("Reviewers field is not visible")
		return
	end

	local seed_names = {}
	for _, r in ipairs(state.fields.reviewers) do
		local username = tostring(r.username or "")
		if username ~= "" then
			table.insert(seed_names, username)
			reviewer_by_username[username:lower()] = r
		end
	end

	local completion = users_completion.for_project(users_api.list_members, path, function(user)
		local username = tostring(user.username or "")
		if username == "" then
			return nil
		end
		return {
			name = username,
			display = string.format("%s (@%s)", user.name or username, username),
			menu = "member",
		}
	end, function(users)
		for _, user in ipairs(users) do
			local username = tostring(user.username or "")
			if username ~= "" then
				reviewer_by_username[username:lower()] = user
			end
		end
	end)

	shell.edit_completion_field("reviewers", {
		label = "Reviewers",
		seed_text = table.concat(seed_names, ", "),
		multi_value = true,
		seed_resolved = seed_names,
		completion = completion,
		on_save = function(text, done)
			local selected = {}
			for _, segment in ipairs(vim.split(text, ",", { plain = true })) do
				local trimmed = vim.trim(segment)
				if trimmed ~= "" then
					local user = reviewer_by_username[trimmed:lower()]
					if user then
						table.insert(selected, user)
					end
				end
			end
			state.fields.reviewers = selected
			done(true)
		end,
	})
end

function M.toggle_draft()
	state.fields.draft = not state.fields.draft
	shell.render_if_open()
end

--- Best-effort local-git default resolution, used when `Type` is switched
--- to `merge_request` manually (e.g. from the issues dashboard's `c` entry
--- point) rather than opened directly from the pulls dashboard (which
--- already resolves these in `M.start()` before the view even opens). Silent
--- on any git error -- Source/Target just stay empty for manual entry.
function M.try_apply_git_defaults()
	local root = state.repo_root or git_branch.repo_root(nil)
	if not root then
		return
	end
	state.repo_root = root

	if state.fields.source_branch == "" then
		local head = git_branch.current_branch(root)
		if head then
			state.fields.source_branch = head
		end
	end
	if state.fields.target_branch == "" then
		local base = git_branch.default_branch(root, "origin")
		if base then
			state.fields.target_branch = base
		end
	end
	shell.render_if_open()
end

---@return table
local function build_payload()
	local assignee_ids = {}
	for _, a in ipairs(state.fields.assignees) do
		local id = tonumber(a.id)
		if id then
			table.insert(assignee_ids, id)
		end
	end
	local label_names = {}
	for _, l in ipairs(state.fields.labels) do
		table.insert(label_names, l.name)
	end
	return {
		repo_slug = state.project_path,
		repo_root = state.repo_root,
		title = vim.trim(state.fields.title),
		body = state.fields.description,
		head = state.fields.source_branch,
		base = state.fields.target_branch,
		draft = state.fields.draft,
		reviewers = state.fields.reviewers,
		assignee_ids = assignee_ids,
		labels = label_names,
	}
end

---@param result PullsCreatePRResult
local function finish_created(result)
	state.submitting = false
	local on_done = state.on_done
	notify.success(tostring(result.message or "Merge request created"), { timeout = 1200 })
	shell.close()
	if on_done then
		on_done({ refresh = true }, nil)
	end
end

local function do_create()
	notify.loading("Creating merge request...")
	state.requests.run(function(done)
		return pullrequests_api.create_pr(build_payload(), done)
	end, function(result, err)
		if err or result == nil then
			state.submitting = false
			notify.error("Create merge request failed: " .. tostring(err or "Unknown error"))
			return
		end
		finish_created(result)
	end)
end

--- Fires the actual `create_pr` API call. Called by `atlas.ui.create`'s
--- `:w` handler after it's already validated the required fields. Pushes
--- the source branch to `origin` first if it isn't there yet (same dance
--- the old tab-based form did); skipped entirely when no local repo was
--- resolved, on the assumption the branch already exists remotely.
function M.submit()
	state.submitting = true
	local root = state.repo_root

	if not root then
		do_create()
		return
	end

	notify.loading("Checking remote branch...")
	git_branch.branch_exists_on_remote(root, state.fields.source_branch, "origin", function(has_remote)
		if has_remote then
			do_create()
			return
		end

		notify.loading("Pushing " .. state.fields.source_branch .. " to origin...")
		git_branch.push_branch(root, state.fields.source_branch, "origin", function(ok, push_err)
			if not ok then
				state.submitting = false
				local err = tostring(push_err or "Unknown error")
				logger.logerror("Create MR push failed", {
					repo_path = root,
					branch = state.fields.source_branch,
					error = err,
				})
				notify.error("git push failed: " .. err)
				return
			end
			do_create()
		end)
	end)
end

--- Entry point for the pulls dashboard's "c" key: resolves the local git
--- context (repo root, current branch, default remote branch) exactly like
--- the old `pulls/create/pr.lua`'s `M.start()` did, then opens the unified
--- create view pre-filled with `Type=merge_request`.
function M.start()
	local root, root_err = git_branch.repo_root(nil)
	if not root then
		notify.error(root_err or "Not in a git repository", { vim_notify = true })
		return
	end

	local head, head_err = git_branch.current_branch(root)
	if not head then
		notify.error(head_err or "Could not detect current branch", { vim_notify = true })
		return
	end

	local info = git_branch.local_repository(root)
	if not info or not info.repo_full_name then
		notify.error("Could not resolve the origin repository", { vim_notify = true })
		return
	end

	local base = git_branch.default_branch(root, "origin") or "main"
	if head == base then
		notify.warn(
			string.format("HEAD '%s' is the default branch — switch to a feature branch first", head),
			{ vim_notify = true }
		)
		return
	end

	require("atlas.ui.create").open({
		project_path = info.repo_full_name,
		repo_root = root,
		initial_type = "merge_request",
		initial_fields = { source_branch = head, target_branch = base },
	})
end

return M
