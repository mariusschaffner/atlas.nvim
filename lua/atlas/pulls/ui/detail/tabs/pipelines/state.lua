local request_scope = require("atlas.core.requests")

---@class PullsPipelinesTabState
---@field selected_pipeline_id string|nil
---@field details_by_id table<string, PullsPipeline|"loading"|string>
---@field selected_job PullsPipelineJob|nil
---@field selected_job_stage PullsPipelineStage|nil
---@field log_by_job_id table<string, string|"loading"|string>
---@field requests AtlasRequestScope
local M = {
	selected_pipeline_id = nil,
	details_by_id = {},
	selected_job = nil,
	selected_job_stage = nil,
	log_by_job_id = {},
	requests = request_scope.new(),
}

function M.reset()
	M.selected_pipeline_id = nil
	M.details_by_id = {}
	M.selected_job = nil
	M.selected_job_stage = nil
	M.log_by_job_id = {}
	M.requests.cancel()
	M.requests = request_scope.new()
end

---@return boolean
function M.at_pipeline_list()
	return M.selected_pipeline_id == nil
end

---@return boolean
function M.at_job_list()
	return M.selected_pipeline_id ~= nil and M.selected_job == nil
end

---@return boolean
function M.at_job_log()
	return M.selected_job ~= nil
end

---Go up one level: log -> job list -> pipeline list.
---@return boolean true if a level was popped
function M.back()
	if M.selected_job ~= nil then
		M.selected_job = nil
		M.selected_job_stage = nil
		return true
	end
	if M.selected_pipeline_id ~= nil then
		M.selected_pipeline_id = nil
		return true
	end
	return false
end

return M
