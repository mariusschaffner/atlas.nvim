local M = {}

local actions = require("atlas.issues.actions")
local icons = require("atlas.ui.shared.icons")
local picker = require("atlas.ui.picker")
local notify = require("atlas.core.notify")
local core_utils = require("atlas.core.utils")
local request_scope = require("atlas.core.requests")
local issues_api = require("atlas.issues.providers.gitlab.api.issues")
local users_api = require("atlas.issues.providers.gitlab.api.users")
local labels_api = require("atlas.issues.providers.gitlab.api.labels")
local milestones_api = require("atlas.issues.providers.gitlab.api.milestones")
local service = require("atlas.providers.gitlab.client")
local inline_field_edit = require("atlas.ui.inline_field_edit")
local users_completion = require("atlas.providers.gitlab.completion.users")
local labels_completion = require("atlas.providers.gitlab.completion.labels")
local milestones_completion = require("atlas.providers.gitlab.completion.milestones")
local detail_state = require("atlas.issues.ui.detail.state")
local presentation = require("atlas.issues.ui.presentation")

---@param ctx AtlasIssueActionContext
---@return boolean
local function has_issue(ctx)
	local issue = ctx.issue
	return issue ~= nil and tostring(issue.key or "") ~= ""
end

---@type AtlasIssueAction[]
local ACTIONS = {}
M.items = ACTIONS

---@param action AtlasIssueAction
local function register(action)
	table.insert(ACTIONS, action)
end

---@param ctx AtlasIssueActionContext
---@param target "close"|"reopen"
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function set_issue_state(ctx, target, done)
	local issue = assert(ctx.issue)
	local key = tostring(issue.key or "")
	local label = target == "close" and "Closing" or "Reopening"
	notify.loading(string.format("%s %s...", label, key))
	issues_api.set_state(key, target, function(ok, err)
		if not ok then
			notify.error(err or (label .. " failed"))
			done(nil, err or (label .. " failed"))
			return
		end
		local msg = target == "close" and "Closed" or "Reopened"
		notify.success(string.format("%s %s", msg, key), { timeout = 1200 })
		done({ issue_key = key }, nil)
	end)
end

---@param ctx AtlasIssueActionContext
---@return boolean, string|nil
local function close_issue_available(ctx)
	if not has_issue(ctx) then
		return false, "No issue selected"
	end
	local issue = assert(ctx.issue)
	---@cast issue GitLabIssue
	if issue.status_id == "closed" then
		return false, "Issue is already closed"
	end
	return true, nil
end

---@param ctx AtlasIssueActionContext
---@return boolean, string|nil
local function reopen_issue_available(ctx)
	if not has_issue(ctx) then
		return false, "No issue selected"
	end
	local issue = assert(ctx.issue)
	---@cast issue GitLabIssue
	if issue.status_id ~= "closed" then
		return false, "Issue is not closed"
	end
	return true, nil
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function edit_title(ctx, done)
	local issue = assert(ctx.issue)
	local key = tostring(issue.key or "")
	local core = ctx.provider and ctx.provider.capabilities.core
	local update = core and core.update_title
	if not update then
		notify.warn("Provider does not support editing issue titles")
		done(nil, "Unsupported")
		return
	end

	local header_win = detail_state.header_win
	local region = detail_state.header_regions and detail_state.header_regions.title
	if header_win == nil or not vim.api.nvim_win_is_valid(header_win) or region == nil then
		local message = "Title field is not visible"
		notify.warn(message)
		done(nil, message)
		return
	end

	local current = tostring(issue.title or "")

	inline_field_edit.start({
		anchor_win = header_win,
		row = region.row,
		col = region.col,
		width = region.width,
		height = region.height,
		seed_text = current,
		on_save = function(text, save_done)
			local title = vim.trim(text)
			if title == "" or title == current then
				save_done(true)
				done(nil, nil)
				return
			end
			notify.loading(string.format("Updating title on %s...", key))
			update(issue, title, function(ok, err)
				if not ok then
					save_done(false, err or "Failed")
					return
				end
				issue.title = title
				notify.success("Title updated", { timeout = 1200 })
				save_done(true)
				done({ issue_key = key }, nil)
			end)
		end,
		on_cancel = function()
			done(nil, nil)
		end,
		on_done = function() end,
	})
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function assign(ctx, done)
	local issue = assert(ctx.issue)
	---@cast issue GitLabIssue
	local key = tostring(issue.key or "")
	local path = issue.project_path
	if path == "" then
		local err = "Could not determine project path"
		notify.error(err)
		done(nil, err)
		return
	end

	local header_win = detail_state.header_win
	local region = detail_state.header_regions and detail_state.header_regions.assignee
	if header_win == nil or not vim.api.nvim_win_is_valid(header_win) or region == nil then
		local message = "Assignee field is not visible"
		notify.warn(message)
		done(nil, message)
		return
	end

	notify.loading("Loading assignees...")
	local requests = request_scope.new()
	requests.all({
		assignees = function(next)
			return issues_api.get_assignees(key, next)
		end,
		members = function(next)
			return users_api.list_members(path, "", next)
		end,
	}, function(values, errors)
		local err = errors.assignees or errors.members
		if err then
			local message = tostring(err)
			notify.error(message)
			done(nil, message)
			return
		end
		notify.clear()

		local original = {}
		local by_username = {}
		local seed_names = {}
		for _, assignee in ipairs(values.assignees or {}) do
			if tonumber(assignee.id) then
				table.insert(original, assignee)
			end
			local username = tostring(assignee.account_id or "")
			if username ~= "" then
				table.insert(seed_names, username)
				by_username[username:lower()] = assignee
			end
		end
		for _, member in ipairs(values.members or {}) do
			local username = tostring(member.account_id or "")
			if username ~= "" then
				by_username[username:lower()] = member
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
					by_username[username:lower()] = user
				end
			end
		end)

		inline_field_edit.start({
			anchor_win = header_win,
			row = region.row,
			col = region.col,
			width = region.width,
			height = region.height,
			seed_text = table.concat(seed_names, ", "),
			multi_value = true,
			seed_resolved = seed_names,
			completion = completion,
			on_save = function(text, save_done)
				local selected = {}
				for _, segment in ipairs(vim.split(text, ",", { plain = true })) do
					local trimmed = vim.trim(segment)
					if trimmed ~= "" then
						local user = by_username[trimmed:lower()]
						if user then
							table.insert(selected, user)
						end
					end
				end

				local id_key = function(item)
					return tonumber(item.id)
				end
				if not core_utils.selection_changed(original, selected, id_key) then
					save_done(true)
					done(nil, nil)
					return
				end

				local final_ids = {}
				for _, it in ipairs(selected) do
					local id = tonumber(it.id)
					if id then
						table.insert(final_ids, id)
					end
				end

				notify.loading(string.format("Updating assignees on %s...", key))
				issues_api.set_assignee_ids(key, final_ids, function(ok, set_err)
					if not ok then
						save_done(false, set_err or "Failed")
						return
					end
					local msg = string.format("%d assignee(s)", #final_ids)
					notify.success(msg, { timeout = 1200 })
					save_done(true)
					done({ issue_key = key }, nil)
				end)
			end,
			on_cancel = function()
				done(nil, nil)
			end,
			on_done = function() end,
		})
	end)
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function labels(ctx, done)
	local issue = assert(ctx.issue)
	---@cast issue GitLabIssue
	local key = tostring(issue.key or "")
	local path = issue.project_path
	if path == "" then
		local err = "Could not determine project path"
		notify.error(err)
		done(nil, err)
		return
	end

	local header_win = detail_state.header_win
	local region = detail_state.header_regions and detail_state.header_regions.labels
	if header_win == nil or not vim.api.nvim_win_is_valid(header_win) or region == nil then
		local message = "Labels field is not visible"
		notify.warn(message)
		done(nil, message)
		return
	end

	notify.loading("Loading labels...")
	issues_api.fetch_issue_labels(key, function(current_labels, current_err)
		if current_err or current_labels == nil then
			local message = current_err or "Failed to load issue labels"
			notify.error(message)
			done(nil, message)
			return
		end
		notify.clear()

		local original_set, seed_names = {}, {}
		for _, label in ipairs(current_labels) do
			local name = tostring(label.name or "")
			if name ~= "" then
				original_set[name] = true
				table.insert(seed_names, name)
			end
		end

		local completion = labels_completion.for_project(labels_api.list, path)

		inline_field_edit.start({
			anchor_win = header_win,
			row = region.row,
			col = region.col,
			width = region.width,
			height = region.height,
			seed_text = table.concat(seed_names, ", "),
			multi_value = true,
			seed_resolved = seed_names,
			completion = completion,
			on_save = function(text, save_done)
				local selected_set = {}
				for _, segment in ipairs(vim.split(text, ",", { plain = true })) do
					local trimmed = vim.trim(segment)
					if trimmed ~= "" then
						selected_set[trimmed] = true
					end
				end

				local adds, removes = {}, {}
				for name, _ in pairs(selected_set) do
					if not original_set[name] then
						table.insert(adds, name)
					end
				end
				for name, _ in pairs(original_set) do
					if not selected_set[name] then
						table.insert(removes, name)
					end
				end
				if #adds == 0 and #removes == 0 then
					save_done(true)
					done(nil, nil)
					return
				end

				notify.loading(string.format("Updating labels on %s...", key))
				issues_api.update_labels(key, { add = adds, remove = removes }, function(ok, set_err)
					if not ok then
						save_done(false, set_err or "Failed")
						return
					end
					local msg = string.format("+%d / -%d label(s)", #adds, #removes)
					notify.success(msg, { timeout = 1200 })
					save_done(true)
					done({ issue_key = key }, nil)
				end)
			end,
			on_cancel = function()
				done(nil, nil)
			end,
			on_done = function() end,
		})
	end)
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function milestone(ctx, done)
	local issue = assert(ctx.issue)
	---@cast issue GitLabIssue
	local key = tostring(issue.key or "")
	local path = issue.project_path
	if path == "" then
		local err = "Could not determine project path"
		notify.error(err)
		done(nil, err)
		return
	end

	local header_win = detail_state.header_win
	local region = detail_state.header_regions and detail_state.header_regions.milestone
	if header_win == nil or not vim.api.nvim_win_is_valid(header_win) or region == nil then
		local message = "Milestone field is not visible"
		notify.warn(message)
		done(nil, message)
		return
	end

	local current = detail_state.current_details and detail_state.current_details.milestone
	local current_title = current and tostring(current.title or "") or ""
	local current_id = current and tonumber(current.id) or nil

	local by_title = {}
	if current_title ~= "" and current_id then
		by_title[current_title:lower()] = current_id
	end

	local completion = milestones_completion.for_project(milestones_api.list, path, function(milestones)
		for _, item in ipairs(milestones) do
			local title = tostring(item.title or "")
			local id = tonumber(item.id)
			if title ~= "" and id then
				by_title[title:lower()] = id
			end
		end
	end)

	inline_field_edit.start({
		anchor_win = header_win,
		row = region.row,
		col = region.col,
		width = region.width,
		height = region.height,
		seed_text = current_title,
		seed_resolved = current_title ~= "" and { current_title } or {},
		completion = completion,
		on_save = function(text, save_done)
			local trimmed = vim.trim(text)
			if trimmed == current_title then
				save_done(true)
				done(nil, nil)
				return
			end

			local milestone_id = nil
			if trimmed ~= "" then
				milestone_id = by_title[trimmed:lower()]
				if milestone_id == nil then
					save_done(false, "Unknown milestone: " .. trimmed)
					return
				end
			end

			notify.loading(string.format("Updating milestone on %s...", key))
			issues_api.set_milestone_id(key, milestone_id, function(ok, set_err)
				if not ok then
					save_done(false, set_err or "Failed")
					return
				end
				notify.success(milestone_id and "Milestone updated" or "Milestone cleared", { timeout = 1200 })
				save_done(true)
				done({ issue_key = key }, nil)
			end)
		end,
		on_cancel = function()
			done(nil, nil)
		end,
		on_done = function() end,
	})
end

---@param _ AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function search(_, done)
	local prev_items = nil
	picker.search({
		title = "Search GitLab Issues",
		fetch_on_open = false,
		format_item = function(item)
			return string.format("%s %s", icons.fallback(), tostring(item.label or ""))
		end,
		preview_item = function(item, preview_done)
			local issue = item.value
			local description = vim.trim(tostring(issue.description or ""))
			preview_done({
				title = issue.key,
				lines = vim.split(description ~= "" and description or "No description", "\n", { plain = true }),
			})
		end,
		fetch = function(query, fetch_done)
			local q = vim.trim(query)
			if q == "" then
				fetch_done(prev_items or {}, nil)
				return
			end
			return issues_api.search_issues_picker(q, {}, function(items, err)
				if err or items == nil then
					fetch_done(nil, err or "Search failed")
					return
				end
				local picker_items = {}
				for _, it in ipairs(items) do
					table.insert(picker_items, {
						id = it.key,
						label = string.format("%s - %s", it.key, it.title),
						value = it,
					})
				end
				prev_items = picker_items
				fetch_done(picker_items, nil)
			end)
		end,
		on_select = function(item)
			local url = item.value and item.value.url
			if not url or url == "" then
				local err = "Selected issue is missing URL"
				notify.error(err)
				done(nil, err)
				return
			end
			require("atlas.commands.open").open(url)
			done(nil, nil)
		end,
		on_cancel = function()
			done(nil, nil)
		end,
	})
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function create_issue(ctx, done)
	local resolved = ctx.project_path or ""
	if resolved == "" and has_issue(ctx) then
		local issue = assert(ctx.issue)
		---@cast issue GitLabIssue
		resolved = issue.project_path
	end
	if resolved == "" then
		local git = require("atlas.core.git")
		local root = git.repo_root(nil)
		if root then
			local remote = git.remote_url(root, "origin")
			local info = remote and git.parse_remote_url(remote) or nil
			if info and info.provider == "gitlab" and info.repo_full_name and info.repo_full_name ~= "" then
				resolved = info.repo_full_name
			end
		end
	end

	local function open_editor(path)
		local create_issue_ui = require("atlas.issues.create.gitlab.issue")
		create_issue_ui.open({
			project_path = path,
			on_done = function(result, err)
				if err then
					done(nil, tostring(err))
					return
				end
				if result == nil then
					done(nil, nil)
					return
				end
				done({ issue_key = result.key }, nil)
			end,
		})
	end

	if resolved ~= "" then
		open_editor(resolved)
		return
	end

	vim.ui.input({ prompt = "Project (group/project): " }, function(input)
		if input == nil then
			done(nil, nil)
			return
		end
		local path = vim.trim(tostring(input))
		if path == "" then
			done(nil, nil)
			return
		end
		open_editor(path)
	end)
end

---@param ctx AtlasIssueActionContext
---@return boolean, string|nil
local function open_issue_available(ctx)
	if not has_issue(ctx) then
		return false, "No issue selected"
	end
	if not presentation.is_open(ctx.issue) then
		return false, "Issue is closed"
	end
	return true, nil
end

---@param ctx AtlasIssueActionContext
---@return boolean, string|nil
local function toggle_subscription_available(ctx)
	if not has_issue(ctx) then
		return false, "No issue selected"
	end
	local issue = assert(ctx.issue)
	---@cast issue GitLabIssue
	if issue.project_path == "" then
		return false, "Invalid issue identifier"
	end
	return true, nil
end

---@param ctx AtlasIssueActionContext
---@param done fun(result: IssuesActionResult|nil, err: string|nil)
local function toggle_subscription(ctx, done)
	local issue = assert(ctx.issue)
	---@cast issue GitLabIssue
	local action = issue.is_subscribed == true and "unsubscribe" or "subscribe"
	local endpoint =
		string.format("/projects/%s/issues/%d/%s", service.url_encode(issue.project_path), issue.iid, action)
	notify.loading(issue.is_subscribed and "Unsubscribing..." or "Subscribing...")
	service.request("POST", endpoint, nil, function(result, err)
		if err then
			notify.error(tostring(err))
			done(nil, tostring(err))
			return
		end
		local subscribed = type(result) == "table" and result.subscribed
		if type(subscribed) ~= "boolean" then
			subscribed = action == "subscribe"
		end
		issue.is_subscribed = subscribed == true
		notify.success(issue.is_subscribed and "Subscribed" or "Unsubscribed", { timeout = 1200 })
		done({ issue_key = issue.key }, nil)
	end, {
		action = action == "subscribe" and "Subscribe to issue" or "Unsubscribe from issue",
		project_path = issue.project_path,
		iid = issue.iid,
	})
end

register({
	id = "close_issue",
	label = "Close Issue",
	is_available = close_issue_available,
	run = function(ctx, done)
		set_issue_state(ctx, "close", done)
	end,
})
register({
	id = "reopen_issue",
	label = "Reopen Issue",
	is_available = reopen_issue_available,
	run = function(ctx, done)
		set_issue_state(ctx, "reopen", done)
	end,
})
register({ id = "edit_title", label = "Edit Title", hidden = true, is_available = open_issue_available, run = edit_title })
register({ id = "assign", label = "Edit Assignees", hidden = true, is_available = open_issue_available, run = assign })
register({ id = "labels", label = "Edit Labels", hidden = true, is_available = has_issue, run = labels })
register({
	id = "milestone",
	label = "Edit Milestone",
	hidden = true,
	is_available = open_issue_available,
	run = milestone,
})
register({ id = "search", label = "Search Issues", hidden = true, run = search })
register({ id = "create_issue", label = "Create Issue", hidden = true, run = create_issue })
register(actions.manage_templates)
register(actions.browse_issue)
register(actions.copy_issue_key)
register(actions.copy_issue_url)
register({
	id = "toggle_subscription",
	label = "Toggle subscription",
	hidden = true,
	is_available = toggle_subscription_available,
	run = toggle_subscription,
})

---@param id AtlasGitLabIssueActionId
---@return AtlasIssueAction|nil
function M.find(id)
	for _, action in ipairs(ACTIONS) do
		if action.id == id then
			return action
		end
	end
	return nil
end

return M
