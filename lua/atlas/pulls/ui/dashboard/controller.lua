local M = {}

local notify = require("atlas.core.notify")
local spinner = require("atlas.ui.components.spinner")
local state = require("atlas.pulls.state")
local dashboard_host = require("atlas.ui.dashboard")
local navigation = require("atlas.ui.navigation")
local info_popup = require("atlas.ui.popups.info")
local requests = require("atlas.core.requests")

local active_requests = requests.new()
local pr_reload_requests = requests.new()

local STATUS_ORDER = { "OPEN", "MERGED", "DECLINED" }

---@return PullsStateFilter[]
local function selected_states()
	local selected = {}
	for _, status in ipairs(STATUS_ORDER) do
		if state.status_filters[status] then
			table.insert(selected, status:lower())
		end
	end
	return selected
end

local function render_if_active()
	local provider = state.provider
	if provider == nil or not dashboard_host.is_active("pulls", provider.id) then
		return
	end
	require("atlas.pulls.ui.dashboard").render()
end

---@param updated PullRequest
---@return boolean, string|nil
local function replace_pr(updated)
	local pulls = state.pulls
	local replaced = false
	for index, current in ipairs(pulls) do
		if
			tostring(current.id) == tostring(updated.id)
			and tostring(current.repo_full_name) == tostring(updated.repo_full_name)
		then
			pulls[index] = updated
			replaced = true
			break
		end
	end

	if not replaced then
		return false, nil
	end
	state.pulls = pulls
	return true, nil
end

local loading_spinner = spinner.create({
	interval_ms = 120,
	on_tick = function(frame)
		state.reload_spinner_frame = frame
		render_if_active()
	end,
})

local function stop_loading_spinner()
	loading_spinner:stop()
	state.reload_spinner_frame = "⠋"
end

local function sync_loading_spinner()
	if state.is_loading or next(state.reloading_pr_keys) ~= nil then
		if not loading_spinner:is_running() then
			loading_spinner:start()
		end
		state.reload_spinner_frame = loading_spinner:current_frame()
	else
		stop_loading_spinner()
	end
end

---@param repo_id string
---@param pr_id string|number
local function begin_pr_reload(repo_id, pr_id)
	state.reloading_pr_keys[repo_id .. ":" .. tostring(pr_id)] = true

	sync_loading_spinner()
	render_if_active()
end

---@param repo_id string
---@param pr_id string|number
local function end_pr_reload(repo_id, pr_id)
	state.reloading_pr_keys[repo_id .. ":" .. tostring(pr_id)] = nil

	sync_loading_spinner()

	render_if_active()
end

local function cancel_active_requests()
	active_requests.cancel()
	active_requests = requests.new()
	pr_reload_requests.cancel()
	pr_reload_requests = requests.new()
	stop_loading_spinner()
	state.reloading_pr_keys = {}
end

---@param scope AtlasRequestScope
---@param on_done fun(err: string|nil)
local function get_current_user(scope, on_done)
	if state.current_user ~= nil then
		on_done(nil)
		return
	end
	local provider = state.provider
	if provider == nil then
		on_done("no provider")
		return
	end
	scope.run(function(done)
		return provider.capabilities.core.fetch_user(done)
	end, function(user, err)
		if err ~= nil then
			on_done(tostring(err))
			return
		end
		state.current_user = user
		on_done(nil)
	end)
end

---@param view AtlasPullsViewConfig|nil
---@param force_load boolean
---@param on_done fun()|nil
local function load_view(view, force_load, on_done)
	local provider = state.provider
	if provider == nil then
		if on_done then
			on_done()
		end
		return
	end

	cancel_active_requests()
	if view == nil then
		state.is_loading = false
		state.error = "No pull request view configured"
		state.pulls = {}
		state.current_view = nil
		render_if_active()
		if on_done then
			on_done()
		end
		return
	end

	local load_requests = active_requests
	if state.current_user == nil then
		get_current_user(load_requests, function(user_err)
			if user_err then
				notify.warn(string.format("Failed to fetch current user: %s", tostring(user_err)))
			else
				render_if_active()
			end
		end)
	end

	state.is_loading = true
	state.error = nil
	state.pulls = {}
	state.current_view = view
	sync_loading_spinner()
	notify.loading("Loading pull requests...")
	render_if_active()

	load_requests.run(function(done)
		return provider.capabilities.core.fetch_pullrequests(view, {
			force_load = force_load,
			states = selected_states(),
			current_user = state.current_user,
		}, done)
	end, function(pulls, err)
		state.is_loading = false
		sync_loading_spinner()
		local first_err = err and err[1]
		local has_pulls = #pulls > 0
		if first_err ~= nil then
			if has_pulls then
				state.error = nil
				state.pulls = pulls
				notify.warn(string.format("Pull requests loaded with errors: %s", tostring(first_err)))
			else
				state.error = tostring(first_err)
				state.pulls = {}
				notify.error(string.format("Failed to fetch pull requests: %s", tostring(first_err)))
			end
		else
			state.error = nil
			state.pulls = pulls
			notify.success("Pull requests loaded", { timeout = 1200 })
		end

		render_if_active()
		if on_done then
			on_done()
		end
	end)
end

function M.refresh_current_view()
	local view = state.current_view or state.active_view
	if view == nil then
		return
	end

	local selected_item = navigation.current_item()
	local selected_pr = type(selected_item) == "table"
			and (selected_item.kind == "pr" or selected_item.kind == "pr_meta")
			and type(selected_item.pr) == "table"
			and selected_item.pr
		or nil
	local function finish()
		local focused = false
		if selected_pr ~= nil then
			focused = navigation.focus_item(function(item)
				return item.kind == "pr"
					and tostring(item.pr.id) == tostring(selected_pr.id)
					and item.pr.repo_full_name == selected_pr.repo_full_name
			end)
		end
		if not focused then
			navigation.focus_first_item()
		end

		local detail = require("atlas.pulls.ui.detail")
		local repo_detail = require("atlas.pulls.ui.repo_detail")
		local item = navigation.current_item()
		if
			(selected_pr ~= nil and not focused)
			or type(item) ~= "table"
			or item.kind ~= "pr"
			or type(item.pr) ~= "table"
		then
			if detail.is_open() then
				detail.close()
			end
			if repo_detail.is_open() then
				repo_detail.close()
			end
			return
		end

		if detail.is_open() then
			detail.select(item.pr, { force_refresh = true })
		elseif repo_detail.is_open() then
			repo_detail.select(item.repo, { force_refresh = true })
		end
	end

	load_view(view, true, finish)
end

---@param pr PullRequest
function M.refresh_pr(pr)
	local provider = state.provider
	if provider == nil then
		return
	end
	local core = provider.capabilities.core

	local pr_id = pr.id
	local repo_id = pr.repo_full_name
	if state.is_pr_reloading(repo_id, pr_id) then
		return
	end

	notify.loading(string.format("Reloading PR #%s...", tostring(pr_id)))
	begin_pr_reload(repo_id, pr_id)
	local detail = require("atlas.pulls.ui.detail")
	if detail.is_open() then
		detail.refresh(pr)
	end

	pr_reload_requests.run(function(done)
		return core.fetch_by_refs({ pr }, { force_load = true }, done)
	end, function(fetched_prs, err)
		local fetched_pr = fetched_prs[1]
		if err ~= nil or fetched_pr == nil then
			end_pr_reload(repo_id, pr_id)
			notify.error(tostring(err or "Failed to reload PR"))
			return
		end

		local _, snapshot_err = replace_pr(fetched_pr)
		end_pr_reload(repo_id, pr_id)

		if snapshot_err then
			notify.warn(snapshot_err)
		else
			notify.success(string.format("Reloaded PR #%s", tostring(pr_id)), { timeout = 1200 })
		end
	end)
end

---@param source_buf integer|nil
function M.show_pr_details(source_buf)
	local node = navigation.current_item()
	if type(node) ~= "table" or (node.kind ~= "pr" and node.kind ~= "pr_meta") or type(node.pr) ~= "table" then
		notify.warn("No PR selected")
		return
	end

	local pr = node.pr
	local lines, highlights = require("atlas.pulls.ui.dashboard.popup").content(pr)
	info_popup.show({
		lines = lines,
		highlights = highlights,
		source_buf = source_buf,
	})
end

---@param view AtlasPullsViewConfig|nil
function M.switch_view(view)
	state.active_view = view
	state.filter_text = require("atlas.ui.filter_query").serialize(view, { domain = "pulls" })
	load_view(view, false, function()
		navigation.focus_first_item()
	end)
end

---@param text string
function M.apply_filter_text(text)
	local view = require("atlas.ui.filter_query").parse(text, { domain = "pulls" })
	view.name = "Custom"
	M.switch_view(view)
end

---@param status string
function M.toggle_status_filter(status)
	-- Don't allow deselecting the last active filter
	local active_count = 0
	for _, enabled in pairs(state.status_filters) do
		if enabled then
			active_count = active_count + 1
		end
	end
	if state.status_filters[status] and active_count <= 1 then
		notify.warn("At least one status filter must remain active")
		return
	end

	state.status_filters[status] = not state.status_filters[status]
	M.refresh_current_view()
end

function M.dispose()
	state.is_loading = false
	cancel_active_requests()
end

return M
