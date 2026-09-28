local M = {}

local detail_ui = require("atlas.ui.detail")
local renderer = require("atlas.pipelines.ui.detail.renderer")
local notify = require("atlas.core.notify")
local request_scope = require("atlas.core.requests")
local state = require("atlas.pipelines.ui.detail.state")

-- Forward-declared: ensure_job_log's async callback needs render_if_open, and
-- load_details' needs sync_live_updates, before their own (later)
-- definitions -- see the reassignments below.
local render_if_open
local sync_live_updates

---@param pipeline Pipeline
---@param job PipelineJob
local function ensure_job_log(pipeline, job)
	local id = tostring(job.id)
	if state.log_by_job_id[id] ~= nil then
		return
	end

	local provider = state.provider
	local fetch = provider and provider.capabilities.core.fetch_job_log
	if not fetch then
		state.log_by_job_id[id] = { status = "error", text = "Job logs are not supported by this provider" }
		return
	end

	state.log_by_job_id[id] = { status = "loading" }
	state.log_requests.run(function(done)
		return fetch(pipeline, job, {}, done)
	end, function(log, err)
		if err then
			state.log_by_job_id[id] = { status = "error", text = "Failed to load job log: " .. tostring(err) }
		else
			state.log_by_job_id[id] = { status = "loaded", text = tostring(log or "") }
		end
		render_if_open()
	end)
end

local function render()
	renderer.render(ensure_job_log)
end

render_if_open = function()
	if detail_ui.is_showing("pipelines") then
		render()
	end
end

---@param left Pipeline|nil
---@param right Pipeline|nil
---@return boolean
local function same_pipeline(left, right)
	return left ~= nil and right ~= nil and tostring(left.key or "") == tostring(right.key or "")
end

---@param pipeline Pipeline
---@param force_refresh boolean
local function load_details(pipeline, force_refresh)
	local provider = state.provider
	local fetch = provider and provider.capabilities.core.fetch_pipeline_details
	if not fetch then
		return
	end

	state.details_loading = true
	state.requests.run(function(done)
		return fetch(pipeline, { force_load = force_refresh }, done)
	end, function(detailed, err)
		if not same_pipeline(state.current_pipeline, pipeline) then
			return
		end
		state.details_loading = false
		if detailed == nil then
			notify.error(tostring(err or "Failed to load pipeline details"))
		else
			state.current_pipeline = detailed
		end
		render_if_open()
		sync_live_updates()
	end)
end

-- Live-streaming: while the selected pipeline is still running, poll for
-- fresh pipeline details (so the graph/job-log border pick up job-state
-- changes as jobs finish) and re-fetch the active job's log (so it streams
-- rather than staying frozen at whatever it showed on first load). Driven by
-- one fast timer tick (also what animates the job-log box's "Live" spinner)
-- rather than a separate slow poll timer, so the two stay trivially in sync.
local TICK_MS = 150
local POLL_INTERVAL_MS = 3000
local TICKS_PER_POLL = math.max(1, math.floor(POLL_INTERVAL_MS / TICK_MS))

---@type uv.uv_timer_t|nil
local live_timer = nil
local live_tick_count = 0

---@param pipeline Pipeline|nil
---@return boolean
local function is_pipeline_running(pipeline)
	return pipeline ~= nil and tostring(pipeline.state or ""):upper() == "INPROGRESS"
end

---@return PipelineJob|nil
local function active_job()
	local pipeline = state.current_pipeline
	local stages = pipeline and pipeline.stages or {}
	local stage_index = math.max(1, math.min(#stages, state.active_stage))
	local jobs = stages[stage_index] and stages[stage_index].jobs or {}
	if #jobs == 0 then
		return nil
	end
	local job_index = math.max(1, math.min(#jobs, state.active_job_index(stage_index)))
	return jobs[job_index]
end

---@param job PipelineJob|nil
---@return boolean
local function is_job_running(job)
	return job ~= nil and tostring(job.state or ""):upper() == "INPROGRESS"
end

--- Silently re-fetches a still-running job's log in the background. Unlike
--- `ensure_job_log`, always re-fetches rather than trusting the cache, and
--- never flips the entry to "loading" -- that would replace the visible log
--- with a spinner on every poll tick instead of just swapping in new text
--- once it arrives (and dropping a transient poll error rather than
--- clobbering the last good log with it).
---@param pipeline Pipeline
---@param job PipelineJob
local function refresh_job_log(pipeline, job)
	local provider = state.provider
	local fetch = provider and provider.capabilities.core.fetch_job_log
	if not fetch then
		return
	end
	local id = tostring(job.id)
	local entry = state.log_by_job_id[id]
	if entry and entry.status == "loading" then
		return
	end
	state.log_requests.run(function(done)
		return fetch(pipeline, job, {}, done)
	end, function(log, err)
		if err or not same_pipeline(state.current_pipeline, pipeline) then
			return
		end
		local text = tostring(log or "")
		local current = state.log_by_job_id[id]
		if current and current.status == "loaded" and current.text == text then
			return
		end
		state.log_by_job_id[id] = { status = "loaded", text = text }
		render_if_open()
	end)
end

local function stop_live_updates()
	if live_timer then
		live_timer:stop()
		live_timer:close()
		live_timer = nil
	end
end

local function on_live_tick()
	if not M.is_open() or not is_pipeline_running(state.current_pipeline) then
		stop_live_updates()
		return
	end

	renderer.update_streaming_indicator()

	live_tick_count = live_tick_count + 1
	if live_tick_count % TICKS_PER_POLL ~= 0 then
		return
	end

	local pipeline = state.current_pipeline
	if not state.details_loading then
		load_details(pipeline, true)
	end
	local job = active_job()
	if is_job_running(job) then
		refresh_job_log(pipeline, job)
	end
end

--- Starts (or stops) the live-update timer to match whether the currently
--- selected pipeline is still running.
sync_live_updates = function()
	if M.is_open() and is_pipeline_running(state.current_pipeline) then
		if live_timer == nil then
			live_tick_count = 0
			live_timer = vim.uv.new_timer()
			if live_timer then
				live_timer:start(TICK_MS, TICK_MS, vim.schedule_wrap(on_live_tick))
			end
		end
	else
		stop_live_updates()
	end
end

local function cleanup()
	stop_live_updates()
	local buf = state.buf
	if buf and vim.api.nvim_buf_is_valid(buf) then
		require("atlas.pipelines.ui.detail.keymaps").remove(buf)
	end
	state.reset()
end

---@return boolean
function M.is_open()
	return detail_ui.is_showing("pipelines")
end

---@param pipeline Pipeline
---@param opts { force_refresh: boolean|nil }|nil
function M.select(pipeline, opts)
	if not M.is_open() then
		return
	end
	opts = opts or {}

	local changed = not same_pipeline(state.current_pipeline, pipeline)
	state.requests.cancel()
	state.requests = request_scope.new()
	state.current_pipeline = pipeline
	state.details_loading = false
	if changed then
		-- A different pipeline: default back to its first stage rather than
		-- keep whatever stage/job index was active on the previous one.
		state.log_requests.cancel()
		state.log_requests = request_scope.new()
		state.active_stage = 1
		state.active_job_by_stage = {}
		state.log_by_job_id = {}
	end
	render()
	sync_live_updates()
	load_details(pipeline, opts.force_refresh == true)
end

--- Cycles forward (wrapping) to the next stage. Forward-only, matching the
--- single "gp" binding -- there's no "previous stage" key.
function M.next_stage()
	local stages = state.current_pipeline and state.current_pipeline.stages or {}
	if #stages == 0 then
		return
	end
	local index = math.max(1, math.min(#stages, state.active_stage))
	state.active_stage = index % #stages + 1
	render()
	if state.win and vim.api.nvim_win_is_valid(state.win) then
		pcall(vim.api.nvim_win_set_cursor, state.win, { 1, 0 })
	end
end

---@param step 1|-1
local function change_job(step)
	local stages = state.current_pipeline and state.current_pipeline.stages or {}
	local stage_index = math.max(1, math.min(#stages, state.active_stage))
	local jobs = stages[stage_index] and stages[stage_index].jobs or {}
	if #jobs == 0 then
		return
	end
	local index = math.max(1, math.min(#jobs, state.active_job_index(stage_index)))
	state.active_job_by_stage[stage_index] = (index - 1 + step) % #jobs + 1
	render()
	if state.win and vim.api.nvim_win_is_valid(state.win) then
		pcall(vim.api.nvim_win_set_cursor, state.win, { 1, 0 })
	end
end

function M.next_job()
	change_job(1)
end

function M.previous_job()
	change_job(-1)
end

---@param pipeline Pipeline
---@param opts { provider: PipelinesProvider|nil, force_refresh: boolean|nil }|nil
function M.open(pipeline, opts)
	opts = opts or {}
	local provider = opts.provider or state.provider
	if provider == nil then
		notify.error("Pipelines provider unavailable")
		return
	end

	state.win, state.buf, state.header_win, state.header_buf = detail_ui.open("pipelines", cleanup, render)
	state.provider = provider
	if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
		require("atlas.pipelines.ui.detail.keymaps").register(state.buf)
	end

	M.select(pipeline, { force_refresh = opts.force_refresh == true })
end

function M.close()
	if M.is_open() then
		detail_ui.close()
	end
end

return M
