local M = {}

local dashboard_host = require("atlas.ui.dashboard")
local dashboard_body = require("atlas.ui.dashboard_body")
local statusline = require("atlas.ui.statusline")

function M.render()
	dashboard_body.render(function(width, height)
		return require("atlas.pipelines.ui.dashboard.renderer").render({ width = width, height = height })
	end)
end

function M.next_page()
	local state = require("atlas.pipelines.state")
	local page = math.min(state.total_pages or 1, (state.page or 1) + 1)
	if page == state.page then
		return
	end
	state.page = page
	M.render()
	require("atlas.ui.navigation").focus_first_item()
end

function M.previous_page()
	local state = require("atlas.pipelines.state")
	local page = math.max(1, (state.page or 1) - 1)
	if page == state.page then
		return
	end
	state.page = page
	M.render()
	require("atlas.ui.navigation").focus_first_item()
end

---@param pipeline Pipeline
local function open_detail(pipeline)
	local state = require("atlas.pipelines.state")
	require("atlas.pipelines.ui.detail").open(pipeline, { provider = state.provider })
end

---@param item { kind: string, _pipeline: Pipeline|nil }|nil
function M.select(item)
	local detail = require("atlas.pipelines.ui.detail")
	if detail.is_open() and type(item) == "table" and item.kind == "pipeline" and type(item._pipeline) == "table" then
		open_detail(item._pipeline)
	end
end

function M.toggle_detail()
	local item = require("atlas.ui.navigation").current_item()
	local detail = require("atlas.pipelines.ui.detail")
	if detail.is_open() then
		detail.close()
		return
	end
	if type(item) == "table" and item.kind == "pipeline" and type(item._pipeline) == "table" then
		open_detail(item._pipeline)
	end
end

---@param provider PipelinesProvider
---@param opts? { initial_view?: PipelinesViewConfig }
function M.init(provider, opts)
	local state = require("atlas.pipelines.state")
	local controller = require("atlas.pipelines.ui.dashboard.controller")
	local keymaps = require("atlas.pipelines.ui.dashboard.keymaps")

	state.provider = provider
	state.provider_views = provider.views()
	state.current_view = nil
	state.error = nil
	state.set_pipelines({})

	local ui = provider.capabilities.ui
	if ui and ui.setup then
		ui.setup()
	end

	state.views = state.provider_views
	state.active_view = (opts and opts.initial_view) or state.provider_views[1] or {
		name = "All",
		project = provider.current_repo_project and provider.current_repo_project() or nil,
	}
	state.filter_text = require("atlas.ui.filter_query").serialize(state.active_view, { domain = "pipelines" })

	statusline.clear_items()

	local buf = dashboard_host.buf()
	if buf ~= nil then
		keymaps.register(buf, state.views)
	end

	M.render()
	controller.switch_view(state.active_view)
end

--- Re-activates an already-initialized dashboard (e.g. switching back to this
--- tab) without resetting filters or already-loaded pipelines.
---@param provider PipelinesProvider
function M.activate(provider)
	local state = require("atlas.pipelines.state")
	local keymaps = require("atlas.pipelines.ui.dashboard.keymaps")
	state.provider = provider

	local buf = dashboard_host.buf()
	if buf ~= nil then
		keymaps.register(buf, state.views)
	end

	M.render()
	require("atlas.ui.navigation").focus_first_item()
end

return M
