local M = {}

local utils = require("atlas.ui.shared.utils")
local highlights = require("atlas.ui.shared.highlights")
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

--- Renders the Start/End (left) + branch/commit (right) summary rows, as
--- plain content lines -- these are meant to sit inside the pipeline's own
--- bordered/titled content window (see M.render), not a box of their own.
---@param pipeline Pipeline
---@param width integer
---@return string[] lines
---@return table[] highlights
local function render_summary_lines(pipeline, width)
	local start_text = "Start: " .. format_dt(pipeline.started_at or pipeline.created_at)
	local end_text = "End: " .. format_dt(pipeline.finished_at)
	local branch = tostring(pipeline.ref or "")
	local commit = tostring(pipeline.short_sha or pipeline.sha or "")
	local branch_hl = highlights.dynamic_for(branch) or "Normal"
	local commit_hl = highlights.dynamic_for(commit) or "Normal"

	local row1, branch_start = two_column_row(start_text, branch, width)
	local row2, commit_start = two_column_row(end_text, commit, width)

	return { row1, row2 },
		{
			{ line = 0, start_col = 0, end_col = #start_text, hl_group = "AtlasTextMuted" },
			{ line = 0, start_col = branch_start, end_col = branch_start + #branch, hl_group = branch_hl },
			{ line = 1, start_col = 0, end_col = #end_text, hl_group = "AtlasTextMuted" },
			{ line = 1, start_col = commit_start, end_col = commit_start + #commit, hl_group = commit_hl },
		}
end

---@param pipeline Pipeline
---@return { [1]: string, [2]: string }[]
local function title_chunks(pipeline)
	local hl = graph.state_hl(pipeline.state)
	local id_text = string.format("#%s", tostring(pipeline.id or ""))
	local duration_text = utils.human_duration(pipeline.duration)
	if duration_text == "" then
		return { { id_text, hl } }
	end
	return { { id_text, hl }, { "  ", hl }, { duration_text, hl } }
end

---@param pipeline Pipeline|nil
---@return string
local function content_border_hl(pipeline)
	if pipeline == nil then
		return "AtlasBorder"
	end
	return graph.state_hl(pipeline.state)
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

	-- Everything lives in one box now: the pipeline's own bordered/titled
	-- content window. The sticky header above it stays, but empty, until
	-- something else needs that space.
	if has_header then
		set_lines(header_buf, {})
		utils.apply_spans(header_buf, header_ns, {})
		detail_ui.resize_header(0)
	end

	detail_ui.set_content_title(pipeline and title_chunks(pipeline) or nil)
	detail_ui.set_content_border(content_border_hl(pipeline))

	local width = vim.api.nvim_win_get_width(win)
	local lines, spans = {}, {}

	if pipeline == nil then
		lines = { "", "  Nothing selected..." }
	else
		local summary_lines, summary_spans = render_summary_lines(pipeline, width)
		utils.append_block(lines, spans, { lines = summary_lines, highlights = summary_spans })
		table.insert(lines, "")

		if state.details_loading and #(pipeline.stages or {}) == 0 then
			utils.push(lines, spans, spinner.with_text("Loading pipeline..."), "AtlasTextMuted", 2)
		else
			local graph_lines, graph_spans = graph.render(pipeline, width)
			utils.append_block(lines, spans, { lines = graph_lines, highlights = graph_spans })
		end
	end

	set_lines(buf, lines)
	utils.apply_spans(buf, ns, spans)
end

return M
