local M = {}

local notify = require("atlas.core.notify")
local state = require("atlas.pipelines.state")
local dashboard_host = require("atlas.ui.dashboard")
local navigation = require("atlas.ui.navigation")
local requests = require("atlas.core.requests")

local active_requests = requests.new()

local function render_if_active()
	local provider = state.provider
	if provider == nil or not dashboard_host.is_active("pipelines", provider.id) then
		return
	end

	require("atlas.pipelines.ui.dashboard").render()
end

local function cancel_active_requests()
	active_requests.cancel()
	active_requests = requests.new()
end

---@param view PipelinesViewConfig
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

	state.is_loading = true
	state.error = nil
	state.set_pipelines({})
	state.current_view = view
	notify.loading("Loading pipelines...")
	render_if_active()

	load_requests.run(function(done)
		return provider.capabilities.core.fetch_pipelines(view, { force_load = force_load }, done)
	end, function(pipelines, _next_page_token, _is_last, err)
		state.is_loading = false
		if err then
			state.error = tostring(err)
			state.set_pipelines({})
			notify.error(string.format("Failed to fetch pipelines: %s", tostring(err)))
		else
			state.error = nil
			state.set_pipelines(pipelines or {})
			notify.success(string.format("Loaded %d pipelines", #(pipelines or {})), { timeout = 1200 })
		end
		render_if_active()
		on_done()
	end)
end

---@param force_load boolean
---@param on_done fun()|nil
local function load_active_view(force_load, on_done)
	local view = state.active_view
	if view == nil then
		state.is_loading = false
		state.error = "No pipelines views configured"
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
	load_active_view(true, function()
		navigation.focus_first_item()
	end)
end

---@param view PipelinesViewConfig|nil
function M.switch_view(view)
	state.active_view = view
	state.filter_text = require("atlas.ui.filter_query").serialize(view, { domain = "pipelines" })
	load_active_view(false, function()
		navigation.focus_first_item()
	end)
end

---@param text string
function M.apply_filter_text(text)
	local parsed = require("atlas.ui.filter_query").parse(text, { domain = "pipelines" })
	local view = parsed.query
	view.name = "Custom"
	-- Always scoped to the current repo, regardless of any project: token the
	-- user typed -- this plugin is a per-repo tool, not a cross-project search
	-- client.
	local provider = state.provider
	view.project = provider and provider.current_repo_project and provider.current_repo_project() or nil
	M.switch_view(view)
end

function M.dispose()
	state.is_loading = false
	cancel_active_requests()
end

return M
