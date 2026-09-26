-- Box-based rendering for the Pipelines tab: one 80%-width bordered box per
-- pipeline (same sizing/padding convention as the Review/Activity tabs' own
-- comment boxes -- see atlas.pulls.ui.components.comment_box.box_width), with
-- nested bordered boxes per job when a pipeline is expanded. Mirrors the
-- nesting technique in tabs/review/renderer.lua's emit_file_with_comments
-- (one bordered_box's rendered lines embedded as another's content_lines).
local M = {}

local bordered_box = require("atlas.ui.components.bordered_box")
local comment_box = require("atlas.pulls.ui.components.comment_box")
local spinner = require("atlas.ui.components.spinner")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")
local pipeline_logs = require("atlas.pulls.ui.pipelines.logs")
local state = require("atlas.pulls.ui.detail.tabs.pipelines.state")

local PADDING_X = 1
local BASE_PAD = 1
local JOB_INDENT = BASE_PAD + 1
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

---@param lines string[]
---@param highlights table[]
---@param indent integer
local function indent_block(lines, highlights, indent)
	if indent <= 0 then
		return
	end
	local pad = string.rep(" ", indent)
	for i, line in ipairs(lines) do
		lines[i] = pad .. line
	end
	for _, span in ipairs(highlights) do
		span.start_col = span.start_col + indent
		span.end_col = span.end_col + indent
	end
end

---@param pr PullRequest
---@param pipeline PullsPipeline
---@param stage PullsPipelineStage|nil
---@param job PullsPipelineJob
---@param available_width integer
---@param ensure_job_log fun(pr: PullRequest, pipeline: PullsPipeline|nil, job: PullsPipelineJob)
---@return string[] lines
---@return table[] highlights
---@return AtlasFieldBoxRegion region
local function render_job_box(pr, pipeline, stage, job, available_width, ensure_job_log)
	local id = job_key(job)
	local job_state = tostring(job.state or "UNKNOWN"):upper()
	local job_icon = icons.pulls_status(job_state:lower())
	local status_hl = PIPELINE_HL[job_state] or "AtlasPipelineLinkMuted"
	local is_active = state.active_id == id
	local expanded = state.is_job_expanded(tostring(job.id))

	table.insert(state.navigable, { id = id, kind = "job", pipeline = pipeline, stage = stage, job = job })

	local border_hl = is_active and "AtlasFieldBoxBorderEditable" or "AtlasFieldBoxBorder"
	local bottom_hint, bottom_hint_highlights
	if is_active then
		bottom_hint, bottom_hint_highlights =
			comment_box.build_hint({ { action_id = "ui.toggle_fold", label = "Toggle", hl = "AtlasFooterInfo" } })
	end

	local box_width = math.max(3, available_width)
	local content_lines, content_highlights = {}, {}

	if expanded then
		ensure_job_log(pr, pipeline, job)
		local log_entry = state.log_by_job_id[tostring(job.id)]
		if log_entry == nil or log_entry.status == "loading" then
			local text = spinner.with_text("Loading log...")
			table.insert(content_lines, text)
			table.insert(content_highlights, { line = 0, start_col = 0, end_col = #text, hl_group = "AtlasTextMuted" })
		elseif log_entry.status == "error" then
			local text = tostring(log_entry.text or "")
			table.insert(content_lines, text)
			table.insert(content_highlights, { line = 0, start_col = 0, end_col = #text, hl_group = "AtlasLogError" })
		else
			local log_lines = pipeline_logs.split_log_lines(log_entry.text)
			local shown = log_lines
			if #log_lines > MAX_LOG_LINES then
				local truncated = #log_lines - MAX_LOG_LINES
				shown = vim.list_slice(log_lines, truncated + 1, #log_lines)
				local text =
					string.format("... %d earlier line%s truncated ...", truncated, truncated == 1 and "" or "s")
				table.insert(content_lines, text)
				table.insert(
					content_highlights,
					{ line = #content_lines - 1, start_col = 0, end_col = #text, hl_group = "AtlasTextMuted" }
				)
			end
			if #shown == 0 then
				local text = "(empty log)"
				table.insert(content_lines, text)
				table.insert(
					content_highlights,
					{ line = #content_lines - 1, start_col = 0, end_col = #text, hl_group = "AtlasTextMuted" }
				)
			end
			for i, line in ipairs(shown) do
				local gutter = string.format("%4d │ ", i)
				local text = gutter .. line
				table.insert(content_lines, text)
				table.insert(
					content_highlights,
					{ line = #content_lines - 1, start_col = 0, end_col = #gutter, hl_group = "AtlasTextMuted" }
				)
				local line_hl = pipeline_logs.classify_log_line(line)
				if line_hl then
					table.insert(content_highlights, {
						line = #content_lines - 1,
						start_col = #gutter,
						end_col = #text,
						hl_group = line_hl,
					})
				end
			end
		end
	end

	local box_lines, box_highlights = bordered_box.render({
		width = box_width,
		box_width = box_width,
		title = string.format("%s %s", job_icon, job.name),
		title_highlights = { { start_col = 0, end_col = #job_icon, hl_group = status_hl } },
		title_right = duration_text(job.duration),
		content_lines = content_lines,
		content_highlights = content_highlights,
		border_hl = border_hl,
		bottom_hint = bottom_hint,
		bottom_hint_highlights = bottom_hint_highlights,
	})

	local region = { row = 1, col = 1, width = box_width - 2, height = math.max(1, #content_lines) }
	return box_lines, box_highlights, region
end

---@param lines string[]
---@param spans table[]
---@param line_map table<integer, table>
---@param pr PullRequest
---@param pipeline PullsPipeline
---@param width integer
---@param ensure_pipeline_details fun(pr: PullRequest, pipeline: PullsPipeline)
---@param ensure_job_log fun(pr: PullRequest, pipeline: PullsPipeline|nil, job: PullsPipelineJob)
local function append_pipeline_box(lines, spans, line_map, pr, pipeline, width, ensure_pipeline_details, ensure_job_log)
	local id = pipeline_key(pipeline)
	-- `ensure_pipeline_details`/`state.details_by_id` are keyed by the raw
	-- pipeline id (unprefixed) -- unchanged from before this redesign --
	-- while `id` above (prefixed) is only for the navigable/active/regions
	-- namespace. Keep the two straight; see keymaps.lua's `M.toggle_fold`.
	local raw_id = tostring(pipeline.id)
	local state_value = tostring(pipeline.state or "UNKNOWN"):upper()
	local border_hl = PIPELINE_HL[state_value] or "AtlasPipelineLinkMuted"
	local expanded = state.is_pipeline_expanded(id)
	local is_active = state.active_id == id
	local job_count = tonumber(pipeline.job_count)

	table.insert(state.navigable, { id = id, kind = "pipeline", pipeline = pipeline })

	local bottom_hint, bottom_hint_highlights
	if is_active then
		bottom_hint, bottom_hint_highlights =
			comment_box.build_hint({ { action_id = "ui.toggle_fold", label = "Toggle", hl = "AtlasFooterInfo" } })
	end

	local available = math.max(1, width - PADDING_X)
	local box_width = comment_box.box_width(available)
	local interior_width = box_width - 2

	local content_lines, content_highlights = {}, {}

	local jobs_line = string.format(
		"%s %s",
		expanded and "▾" or "▸",
		job_count and string.format("%d %s", job_count, job_count == 1 and "job" or "jobs") or "Jobs"
	)
	table.insert(content_lines, string.rep(" ", BASE_PAD) .. jobs_line)
	table.insert(content_highlights, { line = 0, start_col = 0, end_col = #content_lines[1], hl_group = "AtlasTextMuted" })

	---@type { row: integer, height: integer, id: string }[]
	local pipeline_job_boxes = {}

	if expanded then
		ensure_pipeline_details(pr, pipeline)
		local detailed = state.details_by_id[raw_id]
		if detailed == nil or detailed == "loading" then
			local text = spinner.with_text("Loading jobs...")
			table.insert(content_lines, string.rep(" ", BASE_PAD) .. text)
			table.insert(
				content_highlights,
				{ line = #content_lines - 1, start_col = 0, end_col = #content_lines[#content_lines], hl_group = "AtlasTextMuted" }
			)
		elseif type(detailed) == "string" then
			table.insert(content_lines, string.rep(" ", BASE_PAD) .. detailed)
			table.insert(
				content_highlights,
				{ line = #content_lines - 1, start_col = 0, end_col = #content_lines[#content_lines], hl_group = "AtlasLogError" }
			)
		else
			local stages = sort_by_status(detailed.stages)
			local any_jobs = false
			for _, stage in ipairs(stages) do
				local stage_jobs = sort_by_status(stage.jobs)
				if #stage_jobs > 0 then
					any_jobs = true
					local stage_text = string.rep(" ", JOB_INDENT) .. (stage.name or "Stage")
					table.insert(content_lines, stage_text)
					table.insert(
						content_highlights,
						{ line = #content_lines - 1, start_col = 0, end_col = #stage_text, hl_group = "AtlasColumnHeader" }
					)

					for _, job in ipairs(stage_jobs) do
						local job_lines, job_highlights, job_region =
							render_job_box(pr, pipeline, stage, job, interior_width - JOB_INDENT, ensure_job_log)
						indent_block(job_lines, job_highlights, JOB_INDENT)

						-- `content_lines` is 1-indexed; job_lines[k] (1-indexed within
						-- the job's own box_lines) ends up at content_lines[job_base+k].
						-- job_region.row is 0-indexed within job_lines (row 0 = top
						-- border), so its first content row is job_lines[job_region.row+1],
						-- landing at content_lines[job_base+job_region.row+1].
						local job_base = #content_lines
						table.insert(pipeline_job_boxes, {
							row = job_base + job_region.row + 1,
							height = job_region.height,
							id = job_key(job),
						})
						for _, jline in ipairs(job_lines) do
							table.insert(content_lines, jline)
						end
						for _, jspan in ipairs(job_highlights) do
							table.insert(content_highlights, {
								line = job_base + jspan.line,
								start_col = jspan.start_col,
								end_col = jspan.end_col,
								hl_group = jspan.hl_group,
							})
						end
					end
				end
			end
			if not any_jobs then
				local text = string.rep(" ", BASE_PAD) .. "No jobs found."
				table.insert(content_lines, text)
				table.insert(
					content_highlights,
					{ line = #content_lines - 1, start_col = 0, end_col = #text, hl_group = "AtlasTextMuted" }
				)
			end
		end
	end

	local box_lines, box_highlights = bordered_box.render({
		width = box_width,
		box_width = box_width,
		title = pipeline.name,
		title_right = duration_text(pipeline.duration),
		content_lines = content_lines,
		content_highlights = content_highlights,
		border_hl = border_hl,
		bottom_hint = bottom_hint,
		bottom_hint_highlights = bottom_hint_highlights,
	})
	indent_block(box_lines, box_highlights, PADDING_X)

	-- Column/width are unused: this tab only ever moves the cursor to column
	-- 0 of a region's row (see keymaps.lua), unlike Review's regions which
	-- also anchor an inline-edit overlay.
	local base = #lines
	state.regions[id] = { row = base + 1, col = 1, width = box_width - 2, height = 1 }
	for _, entry in ipairs(pipeline_job_boxes) do
		state.regions[entry.id] = { row = base + entry.row, col = 1, width = box_width - 2, height = entry.height }
	end

	for _, line in ipairs(box_lines) do
		table.insert(lines, line)
	end
	for _, span in ipairs(box_highlights) do
		table.insert(spans, { line = base + span.line, start_col = span.start_col, end_col = span.end_col, hl_group = span.hl_group })
	end
	for i = 1, #box_lines do
		line_map[base + i] = { kind = "pipeline", pipeline = pipeline }
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
	local lines, spans, line_map = {}, {}, {}
	state.navigable = {}
	state.regions = {}

	for _, pipeline in ipairs(pipelines) do
		append_pipeline_box(lines, spans, line_map, pr, pipeline, width, ensure_pipeline_details, ensure_job_log)
		table.insert(lines, "")
	end

	return lines, spans, line_map
end

return M
