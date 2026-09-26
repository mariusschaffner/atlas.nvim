local M = {}

local bordered_box = require("atlas.ui.components.bordered_box")
local dashboard_host = require("atlas.ui.dashboard")
local filter_bar = require("atlas.ui.filter_bar")
local help = require("atlas.ui.popups.help")
local ui_state = require("atlas.ui.state")
local ns = vim.api.nvim_create_namespace("atlas.ui")

-- Top + bottom border rows the table box adds around the domain body.
local BOX_BORDER_LINES = 2

---@type AtlasFieldBoxRegion|nil
local filter_region = nil

--- The filter bar's interior region from the last render, for anchoring an
--- inline field edit overlay (`ui.filter` keymap). nil before the first render.
---@return AtlasFieldBoxRegion|nil
function M.filter_region()
	return filter_region
end

---@param buf integer
---@param spans table[]
local function apply_spans(buf, spans)
	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	for _, span in ipairs(spans) do
		if span.line_hl_group ~= nil then
			vim.api.nvim_buf_set_extmark(buf, ns, span.line, 0, {
				line_hl_group = span.line_hl_group,
			})
		else
			vim.api.nvim_buf_set_extmark(buf, ns, span.line, span.start_col, {
				end_row = span.line,
				end_col = span.end_col,
				hl_group = span.hl_group,
			})
		end
	end
end

---@param key string
---@return string
local function clean_key(key)
	return (key:gsub("[<>]", ""))
end

--- Builds the "[key] - desc - [key] - desc - ..." string embedded in the
--- table box's bottom border, from the same per-buffer keymap registry the
--- statusline's hint fallback reads (see `atlas.ui.popups.help`).
---@param buf integer
---@return string
local function table_box_hint(buf)
	local parts = {}
	for _, hint in ipairs(help.hints(buf)) do
		table.insert(parts, string.format("[%s] - %s", clean_key(hint.key), hint.desc))
	end
	return table.concat(parts, " - ")
end

--- Renders the filter bar plus a domain-specific body into the dashboard
--- buffer, the body wrapped in its own bordered box (title "Table", grey
--- non-editable chrome, keybinding hints embedded in the bottom border).
---@param render_body fun(width: integer, height: integer, bar_lines: integer): string[], table[], table<integer, table>
function M.render(render_body)
	local win = dashboard_host.win()
	local buf = dashboard_host.buf()
	if win == nil or buf == nil then
		return
	end

	local width = vim.api.nvim_win_get_width(win)
	local height = vim.api.nvim_win_get_height(win)

	local bar_lines, bar_spans, bar_region = filter_bar.render(dashboard_host.domain(), width)
	filter_region = bar_region

	local interior_width = math.max(1, width - 2)
	local available_body_height = math.max(0, height - #bar_lines - BOX_BORDER_LINES)
	-- Reserve the box's first interior row for a blank spacer above the
	-- table header, so the domain renderer's own row budget stays accurate.
	local table_budget_height = math.max(0, available_body_height - 1)
	local body_lines, body_spans, body_line_map = render_body(interior_width, table_budget_height, #bar_lines)

	local content_lines = { "" }
	vim.list_extend(content_lines, body_lines)
	local content_highlights = {}
	for _, span in ipairs(body_spans) do
		local shifted = vim.tbl_extend("force", {}, span)
		shifted.line = span.line + 1
		table.insert(content_highlights, shifted)
	end

	for _ = #content_lines + 1, available_body_height do
		table.insert(content_lines, "")
	end

	local box_lines, box_spans = bordered_box.render({
		width = width,
		box_width = width,
		title = "Table",
		content_lines = content_lines,
		content_highlights = content_highlights,
		border_hl = "AtlasBorder",
		bottom_hint = table_box_hint(buf),
	})

	local lines = vim.list_extend({}, bar_lines)
	vim.list_extend(lines, box_lines)

	local spans = vim.list_extend({}, bar_spans)
	local box_offset = #bar_lines
	for _, span in ipairs(box_spans) do
		local shifted = vim.tbl_extend("force", {}, span)
		shifted.line = span.line + box_offset
		table.insert(spans, shifted)
	end

	-- +1 for the box's own top-border line and +1 for the blank spacer row,
	-- both of which now sit between the filter bar and the first table row.
	local line_map = {}
	local content_offset = box_offset + 2
	for lnum, entry in pairs(body_line_map) do
		line_map[lnum + content_offset] = entry
	end
	ui_state.line_map = line_map

	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	apply_spans(buf, spans)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
end

return M
