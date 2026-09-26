local M = {}

---@param provider PipelinesProvider
---@param opts? { initial_view?: PipelinesViewConfig }
function M.init(provider, opts)
	local dashboard = require("atlas.pipelines.ui.dashboard")
	dashboard.init(provider, opts)
end

---@param provider PipelinesProvider
function M.activate(provider)
	require("atlas.pipelines.ui.dashboard").activate(provider)
end

function M.render()
	require("atlas.pipelines.ui.dashboard").render()
end

function M.dispose()
	local buf = require("atlas.ui.dashboard").buf()
	if buf then
		require("atlas.pipelines.ui.dashboard.keymaps").remove(buf)
	end
	require("atlas.pipelines.ui.dashboard.controller").dispose()
end

return M
