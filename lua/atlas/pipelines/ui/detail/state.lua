local request_scope = require("atlas.core.requests")

---@class PipelinesDetailState
---@field win integer|nil
---@field buf integer|nil
---@field header_win integer|nil
---@field header_buf integer|nil
---@field provider PipelinesProvider|nil
---@field current_pipeline Pipeline|nil
---@field details_loading boolean
---@field requests AtlasRequestScope
local M = {
	win = nil,
	buf = nil,
	header_win = nil,
	header_buf = nil,
	provider = nil,
	current_pipeline = nil,
	details_loading = false,
	requests = request_scope.new(),
}

function M.reset()
	M.win = nil
	M.buf = nil
	M.header_win = nil
	M.header_buf = nil
	M.provider = nil
	M.current_pipeline = nil
	M.details_loading = false
	M.requests.cancel()
	M.requests = request_scope.new()
end

return M
