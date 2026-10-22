-- Flat rendering for the MR detail view's Pipelines tab: one row per
-- pipeline, and once expanded its stages, jobs and expanded jobs' logs as
-- indented rows. Regions/navigable entries drive the tab's own j/k/za
-- navigation (keymaps.lua).
local M = {}

local spinner = require("atlas.ui.components.spinner")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")
local pipeline_logs = require("atlas.pulls.ui.pipelines.logs")
local state = require("atlas.pulls.ui.detail.tabs.pipelines.state")

local PADDING_X = 1
local JOB_INDENT = 3
local LOG_INDENT = JOB_INDENT + 4
local MAX_LOG_LINES = 400

local PIPELINE_HL = {
	SUCCESSFUL = "AtlasPipelineLinkSuccess",
	FAILED = "AtlasPipelineLinkFailed",
	INPROGRESS = "AtlasPipelineLinkInProgress",
	STOPPED = "AtlasPipelineLinkMuted",
}

local PIPELINE_STATUS_PRIORITY = {
	FAILED = 1,
	INPROGRESS = 2,
	STOPPED = 3,
	UNKNOWN = 4,
	SUCCESSFUL = 5,
}

---@generic T: { state: string }
---@param items T[]
---@return T[]
local function sort_by_status(items)
	local indexed = {}
	for index, item in ipairs(items) do
		table.insert(indexed, { item = item, index = index })
	end
	table.sort(indexed, function(a, b)
		local a_state = tostring(a.item.state or "UNKNOWN"):upper()
		local b_state = tostring(b.item.state or "UNKNOWN"):upper()
		local a_priority = PIPELINE_STATUS_PRIORITY[a_state] or PIPELINE_STATUS_PRIORITY.UNKNOWN
		local b_priority = PIPELINE_STATUS_PRIORITY[b_state] or PIPELINE_STATUS_PRIORITY.UNKNOWN
		if a_priority == b_priority then
			return a.index < b.index
		end
		return a_priority < b_priority
	end)

	local sorted = {}
	for _, entry in ipairs(indexed) do
		table.insert(sorted, entry.item)
	end
	return sorted
end

---@param seconds number|nil
---@return string
local function duration_text(seconds)
	local value = tonumber(seconds)
	if value == nil then
		return ""
	end
	if value < 60 then
		return string.format("%ds", math.floor(value))
	end
	return utils.human_duration(value)
end

---@param pipeline PullsPipeline
---@return string
local function pipeline_key(pipeline)
	return "pipeline:" .. tostring(pipeline.id)
end

---@param job PullsPipelineJob
---@return string
local function job_key(job)
	return "job:" .. tostring(job.id)
end

---@class PullsPipelinesRenderContext
---@field lines string[]
---@field spans table[]
---@field line_map table<integer, table>
---@field width integer

--- Appends one row built from `{ text, hl }` parts, plus an optional dim
--- right-aligned text.
---@param ctx PullsPipelinesRenderContext
---@param parts { [1]: string, [2]: string|nil }[]
---@param right string|nil
---@param entry table
local function push_row(ctx, parts, right, entry)
	local row = #ctx.lines
	local line = string.rep(" ", PADDING_X)
	for _, part in ipairs(parts) do
		if part[2] then
			table.insert(ctx.spans, { line = row, start_col = #line, end_col = #line + #part[1], hl_group = part[2] })
		end
		line = line .. part[1]
	end
	if right and right ~= "" then
		local fill = math.max(1, ctx.width - 1 - vim.api.nvim_strwidth(line) - vim.api.nvim_strwidth(right))
		line = line .. string.rep(" ", fill)
		table.insert(ctx.spans, { line = row, start_col = #line, end_col = #line + #right, hl_group = "AtlasTextMuted" })
		line = line .. right
	end
	table.insert(ctx.lines, line)
	ctx.line_map[#ctx.lines] = entry
end

---@param ctx PullsPipelinesRenderContext
---@param pr PullRequest
---@param pipeline PullsPipeline
---@param job PullsPipelineJob
---@param ensure_job_log fun(pr: PullRequest, pipeline: PullsPipeline|nil, job: PullsPipelineJob)
---@return integer log_rows Rows rendered under the job row.
local function render_job_log(ctx, pr, pipeline, job, ensure_job_log)
	ensure_job_log(pr, pipeline, job)
	local entry = { kind = "pipeline", pipeline = pipeline }
	local indent = string.rep(" ", LOG_INDENT)
	local log_entry = state.log_by_job_id[tostring(job.id)]
	if log_entry == nil or log_entry.status == "loading" then
		push_row(ctx, { { indent .. spinner.with_text("Loading log..."), "AtlasTextMuted" } }, nil, entry)
		return 1
	end
	if log_entry.status == "error" then
		push_row(ctx, { { indent .. tostring(log_entry.text or ""), "AtlasLogError" } }, nil, entry)
		return 1
	end
	local log_lines = pipeline_logs.flatten(pipeline_logs.parse(log_entry.text))
	local rows = 0
	local shown = log_lines
	if #log_lines > MAX_LOG_LINES then
		local truncated = #log_lines - MAX_LOG_LINES
		shown = vim.list_slice(log_lines, truncated + 1, #log_lines)
		local text = string.format("... %d earlier line%s truncated ...", truncated, truncated == 1 and "" or "s")
		push_row(ctx, { { indent .. text, "AtlasTextMuted" } }, nil, entry)
		rows = rows + 1
	end
	if #shown == 0 then
		push_row(ctx, { { indent .. "(empty log)", "AtlasTextMuted" } }, nil, entry)
		return rows + 1
	end
	for i, line in ipairs(shown) do
		push_row(ctx, {
			{ indent .. string.format("%4d │ ", i), "AtlasTextMuted" },
			{ line, pipeline_logs.classify_log_line(line) },
		}, nil, entry)
		rows = rows + 1
	end
	return rows
end

--- One pipeline as flat rows (DESIGN-merge-request-view.md §6: no boxes,
--- dim metadata, bright titles): the pipeline row, and once expanded its
--- stages, jobs and any expanded job's log.
---@param ctx PullsPipelinesRenderContext
---@param pr PullRequest
---@param pipeline PullsPipeline
---@param ensure_pipeline_details fun(pr: PullRequest, pipeline: PullsPipeline)
---@param ensure_job_log fun(pr: PullRequest, pipeline: PullsPipeline|nil, job: PullsPipelineJob)
local function render_pipeline(ctx, pr, pipeline, ensure_pipeline_details, ensure_job_log)
	local id = pipeline_key(pipeline)
	-- `ensure_pipeline_details`/`state.details_by_id` are keyed by the raw
	-- pipeline id (unprefixed), `id` (prefixed) only names the
	-- navigable/active/regions entry; see keymaps.lua's `M.toggle_fold`.
	local raw_id = tostring(pipeline.id)
	local state_value = tostring(pipeline.state or "UNKNOWN"):upper()
	local expanded = state.is_pipeline_expanded(id)
	local job_count = tonumber(pipeline.job_count)
	local entry = { kind = "pipeline", pipeline = pipeline }

	table.insert(state.navigable, { id = id, kind = "pipeline", pipeline = pipeline })
	state.regions[id] = { row = #ctx.lines, col = 1, width = ctx.width, height = 1 }
	local jobs_text = job_count and string.format(" · %d %s", job_count, job_count == 1 and "job" or "jobs") or ""
	push_row(ctx, {
		{ (expanded and "▾" or "▸") .. " ", "AtlasTextMuted" },
		{ icons.pulls_status(state_value:lower()) .. " ", PIPELINE_HL[state_value] or "AtlasPipelineLinkMuted" },
		{ tostring(pipeline.name or ""), "AtlasTextBright" },
		{ jobs_text, "AtlasTextMuted" },
	}, duration_text(pipeline.duration), entry)

	if not expanded then
		return
	end
	ensure_pipeline_details(pr, pipeline)
	local detailed = state.details_by_id[raw_id]
	local indent = string.rep(" ", JOB_INDENT)
	if detailed == nil or detailed == "loading" then
		push_row(ctx, { { indent .. spinner.with_text("Loading jobs..."), "AtlasTextMuted" } }, nil, entry)
		return
	end
	if type(detailed) == "string" then
		push_row(ctx, { { indent .. detailed, "AtlasLogError" } }, nil, entry)
		return
	end

	local any_jobs = false
	for _, stage in ipairs(sort_by_status(detailed.stages)) do
		local stage_jobs = sort_by_status(stage.jobs)
		if #stage_jobs > 0 then
			any_jobs = true
			push_row(ctx, { { indent .. string.upper(stage.name or "Stage"), "AtlasTextMuted" } }, nil, entry)
			for _, job in ipairs(stage_jobs) do
				local jid = job_key(job)
				local job_state = tostring(job.state or "UNKNOWN"):upper()
				table.insert(state.navigable, { id = jid, kind = "job", pipeline = pipeline, stage = stage, job = job })
				local row = #ctx.lines
				push_row(ctx, {
					{ indent .. "  " },
					{ icons.pulls_status(job_state:lower()) .. " ", PIPELINE_HL[job_state] or "AtlasPipelineLinkMuted" },
					{ tostring(job.name or ""), state.active_id == jid and "AtlasTextBright" or nil },
				}, duration_text(job.duration), entry)
				local height = 1
				if state.is_job_expanded(tostring(job.id)) then
					-- Navigation walks an expanded job's log rows, so its region
					-- starts at the first log row.
					height = render_job_log(ctx, pr, pipeline, job, ensure_job_log)
					row = row + 1
				end
				state.regions[jid] = { row = row, col = 1, width = ctx.width, height = height }
			end
		end
	end
	if not any_jobs then
		push_row(ctx, { { indent .. "No jobs found.", "AtlasTextMuted" } }, nil, entry)
	end
end

---@param pr PullRequest
---@param pipelines PullsPipeline[]
---@param width integer
---@param ensure_pipeline_details fun(pr: PullRequest, pipeline: PullsPipeline)
---@param ensure_job_log fun(pr: PullRequest, pipeline: PullsPipeline|nil, job: PullsPipelineJob)
---@return string[] lines
---@return table[] spans
---@return table<integer, table> line_map
function M.render(pr, pipelines, width, ensure_pipeline_details, ensure_job_log)
	---@type PullsPipelinesRenderContext
	local ctx = { lines = { "" }, spans = {}, line_map = {}, width = width }
	state.navigable = {}
	state.regions = {}

	for _, pipeline in ipairs(pipelines) do
		render_pipeline(ctx, pr, pipeline, ensure_pipeline_details, ensure_job_log)
	end

	return ctx.lines, ctx.spans, ctx.line_map
end

return M
