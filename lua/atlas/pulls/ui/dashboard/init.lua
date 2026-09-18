local M = {}

local dashboard_host = require("atlas.ui.dashboard")
local dashboard_body = require("atlas.ui.dashboard_body")
local statusline = require("atlas.ui.statusline")

function M.render()
	dashboard_body.render(function(width, height, tab_lines)
		return require("atlas.pulls.ui.dashboard.renderer").render({
			width = width,
			height = height - tab_lines,
		})
	end)
end

---@param pr PullRequest
local function open_detail(pr)
	local state = require("atlas.pulls.state")
	require("atlas.pulls.ui.detail").open(pr, {
		provider = state.provider,
		on_update = require("atlas.pulls.ui.dashboard.controller").refresh_pr,
	})
end

---@param item table|nil
function M.select(item)
	if type(item) ~= "table" or (item.kind ~= "pr" and item.kind ~= "pr_meta") or type(item.pr) ~= "table" then
		return
	end
	local detail = require("atlas.pulls.ui.detail")
	if detail.is_open() then
		open_detail(item.pr)
		return
	end
	local repo_detail = require("atlas.pulls.ui.repo_detail")
	if repo_detail.is_open() then
		repo_detail.select(item.repo)
	end
end

function M.toggle_detail()
	local detail = require("atlas.pulls.ui.detail")
	if detail.is_open() then
		detail.close()
		return
	end
	local item = require("atlas.ui.navigation").current_item()
	if type(item) == "table" and (item.kind == "pr" or item.kind == "pr_meta") and type(item.pr) == "table" then
		open_detail(item.pr)
	end
end

---@param provider PullsProvider
---@param opts? { initial_view?: AtlasPullsViewConfig }
function M.init(provider, opts)
	local state = require("atlas.pulls.state")
	local controller = require("atlas.pulls.ui.dashboard.controller")
	local keymaps = require("atlas.pulls.ui.dashboard.keymaps")
	if state.provider ~= provider then
		state.current_user = nil
	end
	state.provider = provider
	state.provider_views = provider.views()
	state.is_loading = false
	state.error = nil
	state.pulls = {}
	state.current_view = nil
	state.reloading_pr_keys = {}
	state.reload_spinner_frame = "⠋"

	local notifications = require("atlas.ui.notifications")
	notifications.set_provider(provider)

	require("atlas.pulls.ui.highlights").setup()
	local ui = provider.capabilities.ui
	if ui and ui.setup then
		ui.setup()
	end

	state.views = state.provider_views
	state.active_view = (opts and opts.initial_view) or state.views[1]
	state.filter_text = require("atlas.ui.filter_query").serialize(state.active_view, { domain = "pulls" })

	statusline.clear_items()

	local buf = dashboard_host.buf()
	if buf ~= nil then
		keymaps.register(buf, state.views)
	end

	if state.active_view == nil then
		state.error = "No pull request view configured"
		M.render()
		return
	end

	M.render()
	controller.switch_view(state.active_view)

	if provider.capabilities.notifications then
		notifications.refresh({ force_load = false, on_done = M.render })
	end
end

--- Re-activates an already-initialized dashboard (e.g. switching back to this
--- tab) without resetting filters, scroll position, or already-loaded pulls.
---@param provider PullsProvider
function M.activate(provider)
	local state = require("atlas.pulls.state")
	local keymaps = require("atlas.pulls.ui.dashboard.keymaps")
	state.provider = provider

	local buf = dashboard_host.buf()
	if buf ~= nil then
		keymaps.register(buf, state.views)
	end

	M.render()
	require("atlas.ui.navigation").focus_first_item()
end

return M
