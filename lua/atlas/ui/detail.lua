local M = {}

local statusline = require("atlas.ui.statusline")
local utils = require("atlas.ui.shared.utils")

local HEIGHT_RATIO = 0.6
local SIDEBAR_RATIO = 0.35
local MIN_SIDEBAR_WIDTH = 30
local MIN_CONTENT_WIDTH = 40

local state = {
	kind = nil,
	layout = nil, -- "single"|"split"
	win = nil, -- content window (both layouts)
	buf = nil, -- content buffer (both layouts)
	side_win = nil, -- sidebar window (split layout only)
	side_buf = nil, -- sidebar buffer (split layout only)
	previous_win = nil,
	cleanup = nil,
	render = nil,
}

---@param win integer
local function configure(win)
	for name, value in pairs({
		number = false,
		relativenumber = false,
		signcolumn = "no",
		statuscolumn = "",
		foldcolumn = "0",
		foldmethod = "manual",
		foldenable = false,
		wrap = true,
		breakindent = true,
		cursorline = true,
		scrollbind = false,
		cursorbind = false,
		diff = false,
		winbar = "",
		winhighlight = "Normal:Normal,NormalFloat:Normal,FloatBorder:FloatBorder,CursorLine:CursorLine",
	}) do
		vim.api.nvim_set_option_value(name, value, { win = win, scope = "local" })
	end
	statusline.attach(win)
end

---@param total_width integer
---@return integer
local function sidebar_width(total_width)
	local ideal = math.floor(total_width * SIDEBAR_RATIO)
	local max_allowed = math.max(MIN_SIDEBAR_WIDTH, total_width - MIN_CONTENT_WIDTH)
	return math.max(MIN_SIDEBAR_WIDTH, math.min(ideal, max_allowed))
end

---@param buf integer|nil
---@param filetype string
local function reset_buffer(buf, filetype)
	if not utils.buffer.valid(buf) then
		return
	end
	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_buf_clear_namespace(buf, -1, 0, -1)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
	vim.api.nvim_set_option_value("filetype", filetype, { buf = buf })
	vim.api.nvim_set_option_value("syntax", "OFF", { buf = buf })
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
end

local function reset_content()
	reset_buffer(state.buf, "atlas.detail")
	reset_buffer(state.side_buf, "atlas.detail.side")
	if utils.window.valid(state.win) then
		vim.api.nvim_set_option_value("winbar", "", { win = state.win, scope = "local" })
	end
	if utils.window.valid(state.side_win) then
		vim.api.nvim_set_option_value("winbar", "", { win = state.side_win, scope = "local" })
	end
end

local function deactivate()
	local cleanup = state.cleanup
	state.kind = nil
	state.cleanup = nil
	state.render = nil
	if cleanup then
		cleanup()
	end
end

---@return integer source, boolean beside_dashboard
local function dashboard_source()
	local dashboard = require("atlas.ui.dashboard")
	local beside_dashboard = dashboard.is_active()
	return (beside_dashboard and dashboard.win() or vim.api.nvim_get_current_win()), beside_dashboard
end

local function create_single()
	local source, beside_dashboard = dashboard_source()
	local buf = utils.buffer.create("atlas://detail", "atlas.detail")
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	local win = utils.window.create(source, "rightbelow vsplit", buf, configure)
	pcall(vim.api.nvim_win_set_width, win, math.max(math.floor(vim.o.columns * 0.45), 40))
	if not beside_dashboard then
		vim.api.nvim_set_current_win(win)
	end

	state.layout = "single"
	state.win = win
	state.buf = buf
	state.side_win = nil
	state.side_buf = nil

	vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(win),
		once = true,
		callback = function()
			vim.schedule(function()
				if state.win == win then
					deactivate()
					state.win = nil
					state.buf = nil
					state.layout = nil
					require("atlas.ui.dashboard").render()
				end
			end)
		end,
	})
end

local function create_split()
	local source, beside_dashboard = dashboard_source()
	local content_buf = utils.buffer.create("atlas://detail", "atlas.detail")
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = content_buf })
	local side_buf = utils.buffer.create("atlas://detail/side", "atlas.detail.side")
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = side_buf })

	local content_win = utils.window.create(source, "belowright split", content_buf, configure)
	pcall(vim.api.nvim_win_set_height, content_win, math.max(math.floor(vim.o.lines * HEIGHT_RATIO), 10))

	local total_width = vim.api.nvim_win_get_width(content_win)
	local side_win = utils.window.create(content_win, "leftabove vsplit", side_buf, configure)
	pcall(vim.api.nvim_win_set_width, side_win, sidebar_width(total_width))

	if not beside_dashboard then
		vim.api.nvim_set_current_win(content_win)
	end

	state.layout = "split"
	state.win = content_win
	state.buf = content_buf
	state.side_win = side_win
	state.side_buf = side_buf

	local function on_closed()
		vim.schedule(function()
			if state.win ~= content_win and state.side_win ~= side_win then
				return
			end
			deactivate()
			for _, w in ipairs({ content_win, side_win }) do
				if utils.window.valid(w) then
					pcall(vim.api.nvim_win_close, w, true)
				end
			end
			state.win = nil
			state.buf = nil
			state.side_win = nil
			state.side_buf = nil
			state.layout = nil
			require("atlas.ui.dashboard").render()
		end)
	end

	vim.api.nvim_create_autocmd("WinClosed", { pattern = tostring(content_win), once = true, callback = on_closed })
	vim.api.nvim_create_autocmd("WinClosed", { pattern = tostring(side_win), once = true, callback = on_closed })
end

---@param kind "issues"|"pulls"|"repo"
---@return "single"|"split"
local function layout_for(kind)
	if kind == "pulls" or kind == "issues" then
		return "split"
	end
	return "single"
end

---@param kind "issues"|"pulls"|"repo"
---@param cleanup fun()
---@param render fun()
---@return integer win, integer buf, integer|nil side_win, integer|nil side_buf
function M.open(kind, cleanup, render)
	require("atlas.ui.shared.highlights").setup()
	local wanted_layout = layout_for(kind)
	if M.is_open() and vim.api.nvim_win_get_tabpage(state.win) ~= vim.api.nvim_get_current_tabpage() then
		M.close()
	end
	if M.is_open() and state.layout ~= wanted_layout then
		M.close()
	end
	if not M.is_open() then
		deactivate()
		state.win, state.buf, state.side_win, state.side_buf = nil, nil, nil, nil
		if wanted_layout == "split" then
			create_split()
		else
			create_single()
		end
	elseif state.kind ~= kind then
		deactivate()
		reset_content()
	end

	state.kind = kind
	state.cleanup = cleanup
	state.render = render
	return state.win, state.buf, state.side_win, state.side_buf
end

---@param tab integer|nil
---@return boolean
function M.is_open(tab)
	return utils.window.valid(state.win)
		and utils.buffer.valid(state.buf)
		and state.render ~= nil
		and (tab == nil or vim.api.nvim_win_get_tabpage(state.win) == tab)
end

---@param kind "issues"|"pulls"|"repo"
---@param tab integer|nil
---@return boolean
function M.is_showing(kind, tab)
	return M.is_open(tab) and state.kind == kind
end

---@param tab integer|nil
function M.close(tab)
	if not M.is_open(tab) then
		return
	end

	local win = state.win
	local side_win = state.side_win
	local buf = state.buf
	local side_buf = state.side_buf
	deactivate()
	state.win, state.buf, state.side_win, state.side_buf, state.layout = nil, nil, nil, nil, nil
	for _, w in ipairs({ win, side_win }) do
		if utils.window.valid(w) then
			vim.api.nvim_win_close(w, true)
		end
	end
	utils.buffer.delete(buf)
	utils.buffer.delete(side_buf)
	require("atlas.ui.dashboard").render()
end

vim.api.nvim_create_autocmd("VimResized", {
	group = vim.api.nvim_create_augroup("AtlasDetailResize", { clear = true }),
	callback = function()
		if not M.is_open() then
			return
		end
		if state.layout == "split" then
			pcall(vim.api.nvim_win_set_height, state.win, math.max(math.floor(vim.o.lines * HEIGHT_RATIO), 10))
			if utils.window.valid(state.side_win) then
				local total_width = vim.api.nvim_win_get_width(state.win) + vim.api.nvim_win_get_width(state.side_win)
				pcall(vim.api.nvim_win_set_width, state.side_win, sidebar_width(total_width))
			end
		else
			pcall(vim.api.nvim_win_set_width, state.win, math.max(math.floor(vim.o.columns * 0.45), 40))
		end
		if state.render then
			state.render()
		end
	end,
})

return M
