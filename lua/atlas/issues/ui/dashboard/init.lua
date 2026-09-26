local M = {}

local dashboard_host = require("atlas.ui.dashboard")
local dashboard_body = require("atlas.ui.dashboard_body")
local statusline = require("atlas.ui.statusline")

function M.render()
	dashboard_body.render(function(width, height)
		return require("atlas.issues.ui.dashboard.renderer").render({ width = width, height = height })
	end)
end

function M.next_page()
	local state = require("atlas.issues.state")
	local page = math.min(state.total_pages or 1, (state.page or 1) + 1)
	if page == state.page then
		return
	end
	state.page = page
	M.render()
	require("atlas.ui.navigation").focus_first_item()
end

function M.previous_page()
	local state = require("atlas.issues.state")
	local page = math.max(1, (state.page or 1) - 1)
	if page == state.page then
		return
	end
	state.page = page
	M.render()
	require("atlas.ui.navigation").focus_first_item()
end

---@param issue Issue
local function open_detail(issue)
	local state = require("atlas.issues.state")
	local controller = require("atlas.issues.ui.dashboard.controller")
	require("atlas.issues.ui.detail").open(issue, {
		provider = state.provider,
		on_update = function(updated, result)
			if result then
				controller.apply_action_result(result)
			elseif updated then
				controller.update_issue(updated)
			end
		end,
	})
end

-- Tracks whether the cursor was on a milestone row as of the last render, so
-- `M.select` only re-renders (to refresh the "za" hint in the table box's
-- bottom border -- see `keymaps.lua`'s `cursor_on_milestone`) when that
-- actually changes, not on every cursor move.
local last_cursor_on_milestone = nil

---@param milestone IssueMilestone
local function open_milestone_detail(milestone)
	local state = require("atlas.issues.state")
	local project_path = state.active_view and state.active_view.project
	if not project_path or project_path == "" then
		require("atlas.core.notify").warn("No project scoped for this milestone")
		return
	end
	require("atlas.issues.ui.detail.milestone").open(milestone, {
		provider = state.provider,
		project_path = tostring(project_path),
	})
end

---@param item { kind: string, _issue: Issue|nil }|nil
function M.select(item)
	local on_milestone = type(item) == "table" and item.kind == "milestone"
	if on_milestone ~= last_cursor_on_milestone then
		last_cursor_on_milestone = on_milestone
		M.render()
	end

	local detail = require("atlas.issues.ui.detail")
	if detail.is_open() and type(item) == "table" and item.kind == "issue" and type(item._issue) == "table" then
		open_detail(item._issue)
	end
end

function M.toggle_detail()
	local item = require("atlas.ui.navigation").current_item()
	if type(item) == "table" and item.kind == "milestone" and type(item._milestone) == "table" then
		local milestone_detail = require("atlas.issues.ui.detail.milestone")
		if milestone_detail.is_open() then
			milestone_detail.close()
			return
		end
		open_milestone_detail(item._milestone)
		return
	end

	local detail = require("atlas.issues.ui.detail")
	if detail.is_open() then
		detail.close()
		return
	end
	if type(item) == "table" and item.kind == "issue" and type(item._issue) == "table" then
		open_detail(item._issue)
	end
end

---@param provider IssuesProvider
---@param opts? { initial_view?: IssuesViewConfig }
function M.init(provider, opts)
	local state = require("atlas.issues.state")
	local controller = require("atlas.issues.ui.dashboard.controller")
	local keymaps = require("atlas.issues.ui.dashboard.keymaps")
	last_cursor_on_milestone = nil
	if state.provider ~= provider then
		state.current_user = nil
	end
	state.provider = provider
	state.provider_views = provider.views()
	state.current_view = nil

	local notifications = require("atlas.ui.notifications")
	notifications.set_provider(provider)
	state.error = nil
	state.set_issues({})
	state.collapsed_issue_keys = {}

	local capabilities = provider.capabilities
	local ui = capabilities.ui
	if ui and ui.setup then
		ui.setup()
	end

	state.views = state.provider_views
	state.active_view = (opts and opts.initial_view) or {
		name = "Custom",
		scope = "all",
		state = "opened",
		project = provider.current_repo_project and provider.current_repo_project() or nil,
	}
	state.filter_text = require("atlas.ui.filter_query").serialize(state.active_view, { domain = "issues" })

	statusline.clear_items()

	local buf = dashboard_host.buf()
	if buf ~= nil then
		keymaps.register(buf, state.views)
	end

	if state.active_view == nil then
		state.error = "No issues view configured"
		M.render()
		return
	end

	M.render()
	controller.switch_view(state.active_view)

	if capabilities.notifications then
		notifications.refresh({ force_load = false, on_done = M.render })
	end
end

--- Re-activates an already-initialized dashboard (e.g. switching back to this
--- tab) without resetting filters, scroll position, or already-loaded issues.
---@param provider IssuesProvider
function M.activate(provider)
	local state = require("atlas.issues.state")
	local keymaps = require("atlas.issues.ui.dashboard.keymaps")
	state.provider = provider

	local buf = dashboard_host.buf()
	if buf ~= nil then
		keymaps.register(buf, state.views)
	end

	M.render()
	require("atlas.ui.navigation").focus_first_item()
end

return M
