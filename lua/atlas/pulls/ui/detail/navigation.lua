local M = {}

local state = require("atlas.pulls.ui.detail.state")

---@return integer|nil win, integer|nil buf, table<integer, table>|nil line_map
local function active_pane()
	local current = vim.api.nvim_get_current_win()
	if current == state.win and vim.api.nvim_win_is_valid(state.win) and vim.api.nvim_buf_is_valid(state.buf) then
		return state.win, state.buf, state.line_map
	end
	if
		current == state.side_win
		and state.side_win ~= nil
		and vim.api.nvim_win_is_valid(state.side_win)
		and state.side_buf ~= nil
		and vim.api.nvim_buf_is_valid(state.side_buf)
	then
		return state.side_win, state.side_buf, state.side_line_map
	end
	return nil, nil, nil
end

---@return PullsDetailTabModule|nil
local function current_tab_mod()
	for _, tab in ipairs(state.tabs) do
		if tab.key == state.current_tab then
			return tab.mod
		end
	end
end

---@param lnum integer
---@param line_map table<integer, table>
---@return boolean
local function is_selectable(lnum, line_map)
	local entry = line_map[lnum]
	if entry == nil then
		return false
	end

	local tab_mod = current_tab_mod()
	if tab_mod and tab_mod.is_selectable_line then
		return tab_mod.is_selectable_line(lnum, entry)
	end

	return true
end

---@param direction "up"|"down"
function M.move_cursor(direction)
	local win, buf, line_map = active_pane()
	if win == nil or buf == nil then
		return
	end
	line_map = line_map or {}

	local current = vim.api.nvim_win_get_cursor(win)
	local line = current[1]
	local col = current[2]
	local max_line = vim.api.nvim_buf_line_count(buf)
	local step = direction == "up" and -1 or 1
	local bound = direction == "up" and 1 or max_line

	-- On a selectable line -> try to snap to next selectable
	if is_selectable(line, line_map) then
		for lnum = line + step, bound, step do
			if is_selectable(lnum, line_map) then
				vim.api.nvim_win_set_cursor(win, { lnum, col })
				return
			end
		end
	end

	-- No selectable found (or wasn't on one) -> move freely one line
	local next = line + step
	if next >= 1 and next <= max_line then
		vim.api.nvim_win_set_cursor(win, { next, col })
	end
end

return M
