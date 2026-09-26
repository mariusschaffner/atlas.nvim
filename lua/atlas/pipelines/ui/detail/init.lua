local M = {}

local detail_ui = require("atlas.ui.detail")
local renderer = require("atlas.pipelines.ui.detail.renderer")
local notify = require("atlas.core.notify")
local request_scope = require("atlas.core.requests")
local state = require("atlas.pipelines.ui.detail.state")

-- Forward-declared: ensure_job_log's async callback needs render_if_open
-- before its own (later) definition -- see the reassignment below.
local render_if_open

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
	end)
end

local function cleanup()
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
	load_details(pipeline, opts.force_refresh == true)
end

---@param step 1|-1
local function change_stage(step)
	local stages = state.current_pipeline and state.current_pipeline.stages or {}
	if #stages == 0 then
		return
	end
	local index = math.max(1, math.min(#stages, state.active_stage))
	state.active_stage = (index - 1 + step) % #stages + 1
	render()
	if state.win and vim.api.nvim_win_is_valid(state.win) then
		pcall(vim.api.nvim_win_set_cursor, state.win, { 1, 0 })
	end
end

function M.next_stage()
	change_stage(1)
end

function M.previous_stage()
	change_stage(-1)
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
