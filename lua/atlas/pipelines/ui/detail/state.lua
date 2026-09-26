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
---@field active_stage integer 1-based index into current_pipeline.stages -- the stage highlighted in the graph and shown in the bottom part.
---@field active_job_by_stage table<integer, integer> 1-based active job tab index, keyed by stage index; remembers the last job picked per stage.
---@field log_by_job_id table<string, { status: "loading"|"loaded"|"error", text: string|nil }>
---@field log_requests AtlasRequestScope Separate from `requests` (pipeline details) so switching jobs doesn't cancel an in-flight details fetch and vice versa.
local M = {
	win = nil,
	buf = nil,
	header_win = nil,
	header_buf = nil,
	provider = nil,
	current_pipeline = nil,
	details_loading = false,
	requests = request_scope.new(),
	active_stage = 1,
	active_job_by_stage = {},
	log_by_job_id = {},
	log_requests = request_scope.new(),
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
	M.active_stage = 1
	M.active_job_by_stage = {}
	M.log_by_job_id = {}
	M.log_requests.cancel()
	M.log_requests = request_scope.new()
end

---@param stage_index integer
---@return integer 1-based
function M.active_job_index(stage_index)
	return M.active_job_by_stage[stage_index] or 1
end

return M
