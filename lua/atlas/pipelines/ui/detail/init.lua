-- Pipeline detail view (DESIGN-pipeline-view.md): opens one pipeline in the
-- shared detail host, subscribes to its store (`atlas.pipelines.pipeline_state`,
-- which does all fetching and polling) and handles the keys.
local M = {}

local detail_ui = require("atlas.ui.detail")
local renderer = require("atlas.pipelines.ui.detail.renderer")
local notify = require("atlas.core.notify")
local pipeline_state = require("atlas.pipelines.pipeline_state")
local graph = require("atlas.pipelines.ui.detail.components.graph")
local layout = require("atlas.pipelines.ui.detail.graph_layout")
local log_view = require("atlas.pipelines.ui.detail.log_view")
local state = require("atlas.pipelines.ui.detail.state")
local utils = require("atlas.ui.shared.utils")

local function keymaps()
	return require("atlas.pipelines.ui.detail.keymaps")
end

local function render()
	renderer.render()
end

---@return boolean
function M.is_open()
	return detail_ui.is_showing("pipelines")
end

---@param event AtlasPipelineStateEvent
---@param job_id string|nil
local function on_store_event(event, job_id)
	if not M.is_open() then
		return
	end
	if event == "tick" then
		renderer.render_header()
	elseif event == "trace" then
		if state.store and job_id == state.store.selected_job_id then
			renderer.render_log()
		end
	else
		render()
	end
end

local function stop_store()
	if state.unsubscribe then
		state.unsubscribe()
	end
	if state.store then
		state.store:stop()
	end
	state.store = nil
	state.unsubscribe = nil
end

local function cleanup()
	stop_store()
	log_view.detach()
	if utils.buffer.valid(state.buf) then
		keymaps().remove(state.buf)
	end
	state.reset()
end

---@param left Pipeline|nil
---@param right Pipeline|nil
---@return boolean
local function same_pipeline(left, right)
	return left ~= nil
		and right ~= nil
		and tostring(left.project_path or "") == tostring(right.project_path or "")
		and tostring(left.id or "") == tostring(right.id or "")
end

--- Shows `pipeline` in the already-open view (the dashboard calls this as the
--- cursor moves). The same pipeline is just refreshed.
---@param pipeline Pipeline
---@param opts { merge_request: { iid: integer|nil, title: string|nil }|nil }|nil
function M.select(pipeline, opts)
	if not M.is_open() then
		return
	end
	opts = opts or {}
	if state.store and same_pipeline(state.pipeline_ref, pipeline) then
		state.store:refresh()
		return
	end

	stop_store()
	state.pipeline_ref = pipeline
	state.merge_request = opts.merge_request
		or (pipeline.merge_request_iid and { iid = pipeline.merge_request_iid } or nil)
	state.viewport_first = nil
	state.reset_log()
	if state.focus ~= "graph" then
		M.focus_graph()
	end

	local detail_capability = state.provider and state.provider.capabilities.detail
	if detail_capability == nil then
		notify.error("Pipeline details are not supported by this provider")
		return
	end
	state.store = pipeline_state.new({
		api = detail_capability,
		project_path = pipeline.project_path,
		pipeline_id = pipeline.id,
		iid = pipeline.iid,
		merge_request = state.merge_request,
	})
	state.unsubscribe = state.store:subscribe(on_store_event)
	render()
	state.store:start()
end

---@class AtlasPipelineDetailOpenOpts
---@field provider PipelinesProvider|nil
---@field merge_request { iid: integer|nil, title: string|nil }|nil Known when opened from an MR.
---@field return_to fun()|nil Called after closing, to get back to where the view was opened from.

---@param pipeline Pipeline
---@param opts AtlasPipelineDetailOpenOpts|nil
function M.open(pipeline, opts)
	opts = opts or {}
	local provider = opts.provider or state.provider
	if provider == nil then
		notify.error("Pipelines provider unavailable")
		return
	end
	local ui = provider.capabilities.ui
	if ui and ui.setup then
		ui.setup()
	end

	state.win, state.buf, state.header_win, state.header_buf =
		detail_ui.open("pipelines", cleanup, render, { boxed_header = true })
	state.provider = provider
	state.return_to = opts.return_to
	if utils.buffer.valid(state.buf) then
		keymaps().register(state.buf)
	end
	M.select(pipeline, { merge_request = opts.merge_request })
end

function M.close()
	if not M.is_open() then
		return
	end
	local return_to = state.return_to
	detail_ui.close()
	if return_to then
		vim.schedule(return_to)
	end
end

---@return PipelineGraphStage[]
local function stages()
	local pipeline = state.store and state.store.pipeline
	return pipeline and pipeline.stages or {}
end

---@param job PipelineGraphJob|nil
local function select_job(job)
	if job == nil or state.store == nil then
		return
	end
	if job.id ~= state.store.selected_job_id then
		state.reset_log()
		state.store:select_job(job.id)
	end
	render()
end

--- h/l: the neighbouring stage (skipping empty ones), keeping the row.
---@param step 1|-1
local function move_stage(step)
	local all = stages()
	local stage_index, job_index = graph.locate(all, state.store and state.store.selected_job_id)
	local i = stage_index + step
	while all[i] and #(all[i].jobs or {}) == 0 do
		i = i + step
	end
	local target = all[i]
	if target == nil then
		return
	end
	select_job(target.jobs[layout.closest_job(#target.jobs, math.max(1, job_index))])
end

--- j/k: the next/previous job within the stage.
---@param step 1|-1
local function move_job(step)
	local all = stages()
	local stage_index, job_index = graph.locate(all, state.store and state.store.selected_job_id)
	local stage = all[stage_index]
	if stage == nil then
		return
	end
	select_job(stage.jobs[job_index + step])
end

function M.previous_stage()
	move_stage(-1)
end

function M.next_stage()
	move_stage(1)
end

function M.next_job()
	move_job(1)
end

function M.previous_job()
	move_job(-1)
end

--- ⏎: the log gets the keys (native scrolling, search, folds).
function M.focus_log()
	if state.store == nil or state.store:selected_job() == nil then
		return
	end
	state.focus = "log"
	keymaps().set_mode(state.buf, "log")
	render()
end

function M.focus_graph()
	state.focus = "graph"
	if utils.buffer.valid(state.buf) then
		keymaps().set_mode(state.buf, "graph")
	end
	render()
end

return M
