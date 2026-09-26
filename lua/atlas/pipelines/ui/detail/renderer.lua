local M = {}

local utils = require("atlas.ui.shared.utils")
local highlights = require("atlas.ui.shared.highlights")
local field_box = require("atlas.ui.components.field_box")
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

---@param pipeline Pipeline
---@return table
local function start_field(pipeline)
	return { kind = "text", value = "Start: " .. format_dt(pipeline.started_at or pipeline.created_at), hl = "AtlasTextMuted" }
end

---@param pipeline Pipeline
---@return table
local function end_field(pipeline)
	return { kind = "text", value = "End: " .. format_dt(pipeline.finished_at), hl = "AtlasTextMuted" }
end

---@param label string
---@param value string
---@param value_hl string
---@return table
local function labeled_colored_field(label, value)
	local text = label .. value
	local value_hl = highlights.dynamic_for(value) or "Normal"
	return {
		kind = "text",
		value = text,
		hl = {
			{ start_col = 0, end_col = #label, hl_group = "AtlasTextMuted" },
			{ start_col = #label, end_col = #text, hl_group = value_hl },
		},
	}
end

---@param pipeline Pipeline
---@return table
local function in_field(pipeline)
	return labeled_colored_field("In: ", tostring(pipeline.ref or ""))
end

---@param pipeline Pipeline
---@return table
local function on_field(pipeline)
	return labeled_colored_field("On: ", tostring(pipeline.short_sha or pipeline.sha or ""))
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

	if has_header then
		local header_lines, header_spans = {}, {}
		if pipeline ~= nil then
			header_lines, header_spans = field_box.render(
				{ start_field(pipeline), in_field(pipeline), end_field(pipeline), on_field(pipeline) },
				{ width = vim.api.nvim_win_get_width(header_win) }
			)
		end
		set_lines(header_buf, header_lines)
		utils.apply_spans(header_buf, header_ns, header_spans)
		detail_ui.resize_header(#header_lines)
	end

	detail_ui.set_content_title(pipeline and title_chunks(pipeline) or nil)
	detail_ui.set_content_border(content_border_hl(pipeline))

	local width = vim.api.nvim_win_get_width(win)
	local lines, spans = {}, {}

	if pipeline == nil then
		lines = { "", "  Nothing selected..." }
	elseif state.details_loading and #(pipeline.stages or {}) == 0 then
		utils.push(lines, spans, spinner.with_text("Loading pipeline..."), "AtlasTextMuted", 2)
	else
		lines, spans = graph.render(pipeline, width)
	end

	set_lines(buf, lines)
	utils.apply_spans(buf, ns, spans)
end

return M
