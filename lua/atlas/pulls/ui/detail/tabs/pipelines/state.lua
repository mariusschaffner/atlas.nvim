local request_scope = require("atlas.core.requests")

---@class PullsPipelinesNavigableEntry
---@field id string "pipeline:<id>" or "job:<id>"
---@field kind "pipeline"|"job"
---@field pipeline PullsPipeline
---@field stage PullsPipelineStage|nil Only set for kind == "job".
---@field job PullsPipelineJob|nil Only set for kind == "job".

---@class PullsPipelinesTabState
---@field expanded_pipelines table<string, boolean>
---@field expanded_jobs table<string, boolean>
---@field details_by_id table<string, PullsPipeline|"loading"|string>
---@field log_by_job_id table<string, { status: "loading"|"loaded"|"error", text: string|nil }>
---@field requests AtlasRequestScope
---@field navigable PullsPipelinesNavigableEntry[] Flattened, in-order list of every visible entry from the last render.
---@field active_id string|nil Currently active/selected entry id (not cursor-bound).
---@field regions table<string, AtlasFieldBoxRegion> Interior regions from the last render, keyed by navigable id.
---@field pending_focus_pipeline_id string|nil Set by `za` when expanding a pipeline whose job details
--- haven't loaded yet; consumed once those details arrive to focus the first job.
local M = {
	expanded_pipelines = {},
	expanded_jobs = {},
	details_by_id = {},
	log_by_job_id = {},
	requests = request_scope.new(),
	navigable = {},
	active_id = nil,
	regions = {},
	pending_focus_pipeline_id = nil,
}

function M.reset()
	M.expanded_pipelines = {}
	M.expanded_jobs = {}
	M.details_by_id = {}
	M.log_by_job_id = {}
	M.requests.cancel()
	M.requests = request_scope.new()
	M.navigable = {}
	M.active_id = nil
	M.regions = {}
	M.pending_focus_pipeline_id = nil
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

---@return PullsPipelinesNavigableEntry|nil
function M.active_entry()
	for _, entry in ipairs(M.navigable) do
		if entry.id == M.active_id then
			return entry
		end
	end
	return nil
end

--- Moves the active entry by `step` (1 = next, -1 = previous), clamped at
--- the ends of the navigable list (no wraparound, matching plain j/k) --
--- same semantics as the Review tab's `move_active`.
---@param step 1|-1
function M.move_active(step)
	if #M.navigable == 0 then
		return
	end
	local index = 1
	for i, entry in ipairs(M.navigable) do
		if entry.id == M.active_id then
			index = i
			break
		end
	end
	index = math.max(1, math.min(#M.navigable, index + step))
	M.active_id = M.navigable[index].id
end

return M
