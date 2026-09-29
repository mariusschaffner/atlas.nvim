-- Issue/milestone-specific half of the unified create view: owns the
-- Assignee/Labels/Milestone/Start-Due-date field editors (writing into the
-- draft in `ui.create.state` instead of PUTing to GitLab, unlike every other
-- caller of `inline_field_edit`) and the final `create_issue`/
-- `create_milestone` API calls. The generic shell (`:w`/`:q`, Type/Title/
-- Description editing) lives in `atlas.ui.create`.
local M = {}

local shell = require("atlas.ui.create")
local state = require("atlas.ui.create.state")
local notify = require("atlas.core.notify")
local milestones_api = require("atlas.issues.providers.gitlab.api.milestones")
local issues_api = require("atlas.issues.providers.gitlab.api.issues")
local users_api = require("atlas.issues.providers.gitlab.api.users")
local labels_api = require("atlas.issues.providers.gitlab.api.labels")
local users_completion = require("atlas.providers.gitlab.completion.users")
local labels_completion = require("atlas.providers.gitlab.completion.labels")
local milestones_completion = require("atlas.providers.gitlab.completion.milestones")

---@type table<string, IssueUser>
local assignee_by_username = {}
---@type table<string, IssueMilestone>
local milestone_by_title = {}

function M.edit_start_date()
	shell.edit_text_field("start_date", "Start date")
end

function M.edit_due_date()
	shell.edit_text_field("due_date", "Due date")
end

--- Browses/inserts a GitLab issue template into the Description field.
--- Issue-type only (there's no milestone-template concept).
function M.edit_templates()
	if state.type ~= "issue" then
		return
	end
	require("atlas.issues.templates").open({
		get_description = function()
			return state.fields.description
		end,
		set_description = function(description)
			state.fields.description = description or ""
			shell.render_if_open()
		end,
		menu_kind = "atlas_gitlab_templates_menu",
	})
end

--- Edits the Assignee field (issue-type only). Draft-local mirror of
--- `issues/providers/gitlab/actions/registry.lua`'s `assign` action: same
--- completion source, but `on_save` writes into the draft instead of
--- PUTing to GitLab.
function M.edit_assignees()
	local path = state.project_path
	if not path or path == "" then
		notify.warn("Assignee field is not visible")
		return
	end

	local seed_names = {}
	for _, a in ipairs(state.fields.assignees) do
		local username = tostring(a.account_id or "")
		if username ~= "" then
			table.insert(seed_names, username)
			assignee_by_username[username:lower()] = a
		end
	end

	local completion = users_completion.for_project(users_api.list_members, path, function(user)
		local username = tostring(user.account_id or "")
		if username == "" then
			return nil
		end
		return {
			name = username,
			display = string.format("%s (@%s)", user.display_name or username, username),
			menu = "member",
		}
	end, function(users)
		for _, user in ipairs(users) do
			local username = tostring(user.account_id or "")
			if username ~= "" then
				assignee_by_username[username:lower()] = user
			end
		end
	end)

	shell.edit_completion_field("assignee", {
		label = "Assignee",
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

--- Edits the Labels field (issue-type only).
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

--- Edits the Milestone field (issue-type only) -- attaches the new issue to
--- an *existing* milestone. Unrelated to the create view's own `Type` field.
function M.edit_milestone()
	local path = state.project_path
	if not path or path == "" then
		notify.warn("Milestone field is not visible")
		return
	end

	local current = state.fields.milestone
	local current_title = current and tostring(current.title or "") or ""

	local completion = milestones_completion.for_project(milestones_api.list, path, function(milestones)
		for _, item in ipairs(milestones) do
			local title = tostring(item.title or "")
			if title ~= "" and tonumber(item.id) then
				milestone_by_title[title:lower()] = item
			end
		end
	end)

	shell.edit_completion_field("milestone", {
		label = "Milestone",
		seed_text = current_title,
		seed_resolved = current_title ~= "" and { current_title } or {},
		completion = completion,
		on_save = function(text, done)
			local trimmed = vim.trim(text)
			if trimmed == "" then
				state.fields.milestone = nil
				done(true)
				return
			end
			local milestone = milestone_by_title[trimmed:lower()]
			if milestone == nil then
				done(false, "Unknown milestone: " .. trimmed)
				return
			end
			state.fields.milestone = milestone
			done(true)
		end,
	})
end

---@return table
local function build_issue_payload()
	local label_names = {}
	for _, l in ipairs(state.fields.labels) do
		table.insert(label_names, l.name)
	end
	local assignee_ids = {}
	for _, a in ipairs(state.fields.assignees) do
		local id = tonumber(a.id)
		if id then
			table.insert(assignee_ids, id)
		end
	end
	return {
		project_path = state.project_path,
		title = vim.trim(state.fields.title),
		description = state.fields.description ~= "" and state.fields.description or nil,
		labels = label_names,
		assignee_ids = assignee_ids,
		milestone_id = state.fields.milestone and state.fields.milestone.id or nil,
		due_date = state.fields.due_date ~= "" and state.fields.due_date or nil,
	}
end

---@param result { key: string|nil, iid: integer|nil, url: string|nil }
local function finish_issue_created(result)
	state.submitting = false
	local on_done = state.on_done
	notify.success("Issue created: " .. tostring(result.key), { timeout = 1200 })
	shell.close()
	if on_done then
		on_done({ issue_key = result.key, refresh = true }, nil)
	end
end

--- GitLab's REST create-issue endpoint has no `start_date` param (only
--- `due_date`) -- start date lives on the GraphQL "work item" dates widget,
--- which needs a `work_item_id` that only exists once the issue is created.
--- So: create the issue first, then look up its work item id and set the
--- start date as a follow-up call. A failure here still leaves the issue
--- created; it's surfaced as a warning, not a hard error.
---@param result { key: string|nil, iid: integer|nil, url: string|nil }
local function apply_start_date_then_finish(result)
	local issue_ref = { key = result.key }
	state.requests.run(function(done)
		return issues_api.fetch_issue_dates(issue_ref, {}, done)
	end, function(dates, err)
		if err or dates == nil or not dates.work_item_id then
			notify.warn("Issue created, but couldn't set start date: " .. tostring(err or "Unknown error"))
			finish_issue_created(result)
			return
		end
		state.requests.run(function(done)
			return issues_api.update_issue_dates(issue_ref, dates.work_item_id, { start_date = state.fields.start_date }, done)
		end, function(ok, update_err)
			if not ok then
				notify.warn("Issue created, but couldn't set start date: " .. tostring(update_err or "Unknown error"))
			end
			finish_issue_created(result)
		end)
	end)
end

--- Fires the actual `create_issue`/`create_milestone` API call, based on
--- `state.type`. Called by `atlas.ui.create`'s `:w` handler after it's
--- already validated the required fields. Leaves the view open on failure
--- so the user can fix something and `:w` again.
function M.submit()
	state.submitting = true

	if state.type == "milestone" then
		notify.loading("Creating milestone...")
		state.requests.run(function(done)
			return milestones_api.create(state.project_path, {
				title = vim.trim(state.fields.title),
				description = state.fields.description ~= "" and state.fields.description or nil,
				start_date = state.fields.start_date ~= "" and state.fields.start_date or nil,
				due_date = state.fields.due_date ~= "" and state.fields.due_date or nil,
			}, done)
		end, function(milestone, err)
			state.submitting = false
			if err or milestone == nil then
				notify.error("Create milestone failed: " .. tostring(err or "Unknown error"))
				return
			end
			local on_done = state.on_done
			notify.success("Milestone created: " .. tostring(milestone.title), { timeout = 1200 })
			shell.close()
			if on_done then
				on_done({ refresh = true }, nil)
			end
		end)
	else
		notify.loading("Creating issue...")
		state.requests.run(function(done)
			return issues_api.create_issue(build_issue_payload(), done)
		end, function(result, err)
			if err or result == nil then
				state.submitting = false
				notify.error("Create issue failed: " .. tostring(err or "Unknown error"))
				return
			end
			if state.fields.start_date ~= "" then
				apply_start_date_then_finish(result)
			else
				finish_issue_created(result)
			end
		end)
	end
end

return M
