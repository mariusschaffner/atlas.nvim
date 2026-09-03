local request_scope = require("atlas.core.requests")

---@class PullsPipelinesTabState
---@field expanded_pipelines table<string, boolean>
---@field expanded_jobs table<string, boolean>
---@field details_by_id table<string, PullsPipeline|"loading"|string>
---@field log_by_job_id table<string, { status: "loading"|"loaded"|"error", text: string|nil }>
---@field requests AtlasRequestScope
local M = {
	expanded_pipelines = {},
	expanded_jobs = {},
	details_by_id = {},
	log_by_job_id = {},
	requests = request_scope.new(),
}

function M.reset()
	M.expanded_pipelines = {}
	M.expanded_jobs = {}
	M.details_by_id = {}
	M.log_by_job_id = {}
	M.requests.cancel()
	M.requests = request_scope.new()
end

---@param pipeline_id string
---@return boolean
function M.is_pipeline_expanded(pipeline_id)
	return M.expanded_pipelines[pipeline_id] == true
end

---@param pipeline_id string
function M.toggle_pipeline(pipeline_id)
	M.expanded_pipelines[pipeline_id] = not M.is_pipeline_expanded(pipeline_id) or nil
end

---@param job_id string
---@return boolean
function M.is_job_expanded(job_id)
	return M.expanded_jobs[job_id] == true
end

---@param job_id string
function M.toggle_job(job_id)
	M.expanded_jobs[job_id] = not M.is_job_expanded(job_id) or nil
end

return M
