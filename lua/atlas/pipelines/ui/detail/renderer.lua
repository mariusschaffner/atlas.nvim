local M = {}

local utils = require("atlas.ui.shared.utils")
local highlights = require("atlas.ui.shared.highlights")
local bordered_box = require("atlas.ui.components.bordered_box")
local ui_utils = require("atlas.ui.utils")
local spinner = require("atlas.ui.components.spinner")
local state = require("atlas.pipelines.ui.detail.state")
local detail_ui = require("atlas.ui.detail")
local graph = require("atlas.pipelines.ui.detail.components.graph")

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
	local title = duration_text == "" and id_text or (id_text .. "  " .. duration_text)
	return title, { { start_col = 0, end_col = #title, hl_group = hl } }
end

--- Renders the sticky header's single box: Start/End + branch/commit on its
--- first two lines, then the stage/job graph below -- everything the
--- pipeline detail view currently shows lives in this one box. The bottom
--- part (content window below the header) is unused for now.
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
	local branch_hl = highlights.dynamic_for(branch) or "Normal"
	local commit_hl = highlights.dynamic_for(commit) or "Normal"

	local row1, branch_start = two_column_row(start_text, branch, interior_width)
	local row2, commit_start = two_column_row(end_text, commit, interior_width)

	local content_lines = { row1, row2, "" }
	local content_highlights = {
		{ line = 0, start_col = 0, end_col = #start_text, hl_group = "AtlasTextMuted" },
		{ line = 0, start_col = branch_start, end_col = branch_start + #branch, hl_group = branch_hl },
		{ line = 1, start_col = 0, end_col = #end_text, hl_group = "AtlasTextMuted" },
		{ line = 1, start_col = commit_start, end_col = commit_start + #commit, hl_group = commit_hl },
	}

	if state.details_loading and #(pipeline.stages or {}) == 0 then
		utils.push(content_lines, content_highlights, spinner.with_text("Loading pipeline..."), "AtlasTextMuted")
	else
		local graph_lines, graph_spans = graph.render(pipeline, interior_width)
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

function M.render()
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

	-- Everything currently lives in the header's single box above; the
	-- content window (bottom part) is unused until something needs it.
	detail_ui.set_content_title(nil)
	detail_ui.set_content_border(nil)

	local lines, spans = {}, {}
	if pipeline == nil then
		lines = { "", "  Nothing selected..." }
	end

	set_lines(buf, lines)
	utils.apply_spans(buf, ns, spans)
end

return M
