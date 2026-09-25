local M = {}

local actions = require("atlas.pulls.actions")
local action_utils = require("atlas.pulls.actions.utils")
local picker = require("atlas.ui.picker")
local core_notify = require("atlas.core.notify")
local core_utils = require("atlas.core.utils")
local pullrequests_api = require("atlas.pulls.providers.gitlab.api.pullrequests")
local users_api = require("atlas.pulls.providers.gitlab.api.users")
local labels_api = require("atlas.pulls.providers.gitlab.api.labels")
local service = require("atlas.providers.gitlab.client")
local inline_field_edit = require("atlas.ui.inline_field_edit")
local users_completion = require("atlas.providers.gitlab.completion.users")
local labels_completion = require("atlas.providers.gitlab.completion.labels")
local detail_state = require("atlas.pulls.ui.detail.state")
local presentation = require("atlas.pulls.ui.presentation")

---@param ctx AtlasPullActionContext
---@return boolean
local function has_pr(ctx)
	return ctx.pr ~= nil
end

---@param pr PullRequest
---@return string
local function pr_label(pr)
	local path = pr.repo_full_name
	if path ~= "" then
		return string.format("%s!%s", path, tostring(pr.id or ""))
	end
	return string.format("!%s", tostring(pr.id or ""))
end

---@param ctx AtlasPullActionContext
---@return boolean
local function is_open_or_draft(ctx)
	return has_pr(ctx) and presentation.is_open_or_draft(ctx.pr)
end

---@param ctx AtlasPullActionContext
---@param level "loading"|"success"|"warn"|"error"|"info"
---@param message string
---@param duration integer|nil
local function notify(ctx, level, message, duration)
	if ctx.notify then
		ctx.notify(level, message, duration)
		return
	end
	core_notify.show(level, message, { timeout = duration })
end

---@type AtlasPullAction[]
local ACTIONS = {}
M.items = ACTIONS

---@param action AtlasPullAction
local function register(action)
	table.insert(ACTIONS, action)
end

---@param ctx AtlasPullActionContext
---@return boolean, string|nil
local function review_available(ctx)
	if not is_open_or_draft(ctx) then
		return false, "MR is not open"
	end
	return true, nil
end

---@param ctx AtlasPullActionContext
---@return boolean, string|nil
local function merge_available(ctx)
	if not has_pr(ctx) then
		return false, "No MR selected"
	end
	if ctx.pr.state == "draft" then
		return false, "MR is a draft"
	end
	if ctx.pr.state ~= "open" then
		return false, "MR is not open"
	end
	return true, nil
end

---@param ctx AtlasPullActionContext
---@param done fun(result: PullsActionResult|nil, err: string|nil)
local function merge(ctx, done)
	local pr = ctx.pr
	local options = action_utils.merge_options()
	local label = options.method == "squash" and "squash merge" or "merge"
	vim.ui.input({ prompt = string.format("Confirm %s of %s? [y/N]: ", label, pr_label(pr)) }, function(input)
		if not input or not vim.trim(input):lower():match("^y") then
			done({ changed_pr = false, message = "Merge cancelled" }, nil)
			return
		end
		notify(ctx, "loading", string.format("Merging %s...", pr_label(pr)))
		pullrequests_api.merge(pr, {
			squash = options.method == "squash",
			should_remove_source_branch = options.delete_branch,
		}, function(ok, err)
			if not ok then
				notify(ctx, "error", err or "Merge failed")
				done(nil, err or "Merge failed")
				return
			end
			notify(ctx, "success", string.format("Merged %s", pr_label(pr)), 1500)
			done({ changed_pr = true, message = "Merged" }, nil)
		end)
	end)
end

---@param ctx AtlasPullActionContext
---@return boolean, string|nil
local function reopen_available(ctx)
	if not has_pr(ctx) then
		return false, "No MR selected"
	end
	if ctx.pr.state ~= "declined" then
		return false, "MR is not closed"
	end
	return true, nil
end

---@param ctx AtlasPullActionContext
---@param done fun(result: PullsActionResult|nil, err: string|nil)
local function reopen(ctx, done)
	local pr = ctx.pr
	notify(ctx, "loading", string.format("Reopening %s...", pr_label(pr)))
	pullrequests_api.set_state(pr, "reopen", function(ok, err)
		if not ok then
			notify(ctx, "error", err or "Reopen failed")
			done(nil, err or "Reopen failed")
			return
		end
		notify(ctx, "success", string.format("Reopened %s", pr_label(pr)), 1200)
		done({ changed_pr = true, message = "Reopened" }, nil)
	end)
end

---@param ctx AtlasPullActionContext
---@return boolean, string|nil
local function edit_assignees_available(ctx)
	if not is_open_or_draft(ctx) then
		return false, "MR is not open"
	end
	return true, nil
end

---@param ctx AtlasPullActionContext
---@param done fun(result: PullsActionResult|nil, err: string|nil)
local function edit_assignees(ctx, done)
	local pr = ctx.pr
	local path = pr.repo_full_name
	if path == "" then
		done(nil, "Could not determine project path")
		return
	end

	local header_win = detail_state.header_win
	local region = detail_state.header_regions and detail_state.header_regions.assignee
	if header_win == nil or not vim.api.nvim_win_is_valid(header_win) or region == nil then
		local message = "Assignee field is not visible"
		notify(ctx, "warn", message)
		done(nil, message)
		return
	end

	---@param assignees PullsAuthor[]
	local function open_editor(assignees)
		local original = {}
		local by_username = {}
		local seed_names = {}
		for _, a in ipairs(assignees) do
			local id = tonumber(a.id)
			local username = tostring(a.username or "")
			if id and username ~= "" then
				table.insert(original, { id = id, username = username, name = a.name or username })
				table.insert(seed_names, username)
				by_username[username:lower()] = { id = id, username = username, name = a.name or username }
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
					done({ changed_pr = false, message = "No changes" }, nil)
					return
				end

				local final_ids = {}
				for _, it in ipairs(selected) do
					local id = tonumber(it.id)
					if id then
						table.insert(final_ids, id)
					end
				end

				notify(ctx, "loading", string.format("Updating assignees on %s...", pr_label(pr)))
				pullrequests_api.update_assignees(pr, final_ids, function(ok, set_err)
					if not ok then
						save_done(false, set_err or "Failed")
						return
					end
					local msg = string.format("%d assignee(s)", #final_ids)
					notify(ctx, "success", msg, 1200)
					save_done(true)
					done({ changed_pr = true, message = msg }, nil)
				end)
			end,
			on_cancel = function()
				done({ changed_pr = false, message = "Cancelled" }, nil)
			end,
			on_done = function() end,
		})
	end

	if ctx.details then
		open_editor(ctx.details.assignees or {})
		return
	end
	notify(ctx, "loading", "Loading pull request...")
	pullrequests_api.fetch_pullrequest(pr, { force_load = false }, function(details, err)
		if err or details == nil then
			local message = tostring(err or "Failed to load merge request")
			notify(ctx, "error", message)
			done(nil, message)
			return
		end
		open_editor(details.assignees or {})
	end)
end

---@param ctx AtlasPullActionContext
---@param done fun(result: PullsActionResult|nil, err: string|nil)
local function edit_labels(ctx, done)
	local pr = ctx.pr
	local path = pr.repo_full_name
	if path == "" then
		done(nil, "Could not determine project path")
		return
	end

	local header_win = detail_state.header_win
	local region = detail_state.header_regions and detail_state.header_regions.labels
	if header_win == nil or not vim.api.nvim_win_is_valid(header_win) or region == nil then
		local message = "Labels field is not visible"
		notify(ctx, "warn", message)
		done(nil, message)
		return
	end

	---@param labels PullsLabel[]
	local function open_editor(labels)
		local original_set, seed_names = {}, {}
		for _, label in ipairs(labels) do
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
					done({ changed_pr = false, message = "No changes" }, nil)
					return
				end

				notify(ctx, "loading", string.format("Updating labels on %s...", pr_label(pr)))
				pullrequests_api.update_labels(pr, { add = adds, remove = removes }, function(ok, set_err)
					if not ok then
						save_done(false, set_err or "Failed")
						return
					end
					local msg = string.format("+%d / -%d label(s)", #adds, #removes)
					notify(ctx, "success", msg, 1200)
					save_done(true)
					done({ changed_pr = true, message = msg }, nil)
				end)
			end,
			on_cancel = function()
				done({ changed_pr = false, message = "Cancelled" }, nil)
			end,
			on_done = function() end,
		})
	end

	if ctx.details then
		open_editor(ctx.details.labels or {})
		return
	end
	notify(ctx, "loading", "Loading pull request...")
	pullrequests_api.fetch_pullrequest(pr, { force_load = false }, function(details, err)
		if err or details == nil then
			local message = tostring(err or "Failed to load merge request")
			notify(ctx, "error", message)
			done(nil, message)
			return
		end
		open_editor(details.labels or {})
	end)
end

---@param ctx AtlasPullActionContext
---@param done fun(result: PullsActionResult|nil, err: string|nil)
local function search(ctx, done)
	picker.search({
		title = "Search projects",
		fetch_on_open = false,
		format_item = function(item)
			return item.label
		end,
		fetch = function(query, fetch_done)
			query = vim.trim(query)
			if query == "" then
				fetch_done({}, nil)
				return
			end

			local endpoint =
				string.format("/projects?search=%s&per_page=20&order_by=last_activity_at", service.url_encode(query))
			return service.request("GET", endpoint, nil, function(result, err)
				if err then
					fetch_done(nil, tostring(err))
					return
				end

				local list = {}
				for _, item in ipairs(type(result) == "table" and result or {}) do
					local full_path = tostring(item.path_with_namespace or "")
					if full_path ~= "" then
						table.insert(list, { id = full_path, label = full_path })
					end
				end
				fetch_done(list, nil)
			end, {
				action = "Search projects",
				query = query,
			})
		end,
		on_select = function(item)
			local project = item.id
			---@type AtlasGitLabPullsViewConfig
			local search_view = {
				name = "Search",
				key = nil,
				project = project,
				scope = "all",
			}

			notify(ctx, "success", string.format("Search view -> %s", project))
			require("atlas").open("pulls", "gitlab", { initial_view = search_view })
			done({ changed_pr = false, message = "Search view switched" }, nil)
		end,
		on_cancel = function()
			done({ changed_pr = false, message = "Search cancelled" }, nil)
		end,
	})
end

---@param ctx AtlasPullActionContext
---@return boolean, string|nil
local function toggle_subscription_available(ctx)
	if not has_pr(ctx) then
		return false, "No MR selected"
	end
	local path = ctx.pr.repo_full_name
	if path == "" then
		return false, "Missing project path"
	end
	return true, nil
end

---@param ctx AtlasPullActionContext
---@param done fun(result: PullsActionResult|nil, err: string|nil)
local function toggle_subscription(ctx, done)
	local pr = ctx.pr
	local path = pr.repo_full_name
	local iid = tonumber(pr.id)
	if iid == nil then
		done(nil, "Invalid MR identifier")
		return
	end

	---@param details PullRequestDetails
	local function toggle(details)
		local action = details.is_subscribed == true and "unsubscribe" or "subscribe"
		local endpoint = string.format("/projects/%s/merge_requests/%d/%s", service.url_encode(path), iid, action)
		notify(ctx, "loading", details.is_subscribed and "Unsubscribing..." or "Subscribing...")
		service.request("POST", endpoint, nil, function(result, err)
			if err then
				notify(ctx, "error", tostring(err))
				done(nil, tostring(err))
				return
			end
			local subscribed = type(result) == "table" and result.subscribed
			if type(subscribed) ~= "boolean" then
				subscribed = action == "subscribe"
			end
			details.is_subscribed = subscribed == true
			notify(ctx, "success", details.is_subscribed and "Subscribed" or "Unsubscribed", 1200)
			done({
				changed_pr = true,
				message = details.is_subscribed and "Subscribed" or "Unsubscribed",
			}, nil)
		end, {
			action = action == "subscribe" and "Subscribe to MR" or "Unsubscribe from MR",
			project_path = path,
			iid = iid,
		})
	end

	if ctx.details then
		toggle(ctx.details)
		return
	end
	pullrequests_api.fetch_pullrequest(pr, { force_load = false }, function(details, fetch_err)
		if fetch_err or details == nil then
			local message = tostring(fetch_err or "Failed to load merge request")
			notify(ctx, "error", message)
			done(nil, message)
			return
		end
		toggle(details)
	end)
end

register({
	id = actions.approve.id,
	label = actions.approve.label,
	is_available = review_available,
	run = actions.approve.run,
})

register({
	id = actions.request_changes.id,
	label = actions.request_changes.label,
	is_available = review_available,
	run = actions.request_changes.run,
})

register({
	id = "merge",
	label = "Merge MR",
	is_available = merge_available,
	run = merge,
})

register(actions.edit_title)
register(actions.edit_description)

register(actions.decline)

register({
	id = "reopen",
	label = "Reopen MR",
	is_available = reopen_available,
	run = reopen,
})

register(actions.convert_to_draft)
register(actions.ready_for_review)
register(actions.edit_reviewers)

register({
	id = "edit_assignees",
	label = "Edit assignees",
	is_available = edit_assignees_available,
	run = edit_assignees,
})

register({
	id = "edit_labels",
	label = "Edit labels",
	-- Unlike the other edit_* actions, labels stay editable regardless of PR
	-- state (open, draft, merged, or declined) -- only requires a PR to exist.
	is_available = has_pr,
	run = edit_labels,
})

register({
	id = "search",
	label = "Search projects",
	hidden = true,
	run = search,
})

register({
	id = "toggle_subscription",
	label = "Toggle subscription",
	hidden = true,
	is_available = toggle_subscription_available,
	run = toggle_subscription,
})

register(actions.open_diff)

register(actions.copy_id)
register(actions.copy_url)
register(actions.open_in_browser)

---@param id AtlasGitLabActionId
---@return AtlasPullAction|nil
function M.find(id)
	for _, action in ipairs(ACTIONS) do
		if action.id == id then
			return action
		end
	end
	return nil
end

return M
