local M = {}

local utils = require("atlas.ui.shared.utils")
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

--- Renders the sticky header's single box (the "top part"): the stage/job
--- graph, with the active stage's border highlighted blue. The bottom part
--- (content window below) shows that stage's job logs -- see render_job_log.
---@param pipeline Pipeline
---@param width integer Header window width the box should fill.
---@return string[] lines
---@return table[] highlights
local function render_header_box(pipeline, width)
	local box_width = math.max(4, width)
	local interior_width = box_width - 2

	local content_lines, content_highlights = {}, {}

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

--- Appends a parsed log tree to `lines`/`highlights`, rendering GitLab CI
--- sections as collapsible headers (fold icon + name + duration) using
--- `state.collapsed_sections`, and recording each header's buffer line in
--- `state.section_headers` so the toggle-fold keymap can find it from the
--- cursor. `path_prefix` is the section-key path down to this point (joined
--- with the job id it belongs to forms the fold key).
---@param entries AtlasLogEntry[]
---@param job_id string
---@param path_prefix string
---@param depth integer
---@param lines string[]
---@param highlights table[]
local function append_log_tree(entries, job_id, path_prefix, depth, lines, highlights)
	local indent = string.rep("  ", depth)
	for _, entry in ipairs(entries) do
		if entry.kind == "group" then
			local path = path_prefix .. "/" .. entry.key
			local key = job_id .. "\0" .. path
			local collapsed = state.collapsed_sections[key] == true
			local duration_text = entry.duration and (" (" .. pipeline_logs.format_duration(entry.duration) .. ")") or ""
			local text = indent .. (collapsed and "▸ " or "▾ ") .. entry.name .. duration_text
			table.insert(lines, text)
			table.insert(highlights, { line = #lines - 1, start_col = 0, end_col = #text, hl_group = "AtlasColumnHeader" })
			state.section_headers[#lines] = key
			if not collapsed then
				append_log_tree(entry.entries, job_id, path, depth + 1, lines, highlights)
			end
		else
			local text = indent .. entry.text
			table.insert(lines, text)
			local hl = pipeline_logs.classify_log_line(entry.text)
			if hl then
				table.insert(highlights, { line = #lines - 1, start_col = #indent, end_col = #text, hl_group = hl })
			end
		end
	end
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

	-- Rebuilt below if the log renders successfully -- cleared unconditionally
	-- first so a stale mapping from a previous job/render never lingers.
	state.section_headers = {}

	local lines, highlights = {}, {}
	local show_line_numbers = false
	if log_entry == nil or log_entry.status == "loading" then
		utils.push(lines, highlights, spinner.with_text("Loading log..."), "AtlasTextMuted")
	elseif log_entry.status == "error" then
		utils.push(lines, highlights, tostring(log_entry.text or "Failed to load job log"), "AtlasLogError")
	else
		local entries = pipeline_logs.parse(log_entry.text)
		if #entries == 0 then
			utils.push(lines, highlights, "(empty log)", "AtlasTextMuted")
		else
			show_line_numbers = true
			append_log_tree(entries, tostring(job.id), "", 0, lines, highlights)
		end
	end

	return lines, highlights, title_chunks, graph.state_hl(job.state), show_line_numbers
end

-- Last-applied sticky header render, so switching job tabs (which re-renders
-- the whole panel, header included, even though the header only depicts the
-- active *stage*, not the active job) doesn't needlessly re-set the header
-- buffer/extmarks/window height when nothing in it actually changed.
---@type { buf: integer|nil, signature: string|nil }
local last_header = { buf = nil, signature = nil }

---@param lines string[]
---@param spans table[]
---@return string
local function header_signature(lines, spans)
	return table.concat(lines, "\n") .. "\0" .. vim.inspect(spans)
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

		local signature = header_signature(header_lines, header_spans)
		if last_header.buf ~= header_buf or last_header.signature ~= signature then
			last_header.buf = header_buf
			last_header.signature = signature
			set_lines(header_buf, header_lines)
			utils.apply_spans(header_buf, header_ns, header_spans)
			detail_ui.resize_header(#header_lines)
		end
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

	-- Content is fully replaced on every render (streaming polls included),
	-- which would otherwise reset scroll position -- most noticeably when
	-- toggling a fold shifts the line count out from under the cursor.
	local view
	pcall(vim.api.nvim_win_call, win, function()
		view = vim.fn.winsaveview()
	end)
	set_lines(buf, lines)
	utils.apply_spans(buf, ns, spans)
	if view then
		pcall(vim.api.nvim_win_call, win, function()
			vim.fn.winrestview(view)
		end)
	end
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
