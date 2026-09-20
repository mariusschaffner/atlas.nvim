local request_scope = require("atlas.core.requests")

---@class MilestoneDetailState
---@field win integer|nil
---@field buf integer|nil
---@field header_win integer|nil
---@field header_buf integer|nil
---@field header_regions table<string, AtlasFieldBoxRegion>
---@field provider IssuesProvider|nil
---@field project_path string|nil
---@field current_milestone IssueMilestone|nil
---@field description string|nil
---@field description_loading boolean
---@field work_items Issue[]|nil
---@field work_items_loading boolean
---@field merge_requests MilestoneWorkItem[]|nil
---@field merge_requests_loading boolean
---@field current_tab "description"|"work_items"|"merge_requests"
---@field requests AtlasRequestScope
local M = {
	win = nil,
	buf = nil,
	header_win = nil,
	header_buf = nil,
	header_regions = {},
	provider = nil,
	project_path = nil,
	current_milestone = nil,
	description = nil,
	description_loading = false,
	work_items = nil,
	work_items_loading = false,
	merge_requests = nil,
	merge_requests_loading = false,
	current_tab = "description",
	requests = request_scope.new(),
}

function M.reset()
	M.win = nil
	M.buf = nil
	M.header_win = nil
	M.header_buf = nil
	M.header_regions = {}
	M.provider = nil
	M.project_path = nil
	M.current_milestone = nil
	M.description = nil
	M.description_loading = false
	M.work_items = nil
	M.work_items_loading = false
	M.merge_requests = nil
	M.merge_requests_loading = false
	M.current_tab = "description"
	M.requests.cancel()
	M.requests = request_scope.new()
end

return M
