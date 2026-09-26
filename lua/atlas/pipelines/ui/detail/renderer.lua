local M = {}

local utils = require("atlas.ui.shared.utils")
local highlights = require("atlas.ui.shared.highlights")
local bordered_box = require("atlas.ui.components.bordered_box")
local ui_utils = require("atlas.ui.utils")
local spinner = require("atlas.ui.components.spinner")
local state = require("atlas.pipelines.ui.detail.state")
local detail_ui = require("atlas.ui.detail")
local graph = require("atlas.pipelines.ui.detail.components.graph")
local tabs = require("atlas.ui.components.tabs")
-- Log line splitting/classification is generic text handling with no PR
-- coupling, despite living under the pulls tree (it backs that domain's own
-- inline job-log viewer) -- reused as-is rather than duplicated or relocated.
local pipeline_logs = require("atlas.pulls.ui.pipelines.logs")

local ns = vim.api.nvim_create_namespace("atlas.pipelines.detail")
local header_ns = vim.api.nvim_create_namespace("atlas.pipelines.detail.header")

---@param buf integer|nil
---@param lines string[]
local function set_lines(buf, lines)
	if buf == nil or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
end

---@param iso string|nil
---@return string
local function format_dt(iso)
	local text = utils.format_datetime_short(iso)
	return text ~= "" and text or "-"
end

---@param left string Byte-safe: appended to `right` via plain string concatenation.
---@param right string
---@param interior_width integer
---@return string row, integer right_start Byte offset (into `row`) where `right` begins.
local function two_column_row(left, right, interior_width)
	local gap = math.max(1, interior_width - ui_utils.text_width(left) - ui_utils.text_width(right))
	local row = left .. string.rep(" ", gap) .. right
	return row, #row - #right
end

---@param pipeline Pipeline
---@return string title
---@return table[] highlights Spans relative to `title`.
local function box_title(pipeline)
	local hl = graph.state_hl(pipeline.state)
	local id_text = string.format("#%s", tostring(pipeline.id or ""))
	local duration_text = utils.human_duration(pipeline.duration)
	local title = duration_text == "" and id_text or (id_text .. " - " .. duration_text)
	return title, { { start_col = 0, end_col = #title, hl_group = hl } }
end

--- Renders the sticky header's single box (the "top part"): Start/End +
--- branch/commit on its first two lines, then the stage/job graph below,
--- with the active stage's border highlighted blue. The bottom part
--- (content window below) shows that stage's job logs -- see render_job_log.
---@param pipeline Pipeline
---@param width integer Header window width the box should fill.
---@return string[] lines
---@return table[] highlights
local function render_header_box(pipeline, width)
	local box_width = math.max(4, width)
	local interior_width = box_width - 2

	local start_text = "Start: " .. format_dt(pipeline.started_at or pipeline.created_at)
	local end_text = "End: " .. format_dt(pipeline.finished_at)
	local branch = tostring(pipeline.ref or "")
	local commit = tostring(pipeline.short_sha or pipeline.sha or "")
	-- Branch renders as a colored-background tag/chip; commit stays plain
	-- (dynamic) foreground text.
	local branch_tag = branch ~= "" and string.format(" %s ", branch) or ""
	local branch_hl = branch ~= "" and (highlights.dynamic_for_bg(branch) or "Normal") or "Normal"
	local commit_hl = highlights.dynamic_for(commit) or "Normal"

	local row1, branch_start = two_column_row(start_text, branch_tag, interior_width)
	local row2, commit_start = two_column_row(end_text, commit, interior_width)

	local content_lines = { row1, row2 }
	local content_highlights = {
		{ line = 0, start_col = 0, end_col = #start_text, hl_group = "AtlasTextMuted" },
		{ line = 0, start_col = branch_start, end_col = branch_start + #branch_tag, hl_group = branch_hl },
		{ line = 1, start_col = 0, end_col = #end_text, hl_group = "AtlasTextMuted" },
		{ line = 1, start_col = commit_start, end_col = commit_start + #commit, hl_group = commit_hl },
	}

	if state.details_loading and #(pipeline.stages or {}) == 0 then
		utils.push(content_lines, content_highlights, spinner.with_text("Loading pipeline..."), "AtlasTextMuted")
	else
		local graph_lines, graph_spans = graph.render(pipeline, interior_width, state.active_stage)
		utils.append_block(content_lines, content_highlights, { lines = graph_lines, highlights = graph_spans })
	end

	local title, title_highlights = box_title(pipeline)
	return bordered_box.render({
		width = box_width,
		box_width = box_width,
		title = title,
		title_highlights = title_highlights,
		border_hl = graph.state_hl(pipeline.state),
		content_lines = content_lines,
		content_highlights = content_highlights,
	})
end

--- Renders the bottom part: the active stage's jobs as tabs (shown in the
--- content window's own native title, like the issue/pulls detail views'
--- top-level tabs), and the active job's log as the window's plain buffer
--- content -- so it gets a real, scrollable, line-numbered buffer instead of
--- hand-drawn gutter text.
---@param pipeline Pipeline
---@param ensure_job_log fun(pipeline: Pipeline, job: PipelineJob)
---@return string[] lines
---@return table[] highlights
---@return { [1]: string, [2]: string }[] title_chunks
---@return string border_hl
---@return boolean show_line_numbers
local function render_job_log(pipeline, ensure_job_log)
	local stages = pipeline.stages or {}
	if #stages == 0 then
		return { "", "  No stages available." }, {}, {}, "AtlasBorder", false
	end

	local stage_index = math.max(1, math.min(#stages, state.active_stage))
	state.active_stage = stage_index
	local stage = stages[stage_index]

	local jobs = stage.jobs or {}
	if #jobs == 0 then
		local lines, highlights = {}, {}
		if state.details_loading then
			utils.push(lines, highlights, spinner.with_text("Loading jobs..."), "AtlasTextMuted")
		else
			lines = { "", "  No jobs in this stage." }
		end
		return lines, highlights, {}, "AtlasTextMuted", false
	end

	local job_index = math.max(1, math.min(#jobs, state.active_job_index(stage_index)))
	state.active_job_by_stage[stage_index] = job_index
	local job = jobs[job_index]

	local tab_items = {}
	for _, j in ipairs(jobs) do
		table.insert(tab_items, { key = tostring(j.id), label = tostring(j.name or "job") })
	end
	local title_chunks = {}
	if #tab_items > 1 then
		title_chunks = tabs.title_chunks(tab_items, tostring(job.id), {
			active_hl = "AtlasDetailTabActive",
			inactive_hl = "AtlasTextMuted",
			gap = " - ",
			border_hl = graph.state_hl(job.state),
		})
	end

	ensure_job_log(pipeline, job)
	local log_entry = state.log_by_job_id[tostring(job.id)]

	local lines, highlights = {}, {}
	local show_line_numbers = false
	if log_entry == nil or log_entry.status == "loading" then
		utils.push(lines, highlights, spinner.with_text("Loading log..."), "AtlasTextMuted")
	elseif log_entry.status == "error" then
		utils.push(lines, highlights, tostring(log_entry.text or "Failed to load job log"), "AtlasLogError")
	else
		local log_lines = pipeline_logs.split_log_lines(log_entry.text)
		if #log_lines == 0 then
			utils.push(lines, highlights, "(empty log)", "AtlasTextMuted")
		else
			show_line_numbers = true
			for i, line in ipairs(log_lines) do
				table.insert(lines, line)
				local hl = pipeline_logs.classify_log_line(line)
				if hl then
					table.insert(highlights, { line = i - 1, start_col = 0, end_col = #line, hl_group = hl })
				end
			end
		end
	end

	return lines, highlights, title_chunks, graph.state_hl(job.state), show_line_numbers
end

---@param ensure_job_log fun(pipeline: Pipeline, job: PipelineJob)
function M.render(ensure_job_log)
	local buf = state.buf
	local win = state.win
	if buf == nil or win == nil then
		return
	end
	if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_win_is_valid(win) then
		return
	end

	local pipeline = state.current_pipeline
	local header_win = state.header_win
	local header_buf = state.header_buf
	local has_header = utils.window.valid(header_win) and utils.buffer.valid(header_buf)

	if has_header then
		local header_lines, header_spans = {}, {}
		if pipeline ~= nil then
			header_lines, header_spans = render_header_box(pipeline, vim.api.nvim_win_get_width(header_win))
		end
		set_lines(header_buf, header_lines)
		utils.apply_spans(header_buf, header_ns, header_spans)
		detail_ui.resize_header(#header_lines)
	end

	local lines, spans = {}, {}
	local title_chunks, border_hl, show_line_numbers = {}, "AtlasBorder", false

	if pipeline == nil then
		lines = { "", "  Nothing selected..." }
	else
		lines, spans, title_chunks, border_hl, show_line_numbers = render_job_log(pipeline, ensure_job_log)
	end

	detail_ui.set_content_title(title_chunks)
	detail_ui.set_content_border(border_hl)
	vim.api.nvim_set_option_value("number", show_line_numbers, { win = win, scope = "local" })

	set_lines(buf, lines)
	utils.apply_spans(buf, ns, spans)
end

return M
