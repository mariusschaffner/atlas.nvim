local M = {}

local dashboard_host = require("atlas.ui.dashboard")
local dashboard_tabs = require("atlas.ui.dashboard_tabs")
local ui_state = require("atlas.ui.state")
local ns = vim.api.nvim_create_namespace("atlas.ui")

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

--- Renders the tab bar plus a domain-specific body into the dashboard buffer.
---@param render_body fun(width: integer, height: integer, tab_lines: integer): string[], table[], table<integer, table>
function M.render(render_body)
	local win = dashboard_host.win()
	local buf = dashboard_host.buf()
	if win == nil or buf == nil then
		return
	end

	local width = vim.api.nvim_win_get_width(win)
	local height = vim.api.nvim_win_get_height(win)

	local tab_lines, tab_spans = dashboard_tabs.render(dashboard_host.domain(), width)
	local body_lines, body_spans, body_line_map = render_body(width, height, #tab_lines)

	local lines = vim.list_extend({}, tab_lines)
	vim.list_extend(lines, body_lines)

	local spans = vim.list_extend({}, tab_spans)
	local offset = #tab_lines
	for _, span in ipairs(body_spans) do
		local shifted = vim.tbl_extend("force", {}, span)
		shifted.line = span.line + offset
		table.insert(spans, shifted)
	end

	local line_map = {}
	for lnum, entry in pairs(body_line_map) do
		line_map[lnum + offset] = entry
	end
	ui_state.line_map = line_map

	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	apply_spans(buf, spans)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
end

return M
