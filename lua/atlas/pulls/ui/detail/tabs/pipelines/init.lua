local M = {}

local utils = require("atlas.ui.shared.utils")
local spinner = require("atlas.ui.components.spinner")
local renderer = require("atlas.pulls.ui.detail.tabs.pipelines.renderer")
local keymaps = require("atlas.pulls.ui.detail.tabs.pipelines.keymaps")
local state = require("atlas.pulls.ui.detail.tabs.pipelines.state")
local detail = require("atlas.pulls.ui.detail.state")

local PADDING_X = 1

---@type fun()|nil
local current_refresh = nil

---@param pr PullRequest
---@param pipeline PullsPipeline
local function ensure_pipeline_details(pr, pipeline)
	local id = tostring(pipeline.id)
	if state.details_by_id[id] ~= nil then
		return
	end

	local pipelines_api = detail.provider and detail.provider.capabilities.pipelines
	if not pipelines_api or not pipelines_api.fetch_details then
		state.details_by_id[id] = "Pipeline job details are not supported by this provider"
		return
	end

	state.details_by_id[id] = "loading"
	state.requests.run(function(done)
		return pipelines_api.fetch_details(pr, pipeline, {}, done)
	end, function(result, err)
		state.details_by_id[id] = err and ("Failed to load jobs: " .. tostring(err)) or (result or pipeline)
		if current_refresh then
			current_refresh()
		end
	end)
end

---@param pr PullRequest
---@param pipeline PullsPipeline|nil
---@param job PullsPipelineJob
local function ensure_job_log(pr, pipeline, job)
	local id = tostring(job.id)
	if state.log_by_job_id[id] ~= nil then
		return
	end

	local pipelines_api = detail.provider and detail.provider.capabilities.pipelines
	if not pipelines_api or not pipelines_api.fetch_job_log then
		state.log_by_job_id[id] = { status = "error", text = "Job logs are not supported by this provider" }
		return
	end

	state.log_by_job_id[id] = { status = "loading" }
	state.requests.run(function(done)
		return pipelines_api.fetch_job_log(pr, pipeline, job, done)
	end, function(log, err)
		if err then
			state.log_by_job_id[id] = { status = "error", text = "Failed to load job logs: " .. tostring(err) }
		else
			state.log_by_job_id[id] = { status = "loaded", text = tostring(log or "") }
		end
		if current_refresh then
			current_refresh()
		end
	end)
end

-- Exported so keymaps.lua can lazily require this module and drive the same
-- lazy-fetch caches (avoids a circular top-level require between the two).
M.ensure_pipeline_details = ensure_pipeline_details
M.ensure_job_log = ensure_job_log

---@param pipeline_id string
---@return PullsPipelinesNavigableEntry|nil
local function first_job_entry(pipeline_id)
	for _, entry in ipairs(state.navigable) do
		if entry.kind == "job" and tostring(entry.pipeline.id) == pipeline_id then
			return entry
		end
	end
	return nil
end

--- Focuses the first job of a just-expanded pipeline: marks it active and
--- expanded, kicks off its log fetch, and re-renders. Called either
--- synchronously from keymaps.lua's `za` handler (when job details were
--- already cached) or from here once a pending fetch completes.
---@param pr PullRequest
---@param pipeline_id string
---@return boolean focused
function M.focus_first_job(pr, pipeline_id)
	local entry = first_job_entry(pipeline_id)
	if entry == nil then
		return false
	end
	state.active_id = entry.id
	state.expanded_jobs[tostring(entry.job.id)] = true
	ensure_job_log(pr, entry.pipeline, entry.job)
	return true
end

---@param pr PullRequest
---@param width integer
---@return string[], table[], table<integer, table>
local function do_render(pr, width)
	local lines, spans, line_map = {}, {}, {}

	if detail.pipelines == nil or detail.pipelines == "loading" then
		utils.push(lines, spans, spinner.with_text("Loading pipelines..."), "AtlasTextMuted", PADDING_X)
		return lines, spans, line_map
	end
	if type(detail.pipelines) == "string" then
		utils.push(lines, spans, detail.pipelines, "AtlasLogError", PADDING_X)
		return lines, spans, line_map
	end

	-- Pipelines are already newest-first (see the GitLab provider's fetch());
	-- keep that order so it matches the GitLab web UI's pipeline list.
	local entries = detail.pipelines
	if #entries == 0 then
		utils.push(lines, spans, "No pipelines found.", "AtlasTextMuted", PADDING_X)
		return lines, spans, line_map
	end

	return renderer.render(pr, entries, width, ensure_pipeline_details, ensure_job_log)
end

---@param pr PullRequest
---@param _details PullRequestDetails|nil
---@param width integer
---@return string[], table[], table<integer, table>|nil
function M.render(pr, _details, width)
	local lines, spans, line_map = do_render(pr, width)

	-- First render after data loads: default the active entry to the first
	-- pipeline -- `renderer.render` only populates `state.navigable` as a
	-- side effect, so the default can't be known until after this first pass.
	-- Same pattern as the Review tab's `M.render`.
	if state.active_id == nil and #state.navigable > 0 then
		state.active_id = state.navigable[1].id
		lines, spans, line_map = do_render(pr, width)
	end

	-- A `za` on a pipeline whose job details hadn't loaded yet left a pending
	-- focus request; once those details have arrived (now reflected in
	-- `state.navigable`), jump active to its first job and render once more.
	local pending = state.pending_focus_pipeline_id
	if pending ~= nil then
		local detailed = state.details_by_id[pending]
		if detailed ~= nil and detailed ~= "loading" and type(detailed) ~= "string" then
			state.pending_focus_pipeline_id = nil
			if M.focus_first_job(pr, pending) then
				lines, spans, line_map = do_render(pr, width)
				-- This resolution happens inside the async data-load callback
				-- chain, not a keymap handler, so nothing else moves the
				-- window cursor onto the newly-focused job -- do it here.
				local region = state.regions[state.active_id]
				local win = detail.win
				if region and win and vim.api.nvim_win_is_valid(win) then
					pcall(vim.api.nvim_win_set_cursor, win, { region.row + 1, 0 })
				end
			end
		end
	end

	return lines, spans, line_map
end

function M.reset()
	state.reset()
end

---@param pr PullRequest
---@param refresh fun()
---@param opts { force_refresh: boolean|nil }|nil
function M.on_select(pr, refresh, opts)
	opts = opts or {}
	current_refresh = refresh
	if not opts.force_refresh then
		return
	end

	state.requests.cancel()
	state.requests = require("atlas.core.requests").new()
	state.details_by_id = {}
	state.log_by_job_id = {}
	-- Rows still marked expanded will lazily re-fetch on the next render.
end

---@param _lnum integer
---@param _entry table
---@return boolean
function M.is_selectable_line(_lnum, _entry)
	-- Defensive fallback only: this tab's own `ui.next_item`/`ui.previous_item`
	-- (keymaps.lua) fully replace generic line-by-line navigation while it's
	-- active, same as the Review tab.
	return true
end

---@param pr PullRequest
---@param _entry table
---@return boolean|nil
function M.on_enter(pr, _entry)
	-- `<CR>` aliases to the same toggle as `za`, acting on whatever is
	-- currently `state.active_entry()` rather than the literal cursor line.
	return keymaps.toggle_fold(pr, current_refresh)
end

---@return boolean
function M.is_loading()
	if detail.pipelines == "loading" then
		return true
	end
	for id in pairs(state.expanded_pipelines) do
		if state.details_by_id[id] == "loading" then
			return true
		end
	end
	for id in pairs(state.expanded_jobs) do
		local log_entry = state.log_by_job_id[id]
		if log_entry == nil or log_entry.status == "loading" then
			return true
		end
	end
	return false
end

---@param buf integer
---@param refresh fun()
function M.activate(buf, refresh)
	current_refresh = refresh
	keymaps.setup(buf, refresh)
end

---@param buf integer
function M.deactivate(buf)
	current_refresh = nil
	state.requests.cancel()
	keymaps.teardown(buf)
end

return M
