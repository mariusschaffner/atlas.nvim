-- Data side of the pipeline detail view (DESIGN-pipeline-view.md §6): loads
-- one pipeline (status, stages, jobs), polls it while it can still change,
-- fetches the selected job's trace incrementally while that job runs, and runs
-- the pipeline/job actions. The view subscribes and only renders.
local M = {}

local requests = require("atlas.core.requests")
local status = require("atlas.pipelines.status")

M.PIPELINE_POLL_MS = 4000
M.TRACE_POLL_MS = 1500
M.TICK_MS = 1000
-- Keep polling this long after an action even if the pipeline still looks
-- finished: GitLab takes a moment to flip a retried/played pipeline back to running.
M.ACTION_GRACE_SECONDS = 10

---@alias AtlasPipelineStateEvent "pipeline"|"trace"|"tick"

---@class AtlasPipelineTrace
---@field raw string Every byte received so far.
---@field offset integer Byte offset for the next `Range` request.
---@field status "loading"|"loaded"|"error"
---@field err string|nil
---@field complete boolean The job has finished and its final trace is in.
---@field pending_final boolean|nil A final fetch was asked for while another fetch was in flight.

---@class AtlasPipelineTimers
---@field every fun(ms: integer, fn: fun()): { stop: fun() }
---@field now fun(): integer

--- How one trace response changes the accumulated text. Pure.
--- 206 carries only the requested bytes; 200 means the server ignored the
--- range and sent everything (so the already-known prefix is cut off, or the
--- trace is replaced if it got shorter); 416 means nothing new.
---@param offset integer Bytes already received.
---@param body string|nil
---@param http_status integer|nil
---@return "append"|"reset"|"none" mode
---@return string text
function M.trace_delta(offset, body, http_status)
	body = body or ""
	if http_status == 416 or body == "" then
		return "none", ""
	end
	if http_status == 206 or offset <= 0 then
		return "append", body
	end
	if #body < offset then
		return "reset", body
	end
	local tail = body:sub(offset + 1)
	if tail == "" then
		return "none", ""
	end
	return "append", tail
end

--- Job to show when nothing is selected yet: the first running job, else the
--- first failed one, else the first job. Pure.
---@param pipeline PipelineGraph|nil
---@return PipelineGraphJob|nil
function M.default_job(pipeline)
	if pipeline == nil then
		return nil
	end
	local first, failed
	for _, stage in ipairs(pipeline.stages or {}) do
		for _, job in ipairs(stage.jobs or {}) do
			if job.status == "running" then
				return job
			end
			first = first or job
			if failed == nil and job.status == "failed" and not job.allow_failure then
				failed = job
			end
		end
	end
	return failed or first
end

---@param pipeline PipelineGraph|nil
---@param job_id string|nil
---@return PipelineGraphJob|nil job
---@return PipelineGraphStage|nil stage
function M.find_job(pipeline, job_id)
	if pipeline == nil or job_id == nil then
		return nil, nil
	end
	for _, stage in ipairs(pipeline.stages or {}) do
		for _, job in ipairs(stage.jobs or {}) do
			if job.id == job_id then
				return job, stage
			end
		end
	end
	return nil, nil
end

---@param pipeline PipelineGraph|nil
---@param stage_name string
---@param job_name string
---@return PipelineGraphJob|nil
local function find_job_by_name(pipeline, stage_name, job_name)
	for _, stage in ipairs((pipeline or {}).stages or {}) do
		if stage.name == stage_name then
			for _, job in ipairs(stage.jobs or {}) do
				if job.name == job_name then
					return job
				end
			end
		end
	end
	return nil
end

---@return AtlasPipelineTimers
local function default_timers()
	return {
		every = function(ms, fn)
			local timer = vim.uv.new_timer()
			timer:start(ms, ms, function()
				vim.schedule(fn)
			end)
			return {
				stop = function()
					if not timer:is_closing() then
						timer:stop()
						timer:close()
					end
				end,
			}
		end,
		now = os.time,
	}
end

---@class AtlasPipelineStore
---@field api PipelinesDetailCapability
---@field project_path string
---@field pipeline_id string
---@field iid string|nil
---@field pipeline PipelineGraph|nil
---@field error string|nil
---@field loading boolean
---@field selected_job_id string|nil
---@field traces table<string, AtlasPipelineTrace>
local Store = {}
Store.__index = Store

---@class AtlasPipelineStoreOpts
---@field api PipelinesDetailCapability
---@field project_path string
---@field pipeline_id string|integer
---@field iid string|nil
---@field merge_request { iid: integer|nil, title: string|nil }|nil Known from the entry point (MR view).
---@field timers AtlasPipelineTimers|nil Injected by specs.

---@param opts AtlasPipelineStoreOpts
---@return AtlasPipelineStore
function M.new(opts)
	local self = setmetatable({}, Store)
	self.api = opts.api
	self.project_path = tostring(opts.project_path or "")
	self.pipeline_id = tostring(opts.pipeline_id or "")
	self.iid = opts.iid and tostring(opts.iid) or nil
	self.merge_request = opts.merge_request
	self.pipeline = nil
	self.error = nil
	self.loading = true
	self.selected_job_id = nil
	self.selected_key = nil
	self.traces = {}
	self.listeners = {}
	self.timers = opts.timers or default_timers()
	self.pipeline_scope = requests.new()
	self.trace_scope = requests.new()
	self.action_scope = requests.new()
	self.pipeline_in_flight = false
	self.trace_in_flight = false
	self.grace_until = 0
	self.handles = {}
	self.stopped = false
	return self
end

--- Calls `fn(event, job_id)` on every change. Returns an unsubscribe function.
---@param fn fun(event: AtlasPipelineStateEvent, job_id: string|nil)
---@return fun()
function Store:subscribe(fn)
	table.insert(self.listeners, fn)
	return function()
		for i, listener in ipairs(self.listeners) do
			if listener == fn then
				table.remove(self.listeners, i)
				return
			end
		end
	end
end

---@param event AtlasPipelineStateEvent
---@param job_id string|nil
function Store:emit(event, job_id)
	if self.stopped then
		return
	end
	for _, listener in ipairs(vim.list_extend({}, self.listeners)) do
		listener(event, job_id)
	end
end

---@return integer
function Store:now()
	return self.timers.now()
end

---@return PipelineGraphJob|nil
function Store:selected_job()
	return (M.find_job(self.pipeline, self.selected_job_id))
end

---@return AtlasPipelineTrace|nil
function Store:selected_trace()
	return self.selected_job_id and self.traces[self.selected_job_id] or nil
end

--- Whether the pipeline poll should run.
---@return boolean
function Store:pipeline_active()
	if self.pipeline == nil then
		return false
	end
	return status.is_active(self.pipeline.status) or self:now() < self.grace_until
end

---@param name "poll"|"trace"|"tick"
---@param wanted boolean
---@param ms integer
---@param fn fun()
function Store:set_timer(name, wanted, ms, fn)
	local handle = self.handles[name]
	if wanted and handle == nil then
		self.handles[name] = self.timers.every(ms, fn)
	elseif not wanted and handle ~= nil then
		handle.stop()
		self.handles[name] = nil
	end
end

--- Names of the timers currently running (for specs and the view's cleanup checks).
---@return string[]
function Store:active_timers()
	local names = {}
	for name in pairs(self.handles) do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

function Store:sync_timers()
	if self.stopped then
		return
	end
	local active = self:pipeline_active()
	self:set_timer("poll", active, M.PIPELINE_POLL_MS, function()
		self:refresh()
	end)
	self:set_timer("tick", active and status.is_active(self.pipeline.status), M.TICK_MS, function()
		self:emit("tick")
	end)
	local job = self:selected_job()
	self:set_timer("trace", job ~= nil and job.status == "running", M.TRACE_POLL_MS, function()
		self:fetch_trace(self.selected_job_id)
	end)
end

--- Loads the pipeline (resolving its iid first when needed) and starts polling.
function Store:start()
	if self.iid ~= nil then
		self:refresh()
		return
	end
	self.pipeline_in_flight = true
	self.pipeline_scope.run(function(done)
		return self.api.fetch_pipeline(self.project_path, self.pipeline_id, done)
	end, function(found, err)
		self.pipeline_in_flight = false
		if err or found == nil or found.iid == nil then
			self.loading = false
			self.error = err or "Pipeline not found"
			self:emit("pipeline")
			return
		end
		self.iid = found.iid
		self:refresh()
	end)
end

--- Re-fetches the pipeline snapshot. Skipped while a fetch is still in flight.
function Store:refresh()
	if self.stopped or self.pipeline_in_flight or self.iid == nil then
		return
	end
	self.pipeline_in_flight = true
	self.pipeline_scope.run(function(done)
		return self.api.fetch_pipeline_graph(self.project_path, self.iid, done)
	end, function(pipeline, err)
		self.pipeline_in_flight = false
		self.loading = false
		if err or pipeline == nil then
			self.error = err or "Pipeline not found"
			self:emit("pipeline")
			self:sync_timers()
			return
		end
		self.error = nil
		local previous = self:selected_job()
		pipeline.merge_request = pipeline.merge_request or self.merge_request
		self.pipeline = pipeline

		-- A retried job gets a new id: follow it by stage + name.
		if self.selected_job_id and M.find_job(pipeline, self.selected_job_id) == nil and self.selected_key then
			local successor = find_job_by_name(pipeline, self.selected_key[1], self.selected_key[2])
			if successor then
				self.selected_job_id = nil
				self:select_job(successor.id)
			end
		end
		if self.selected_job_id == nil then
			local job = M.default_job(pipeline)
			if job then
				self:select_job(job.id)
			end
		end

		-- The selected job just finished: one last trace fetch for its tail.
		local current = self:selected_job()
		if previous and current and previous.id == current.id then
			if status.is_active(previous.status) and not status.is_active(current.status) then
				self:fetch_trace(current.id, true)
			end
		end

		self:emit("pipeline")
		self:sync_timers()
	end)
end

--- Switches the trace being followed. Cached traces of finished jobs are reused.
---@param job_id string
function Store:select_job(job_id)
	if self.stopped or job_id == nil or job_id == self.selected_job_id then
		return
	end
	self.selected_job_id = job_id
	local job, stage = M.find_job(self.pipeline, job_id)
	self.selected_key = (job and stage) and { stage.name, job.name } or nil
	self.trace_scope.cancel()
	self.trace_scope = requests.new()
	self.trace_in_flight = false

	local trace = self.traces[job_id]
	if trace == nil or not trace.complete then
		self:fetch_trace(job_id)
	end
	self:emit("trace", job_id)
	self:sync_timers()
end

--- Fetches what's new in a job's trace.
---@param job_id string|nil
---@param final boolean|nil The job just finished: mark the trace complete afterwards.
function Store:fetch_trace(job_id, final)
	if self.stopped or job_id == nil then
		return
	end
	local trace = self.traces[job_id]
	if trace == nil then
		trace = { raw = "", offset = 0, status = "loading", complete = false }
		self.traces[job_id] = trace
	end
	if self.trace_in_flight then
		-- Don't lose the finished job's last bytes to a poll that's still running.
		trace.pending_final = trace.pending_final or final == true
		return
	end
	local job = M.find_job(self.pipeline, job_id)
	-- Jobs that never started (created, pending, manual, skipped) have no trace yet.
	if job and job.started_at == nil and job.status ~= "running" then
		trace.status = "loaded"
		trace.complete = false
		return
	end
	self.trace_in_flight = true
	self.trace_scope.run(function(done)
		return self.api.fetch_job_trace(self.project_path, job_id, trace.offset, done)
	end, function(body, err, http_status)
		self.trace_in_flight = false
		if trace.pending_final then
			trace.pending_final = false
			vim.schedule(function()
				self:fetch_trace(job_id, true)
			end)
		end
		if err then
			trace.status = "error"
			trace.err = err
			self:emit("trace", job_id)
			return
		end
		local mode, text = M.trace_delta(trace.offset, body, http_status)
		if mode == "reset" then
			trace.raw = text
			trace.offset = #text
		elseif mode == "append" then
			trace.raw = trace.raw .. text
			trace.offset = trace.offset + #text
		end
		trace.status = "loaded"
		trace.err = nil
		local latest = M.find_job(self.pipeline, job_id)
		trace.complete = final == true or (latest ~= nil and not status.is_active(latest.status))
		if mode ~= "none" or final or trace.offset == 0 then
			self:emit("trace", job_id)
		end
	end)
end

---@param name "retry_pipeline"|"cancel_pipeline"|"retry_job"|"cancel_job"|"play_job"
---@param target string|nil Pipeline or job id.
---@param on_done fun(ok: boolean, err: string|nil)|nil
function Store:run_action(name, target, on_done)
	on_done = on_done or function() end
	if target == nil then
		on_done(false, "Nothing selected")
		return
	end
	self.action_scope.run(function(done)
		return self.api[name](self.project_path, target, done)
	end, function(ok, err)
		if ok then
			self.grace_until = self:now() + M.ACTION_GRACE_SECONDS
			self.pipeline_in_flight = false
			self.pipeline_scope.cancel()
			self.pipeline_scope = requests.new()
			self:refresh()
			self:sync_timers()
		end
		on_done(ok, err)
	end)
end

---@param on_done fun(ok: boolean, err: string|nil)|nil
function Store:retry_failed(on_done)
	self:run_action("retry_pipeline", self.pipeline_id, on_done)
end

---@param on_done fun(ok: boolean, err: string|nil)|nil
function Store:cancel_pipeline(on_done)
	self:run_action("cancel_pipeline", self.pipeline_id, on_done)
end

---@param job_id string|nil
---@param on_done fun(ok: boolean, err: string|nil)|nil
function Store:retry_job(job_id, on_done)
	self:run_action("retry_job", job_id, on_done)
end

---@param job_id string|nil
---@param on_done fun(ok: boolean, err: string|nil)|nil
function Store:cancel_job(job_id, on_done)
	self:run_action("cancel_job", job_id, on_done)
end

---@param job_id string|nil
---@param on_done fun(ok: boolean, err: string|nil)|nil
function Store:play_job(job_id, on_done)
	self:run_action("play_job", job_id, on_done)
end

--- Stops every timer and in-flight request; the store is dead afterwards.
function Store:stop()
	for name in pairs(self.handles) do
		self:set_timer(name, false, 0, function() end)
	end
	self.stopped = true
	self.pipeline_scope.cancel()
	self.trace_scope.cancel()
	self.action_scope.cancel()
	self.listeners = {}
end

return M
