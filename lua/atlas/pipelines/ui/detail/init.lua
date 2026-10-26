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
	-- Hand the host's content window back in its default look.
	detail_ui.set_content_title(nil)
	detail_ui.set_content_border(nil)
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
		log_view.attach(function()
			renderer.render_log_title()
		end)
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

--- F: follow mode back on, cursor to the end.
function M.follow()
	log_view.follow()
	renderer.render_log_title()
end

--- za: open/close the log section under the cursor.
function M.toggle_fold()
	log_view.toggle_fold()
end

--- gz: hide/show the graph so the log fills the view.
function M.toggle_fullscreen()
	state.fullscreen = not state.fullscreen
	renderer.render_header()
	renderer.render_log_title()
end

-- Actions (DESIGN-pipeline-view.md §5). The store refreshes (and restarts
-- polling) after each one; destructive ones ask first.

---@param question string
---@param on_yes fun()
local function confirm(question, on_yes)
	vim.ui.input({ prompt = question .. " [y/N]: " }, function(input)
		local answer = input and vim.trim(input):lower()
		if answer == "y" or answer == "yes" then
			on_yes()
		end
	end)
end

---@param run fun(store: AtlasPipelineStore, done: fun(ok: boolean, err: string|nil))
---@param doing string e.g. "Retrying job deploy-prod"
---@param done_text string e.g. "Job retried"
local function act(run, doing, done_text)
	local store = state.store
	if store == nil then
		return
	end
	notify.loading(doing .. "...")
	run(store, function(ok, err)
		if not ok then
			notify.error(doing .. " failed: " .. tostring(err))
			return
		end
		notify.success(done_text, { timeout = 1200 })
	end)
end

---@return PipelineGraphJob|nil
local function selected_job()
	local job = state.store and state.store:selected_job()
	if job == nil then
		notify.warn("Select a job first")
	end
	return job
end

--- R: retry the pipeline's failed jobs.
function M.retry_failed()
	act(function(store, done)
		store:retry_failed(done)
	end, "Retrying failed jobs", "Failed jobs retried")
end

--- gX: cancel the whole pipeline (asks first).
function M.cancel_pipeline()
	local store = state.store
	if store == nil then
		return
	end
	confirm(string.format("Cancel pipeline #%s?", store.pipeline_id), function()
		act(function(s, done)
			s:cancel_pipeline(done)
		end, "Cancelling pipeline", "Pipeline cancelled")
	end)
end

--- r: retry the selected job.
function M.retry_job()
	local job = selected_job()
	if job == nil then
		return
	end
	if not job.retryable then
		notify.warn(job.name .. " can't be retried")
		return
	end
	act(function(store, done)
		store:retry_job(job.id, done)
	end, "Retrying " .. job.name, job.name .. " retried")
end

--- p: play the selected manual job.
function M.play_job()
	local job = selected_job()
	if job == nil then
		return
	end
	if not (job.manual and job.playable) then
		notify.warn(job.name .. (job.manual and " is blocked" or " is not a manual job"))
		return
	end
	act(function(store, done)
		store:play_job(job.id, done)
	end, "Starting " .. job.name, job.name .. " started")
end

--- X: cancel the selected job (asks first).
function M.cancel_job()
	local job = selected_job()
	if job == nil then
		return
	end
	if not job.cancelable then
		notify.warn(job.name .. " can't be cancelled")
		return
	end
	confirm(string.format("Cancel job %s?", job.name), function()
		act(function(store, done)
			store:cancel_job(job.id, done)
		end, "Cancelling " .. job.name, job.name .. " cancelled")
	end)
end

return M
