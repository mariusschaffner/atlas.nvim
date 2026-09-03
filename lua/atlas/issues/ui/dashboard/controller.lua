local M = {}

local config = require("atlas.config")
local notify = require("atlas.core.notify")
local status_spinner = require("atlas.ui.components.spinner")
local state = require("atlas.issues.state")
local dashboard_host = require("atlas.ui.dashboard")
local navigation = require("atlas.ui.navigation")
local info_popup = require("atlas.ui.popups.info")
local requests = require("atlas.core.requests")

local active_requests = requests.new()
local issue_reload_requests = requests.new()

local function render_if_active()
	local provider = state.provider
	if provider == nil or not dashboard_host.is_active("issues", provider.id) then
		return
	end

	require("atlas.issues.ui.dashboard").render()
end

local refresh_status_spinner = status_spinner.create({
	interval_ms = 120,
	on_tick = function(frame)
		state.reload_spinner_frame = frame
		render_if_active()
	end,
})

local function reset_reload_state()
	refresh_status_spinner:stop()
	state.reloading_issue_keys = {}
	state.reload_spinner_frame = "⠋"
end

---@param issue_key string
local function begin_issue_reload(issue_key)
	state.reloading_issue_keys[issue_key] = true

	if not refresh_status_spinner:is_running() then
		refresh_status_spinner:start()
	end

	state.reload_spinner_frame = refresh_status_spinner:current_frame()
	render_if_active()
end

---@param issue_key string
local function end_issue_reload(issue_key)
	state.reloading_issue_keys[issue_key] = nil

	if next(state.reloading_issue_keys) == nil then
		refresh_status_spinner:stop()
		state.reload_spinner_frame = "⠋"
	end

	render_if_active()
end

local function cancel_active_requests()
	active_requests.cancel()
	active_requests = requests.new()

	issue_reload_requests.cancel()
	issue_reload_requests = requests.new()
	reset_reload_state()
end

---@param provider IssuesProvider
---@param scope AtlasRequestScope
local function fetch_current_user(provider, scope)
	if state.current_user ~= nil then
		return
	end
	scope.run(function(done)
		return provider.capabilities.core.fetch_user(done)
	end, function(user, err)
		if err then
			notify.warn(string.format("Failed to fetch current user: %s", tostring(err)))
			return
		end
		state.current_user = user
		render_if_active()
	end)
end

---@return AtlasIssuesConfig
local function issues_config()
	return (config.options and config.options.issues) or {}
end

---@param view IssuesViewConfig
---@return boolean
local function relationships_enabled(view)
	return view.layout ~= "compact" and issues_config().with_relationships ~= false
end

---@param issues Issue[]
---@return IssueRef[]
local function missing_parent_refs(issues)
	local existing = {}
	for _, issue in ipairs(issues) do
		existing[issue.key] = true
	end

	local refs = {}
	local seen = {}
	for _, issue in ipairs(issues) do
		local parent = issue.parent
		local key = parent and parent.key
		if key and not existing[key] and not seen[key] then
			seen[key] = true
			table.insert(refs, parent)
		end
	end
	return refs
end

---@param issues Issue[]
---@param additions Issue[]
---@return Issue[]
local function merge_issues(issues, additions)
	local existing = {}
	for _, issue in ipairs(issues) do
		existing[issue.key] = true
	end

	for _, issue in ipairs(additions) do
		if not existing[issue.key] then
			existing[issue.key] = true
			table.insert(issues, issue)
		end
	end
	return issues
end

---@param updated Issue
---@return boolean, string|nil
local function replace_issue(updated)
	local issues = state.issues
	for index, current in ipairs(issues) do
		if current.key == updated.key then
			issues[index] = updated
			state.set_issues(issues)
			return true, nil
		end
	end
	return false, nil
end

---@param provider IssuesProvider
---@param view IssuesViewConfig
---@param issues Issue[]
---@param force_load boolean
---@param scope AtlasRequestScope
---@param on_done fun(issues: Issue[])
local function fetch_missing_parents(provider, view, issues, force_load, scope, on_done)
	local fetch = provider.capabilities.core.fetch_by_refs
	if not relationships_enabled(view) then
		on_done(issues)
		return
	end

	local refs = missing_parent_refs(issues)
	if #refs == 0 then
		on_done(issues)
		return
	end

	scope.run(function(done)
		return fetch(refs, { force_load = force_load }, done)
	end, function(parents, err)
		if err then
			notify.warn("Failed to fetch parent issues: " .. tostring(err))
			on_done(issues)
			return
		end
		on_done(merge_issues(issues, parents))
	end)
end

---@param view IssuesViewConfig
---@param force_load boolean
---@param on_done fun()|nil
local function load_query(view, force_load, on_done)
	on_done = on_done or function() end

	local provider = state.provider
	if provider == nil then
		on_done()
		return
	end

	cancel_active_requests()
	local load_requests = active_requests
	fetch_current_user(provider, load_requests)

	state.is_loading = true
	state.error = nil
	state.set_issues({})
	state.current_view = view
	notify.loading("Loading issues...")
	if not refresh_status_spinner:is_running() then
		refresh_status_spinner:start()
	end
	state.reload_spinner_frame = refresh_status_spinner:current_frame()

	render_if_active()

	local function finish_loading()
		state.is_loading = false
		if next(state.reloading_issue_keys) == nil then
			refresh_status_spinner:stop()
		end
	end

	local function finalize_fetch_failure(err, issues)
		finish_loading()

		if #issues > 0 then
			state.error = nil
			state.set_issues(issues)
			notify.warn(string.format("Stopped at %d issues: %s", #issues, tostring(err)))
		else
			state.error = tostring(err)
			state.set_issues({})
			notify.error(string.format("Failed to fetch issues: %s", tostring(err)))
		end

		render_if_active()
		on_done()
	end

	local function finalize_fetch_success(issues)
		state.error = nil
		fetch_missing_parents(provider, view, issues, force_load, load_requests, function(enriched)
			state.set_issues(enriched)
			finish_loading()

			notify.success(string.format("Loaded %d issues", #enriched), { timeout = 1200 })
			render_if_active()
			on_done()
		end)
	end

	local configured_max = tonumber(issues_config().max_results)
	local max_results = (configured_max and configured_max > 0) and math.floor(configured_max) or 100

	local function fetch_page(next_page_token, issues)
		local remaining = max_results - #issues
		if remaining <= 0 then
			finalize_fetch_success(issues)
			return
		end

		load_requests.run(function(done)
			return provider.capabilities.core.fetch_issues(view, {
				force_load = force_load,
				next_page_token = next_page_token,
				max_results = remaining,
				layout = view.layout or "plain",
				with_relationships = relationships_enabled(view),
			}, done)
		end, function(page_issues, next_token, is_last, err)
			if err ~= nil then
				finalize_fetch_failure(err, issues)
				return
			end

			for _, issue in ipairs(page_issues) do
				if #issues >= max_results then
					break
				end
				table.insert(issues, issue)
			end

			state.error = nil
			state.set_issues(issues)
			render_if_active()

			if #issues >= max_results then
				finalize_fetch_success(issues)
				return
			end

			if is_last ~= true and next_token ~= nil and next_token ~= "" then
				fetch_page(next_token, issues)
				return
			end

			finalize_fetch_success(issues)
		end)
	end

	fetch_page(nil, {})
end

---@param force_load boolean
---@param on_done fun()|nil
local function load_active_view(force_load, on_done)
	local view = state.active_view
	if view == nil then
		state.is_loading = false
		state.error = "No issues views configured"
		notify.error(state.error)
		render_if_active()
		if on_done then
			on_done()
		end
		return
	end

	load_query(view, force_load, on_done)
end

function M.refresh_current_view()
	local provider = state.provider
	local refresh = provider and provider.capabilities.core.refresh
	if refresh then
		refresh()
	end
	local selected = navigation.current_item()
	local selected_key = selected and selected.kind == "issue" and selected._issue and selected._issue.key or nil

	local function finish()
		local focused = false
		if selected_key then
			focused = navigation.focus_item(function(item)
				return item.kind == "issue" and item._issue and item._issue.key == selected_key
			end)
		end
		if not focused then
			navigation.focus_first_item()
		end
		local item = navigation.current_item()
		local detail = require("atlas.issues.ui.detail")
		if detail.is_open() then
			if not (selected_key and not focused) and item and item.kind == "issue" and item._issue then
				detail.select(item._issue, { force_refresh = true })
			else
				detail.close()
			end
		end
	end

	load_active_view(true, finish)
end

---@param view IssuesViewConfig|nil
function M.switch_view(view)
	state.active_view = view
	state.filter_text = require("atlas.ui.filter_query").serialize(view, { domain = "issues" })
	load_active_view(false, function()
		navigation.focus_first_item()
	end)
end

---@param text string
function M.apply_filter_text(text)
	local view = require("atlas.ui.filter_query").parse(text, { domain = "issues" })
	view.name = "Custom"
	view.state = view.state or "opened"
	M.switch_view(view)
end

---@param status "OPEN"|"CLOSED"
function M.set_status_filter(status)
	if state.status_filters[status] then
		return
	end
	state.status_filters.OPEN = status == "OPEN"
	state.status_filters.CLOSED = status == "CLOSED"

	local view = vim.tbl_extend("force", {}, state.active_view or {})
	view.state = status == "OPEN" and "opened" or "closed"
	M.switch_view(view)
end

---@param source_buf integer|nil
function M.show_issue_details(source_buf)
	local node = navigation.current_item()
	if type(node) ~= "table" or node.kind ~= "issue" then
		notify.warn("No issue selected")
		return
	end

	local issue = type(node._issue) == "table" and node._issue or nil
	if issue == nil then
		notify.warn("Issue payload missing on line")
		return
	end

	local lines, highlights = require("atlas.issues.ui.popup").content(issue)
	info_popup.show({
		lines = lines,
		highlights = highlights,
		source_buf = source_buf,
	})
end

---@param issue Issue
local function refresh_issue(issue)
	local issue_key = issue.key
	if issue_key == "" then
		notify.warn("Issue key missing")
		return
	end
	if state.reloading_issue_keys[issue_key] then
		return
	end

	local provider = state.provider
	if provider == nil then
		return
	end

	notify.loading(string.format("Reloading %s...", issue_key))
	begin_issue_reload(issue_key)

	---@type IssueRef
	local ref = issue
	local detail = require("atlas.issues.ui.detail")
	if detail.is_open() then
		detail.refresh(issue)
	end
	issue_reload_requests.run(function(done)
		return provider.capabilities.core.fetch_by_refs({ ref }, { force_load = true }, done)
	end, function(fetched_issues, err)
		local fetched_issue = fetched_issues[1]
		if err ~= nil or fetched_issue == nil then
			end_issue_reload(issue_key)
			notify.error(tostring(err or "Failed to reload issue"))
			return
		end
		if fetched_issue.parent == nil then
			fetched_issue.parent = issue.parent
		end

		local replaced = replace_issue(fetched_issue)
		if not replaced then
			local issues = state.issues
			table.insert(issues, fetched_issue)
			state.set_issues(issues)
		end
		end_issue_reload(issue_key)
		notify.success(string.format("Reloaded %s", issue_key), { timeout = 1200 })
	end)
end

---@param result IssuesActionResult|nil
function M.apply_action_result(result)
	if result == nil or result.issue_key == nil or result.issue_key == "" then
		return
	end

	local issue
	for _, candidate in ipairs(state.issues) do
		if candidate.key == result.issue_key then
			issue = candidate
			break
		end
	end
	if issue and not result.removed then
		refresh_issue(issue)
	else
		M.refresh_current_view()
	end
end

---@param issue Issue
---@return boolean, string|nil
function M.update_issue(issue)
	local updated, err = replace_issue(issue)
	if updated then
		render_if_active()
	end
	return updated, err
end

function M.toggle_current_issue_collapsed()
	local node = navigation.current_item()
	if type(node) ~= "table" or node.kind ~= "issue" or type(node._issue) ~= "table" then
		return
	end
	if state.toggle_issue_collapsed(node._issue.key) then
		render_if_active()
	end
end

function M.toggle_all_issues_collapsed()
	if state.toggle_all_issues_collapsed() then
		render_if_active()
	end
end

function M.refresh_current_issue()
	local node = navigation.current_item()
	if type(node) ~= "table" or node.kind ~= "issue" then
		notify.warn("No issue selected")
		return
	end

	local issue = type(node._issue) == "table" and node._issue or nil
	if issue == nil then
		notify.warn("Issue payload missing on line")
		return
	end
	refresh_issue(issue)
end

function M.dispose()
	state.is_loading = false
	cancel_active_requests()
end

return M
