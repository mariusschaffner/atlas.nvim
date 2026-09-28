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
	local left_w = ui_utils.text_width(left)
	-- `right` (the branch chip / commit) is what has to give on a narrow
	-- window -- `left` (the "Start:"/"End:" label) always stays intact.
	-- Without this, a `right` too wide for what's left of `interior_width`
	-- produced a row wider than the box itself, and bordered_box.lua's own
	-- (structure-blind) truncation would then chop the row whole, sometimes
	-- eating almost all of the branch/commit text instead of just its tail.
	local available_for_right = math.max(0, interior_width - left_w - 1)
	if ui_utils.text_width(right) > available_for_right then
		right = utils.truncate(right, available_for_right)
	end
	local gap = math.max(1, interior_width - left_w - ui_utils.text_width(right))
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

---@param pstate PipelineState|string|nil
---@return boolean
local function is_running(pstate)
	return tostring(pstate or ""):upper() == "INPROGRESS"
end

--- Builds the job-log box's native title: the job tabs (as before), plus --
--- while `streaming` -- a right-aligned "<spinner> Live" indicator flush
--- against the top-right corner, filled in with border dashes so it reads as
--- part of the border rather than floating text (mirrors
--- `bordered_box.lua`'s own `title`/`title_right` split, adapted to a native
--- floating-window title's single string instead of hand-drawn buffer text).
---@param tab_items { key: string, label: string }[]
---@param active_job_id string
---@param border_hl string
---@param streaming boolean
---@param width integer Content window width -- matches the span the native title is drawn across.
---@return { [1]: string, [2]: string }[]
local function job_log_title(tab_items, active_job_id, border_hl, streaming, width)
	local chunks = tabs.title_chunks(tab_items, active_job_id, {
		active_hl = "AtlasDetailTabActive",
		inactive_hl = "AtlasTextMuted",
		gap = " - ",
		border_hl = border_hl,
	})
	if not streaming then
		return chunks
	end

	local left_width = 0
	for _, chunk in ipairs(chunks) do
		left_width = left_width + ui_utils.text_width(chunk[1])
	end

	local right_part = string.format(" %s Live ", spinner.frame())
	local right_width = ui_utils.text_width(right_part) + 1 -- trailing dash before the corner

	local fill = math.max(0, width - left_width - right_width)
	if fill > 0 then
		table.insert(chunks, { string.rep("─", fill), border_hl })
	end
	table.insert(chunks, { right_part, "AtlasTextWarning" })
	table.insert(chunks, { "─", border_hl })
	return chunks
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

	-- Always titled, even with a single job -- unlike the issue/pulls detail
	-- views' own tab bar (which hides entirely for one tab), a lone job's
	-- name is still worth showing so the box says what log is in it.
	local tab_items = {}
	for _, j in ipairs(jobs) do
		table.insert(tab_items, { key = tostring(j.id), label = tostring(j.name or "job") })
	end
	local title_chunks = job_log_title(
		tab_items,
		tostring(job.id),
		graph.state_hl(job.state),
		is_running(job.state),
		vim.api.nvim_win_get_width(state.win)
	)

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
				local row = i - 1

				-- Only the leading timestamp (if any) gets its own color; the
				-- message always stays the buffer's plain foreground. This used
				-- to also classify the message itself (error/warning/etc.),
				-- but that made lines look inconsistently colored depending on
				-- content -- some jobs' output was effectively all grey, others
				-- all white, with no way to tell which was "normal". Uniform
				-- foreground + a muted timestamp prefix reads consistently
				-- across every job's log.
				local ts_end = pipeline_logs.timestamp_end(line)
				if ts_end and ts_end > 0 then
					table.insert(highlights, { line = row, start_col = 0, end_col = ts_end, hl_group = "AtlasTextMuted" })
				end
			end
		end
	end

	return lines, highlights, title_chunks, graph.state_hl(job.state), show_line_numbers
end

-- render_header_box always emits exactly: top border, the Start/branch row,
-- the End/commit row, then the dynamic part (loading spinner or the
-- stage/job graph) down to the bottom border. Rows [0, HEADER_STATIC_LINES)
-- are that fixed lead-in -- the only rows two_column_row's branch/commit
-- chips ever live on.
local HEADER_STATIC_LINES = 3

-- Last-applied sticky header render. Switching job tabs, and (once pipelines
-- live-poll while running) every few seconds of a running pipeline, both
-- re-render the whole panel, header included, even though the header's
-- static rows -- Start/End, branch, commit -- never actually change; only
-- the graph rows below them do, as job states update. A single whole-buffer
-- rewrite couldn't tell the two apart, so any graph-only change still
-- cleared and redrew the branch/commit rows too, visible as that corner
-- flickering every poll tick. Diffing and patching the two regions
-- independently (see sync_header_region) means the static rows are now only
-- ever touched when their own text actually changes -- practically never
-- for the lifetime of a single pipeline.
---@type { buf: integer|nil, lines: string[], spans: table[] }
local last_header = { buf = nil, lines = {}, spans = {} }

---@param lines string[]
---@param spans table[]
---@param from integer 0-indexed inclusive start row.
---@param to integer|nil 0-indexed exclusive end row, or nil for "through the last line" (the dynamic region, whose row count can itself change between renders).
---@return string
local function header_region_signature(lines, spans, from, to)
	local slice = {}
	for i = from + 1, (to or #lines) do
		table.insert(slice, lines[i])
	end
	local region_spans = {}
	for _, span in ipairs(spans) do
		local line = span.line or 0
		if line >= from and (to == nil or line < to) then
			table.insert(region_spans, span)
		end
	end
	return table.concat(slice, "\n") .. "\0" .. vim.inspect(region_spans)
end

---@param buf integer
---@param ns integer
---@param from integer
---@param to integer|nil
---@param lines string[]
---@param spans table[]
local function apply_header_region(buf, ns, from, to, lines, spans)
	local slice = {}
	for i = from + 1, (to or #lines) do
		table.insert(slice, lines[i])
	end
	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_buf_set_lines(buf, from, to or -1, false, slice)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

	vim.api.nvim_buf_clear_namespace(buf, ns, from, to or -1)
	for _, span in ipairs(spans) do
		local line = span.line or 0
		if line >= from and (to == nil or line < to) then
			if span.line_hl_group ~= nil then
				vim.api.nvim_buf_set_extmark(buf, ns, line, 0, { line_hl_group = span.line_hl_group })
			else
				vim.api.nvim_buf_set_extmark(buf, ns, line, span.start_col, {
					end_row = line,
					end_col = span.end_col,
					hl_group = span.hl_group,
				})
			end
		end
	end
end

--- Re-applies rows `[from, to)` of the header buffer only if that region's
--- own text/highlights actually changed since the last render.
---@param buf integer
---@param ns integer
---@param from integer
---@param to integer|nil
---@param old_lines string[]
---@param old_spans table[]
---@param new_lines string[]
---@param new_spans table[]
---@return boolean changed
local function sync_header_region(buf, ns, from, to, old_lines, old_spans, new_lines, new_spans)
	if
		header_region_signature(old_lines, old_spans, from, to) == header_region_signature(new_lines, new_spans, from, to)
	then
		return false
	end
	apply_header_region(buf, ns, from, to, new_lines, new_spans)
	return true
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

		local any_changed
		if last_header.buf ~= header_buf or #last_header.lines == 0 or #header_lines == 0 then
			-- New header buffer (fresh `detail.open()`), or a nil<->pipeline
			-- transition -- nothing to diff against, so just write it all.
			set_lines(header_buf, header_lines)
			utils.apply_spans(header_buf, header_ns, header_spans)
			any_changed = true
		else
			local static_changed = sync_header_region(
				header_buf,
				header_ns,
				0,
				HEADER_STATIC_LINES,
				last_header.lines,
				last_header.spans,
				header_lines,
				header_spans
			)
			local dynamic_changed = sync_header_region(
				header_buf,
				header_ns,
				HEADER_STATIC_LINES,
				nil,
				last_header.lines,
				last_header.spans,
				header_lines,
				header_spans
			)
			any_changed = static_changed or dynamic_changed
		end
		-- Only touches the window at all (resize_header internally repositions
		-- the content float too) when something in the header actually
		-- changed -- on top of resize_header's own no-op guard, this avoids
		-- even asking for a resize on a render that turned out to be a no-op.
		if any_changed then
			detail_ui.resize_header(#header_lines)
		end

		last_header.buf = header_buf
		last_header.lines = header_lines
		last_header.spans = header_spans
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

--- Re-applies just the job-log box's native title (job tabs + the "Live"
--- streaming indicator's spinner frame), skipping the header and log buffer
--- entirely. Called on every streaming-animation tick (see
--- `pipelines/ui/detail/init.lua`) so the indicator visibly animates without
--- paying for (or risking flicker from) a full re-render every tick.
function M.update_streaming_indicator()
	local win = state.win
	local pipeline = state.current_pipeline
	if win == nil or not vim.api.nvim_win_is_valid(win) or pipeline == nil then
		return
	end

	local stages = pipeline.stages or {}
	local stage_index = math.max(1, math.min(#stages, state.active_stage))
	local stage = stages[stage_index]
	local jobs = stage and stage.jobs or {}
	if #jobs == 0 then
		return
	end

	local job_index = math.max(1, math.min(#jobs, state.active_job_index(stage_index)))
	local job = jobs[job_index]
	if not is_running(job.state) then
		return
	end

	local tab_items = {}
	for _, j in ipairs(jobs) do
		table.insert(tab_items, { key = tostring(j.id), label = tostring(j.name or "job") })
	end
	local title_chunks =
		job_log_title(tab_items, tostring(job.id), graph.state_hl(job.state), true, vim.api.nvim_win_get_width(win))
	detail_ui.set_content_title(title_chunks)
end

return M
