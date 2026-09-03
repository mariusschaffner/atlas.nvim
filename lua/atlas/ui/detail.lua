local M = {}

local statusline = require("atlas.ui.statusline")
local utils = require("atlas.ui.shared.utils")

local MIN_HEADER_HEIGHT = 3
local MAX_HEADER_RATIO = 0.6

local state = {
	kind = nil,
	layout = nil, -- "single"|"split"
	win = nil, -- content window (both layouts)
	buf = nil, -- content buffer (both layouts)
	header_win = nil, -- sticky header window (split layout only)
	header_buf = nil, -- sticky header buffer (split layout only)
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
	reset_buffer(state.header_buf, "atlas.detail.header")
	if utils.window.valid(state.win) then
		vim.api.nvim_set_option_value("winbar", "", { win = state.win, scope = "local" })
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
	state.header_win = nil
	state.header_buf = nil

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

-- Full-screen dedicated tab: a small fixed-height header window on top (fields,
-- chips, tab bar, reviewers/checks) that never scrolls, and a content window
-- below it that scrolls independently -- a real sticky header.
local function create_split()
	vim.cmd("tabnew")
	local tab = vim.api.nvim_get_current_tabpage()
	local placeholder_buf = vim.api.nvim_get_current_buf()

	local header_buf = utils.buffer.create(string.format("atlas://detail/header/%d", tab), "atlas.detail.header")
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = header_buf })
	local content_buf = utils.buffer.create(string.format("atlas://detail/%d", tab), "atlas.detail")
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = content_buf })

	local header_win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(header_win, header_buf)
	configure(header_win)

	local content_win = utils.window.create(header_win, "belowright split", content_buf, configure)
	pcall(vim.api.nvim_win_set_height, header_win, MIN_HEADER_HEIGHT)

	if placeholder_buf ~= header_buf and placeholder_buf ~= content_buf and vim.api.nvim_buf_is_valid(placeholder_buf) then
		utils.buffer.delete(placeholder_buf)
	end

	vim.api.nvim_set_current_win(content_win)

	state.layout = "split"
	state.win = content_win
	state.buf = content_buf
	state.header_win = header_win
	state.header_buf = header_buf

	local function on_closed()
		vim.schedule(function()
			if state.win ~= content_win and state.header_win ~= header_win then
				return
			end
			deactivate()
			if vim.api.nvim_tabpage_is_valid(tab) then
				pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(tab))
			end
			state.win = nil
			state.buf = nil
			state.header_win = nil
			state.header_buf = nil
			state.layout = nil
			require("atlas.ui.dashboard").render()
		end)
	end

	vim.api.nvim_create_autocmd("WinClosed", { pattern = tostring(content_win), once = true, callback = on_closed })
	vim.api.nvim_create_autocmd("WinClosed", { pattern = tostring(header_win), once = true, callback = on_closed })
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
---@return integer win, integer buf, integer|nil header_win, integer|nil header_buf
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
		state.win, state.buf, state.header_win, state.header_buf = nil, nil, nil, nil
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
	return state.win, state.buf, state.header_win, state.header_buf
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

--- Resizes the sticky header window to fit `line_count` lines, capped so the
--- content window always keeps a reasonable share of the screen.
---@param line_count integer
function M.resize_header(line_count)
	if not utils.window.valid(state.header_win) or not utils.window.valid(state.win) then
		return
	end
	local total = vim.api.nvim_win_get_height(state.header_win) + vim.api.nvim_win_get_height(state.win)
	local max_height = math.max(MIN_HEADER_HEIGHT, math.floor(total * MAX_HEADER_RATIO))
	local height = math.max(MIN_HEADER_HEIGHT, math.min(line_count, max_height))
	pcall(vim.api.nvim_win_set_height, state.header_win, height)
end

---@param tab integer|nil
function M.close(tab)
	if not M.is_open(tab) then
		return
	end

	local win = state.win
	local header_win = state.header_win
	local buf = state.buf
	local header_buf = state.header_buf
	local layout = state.layout
	deactivate()
	state.win, state.buf, state.header_win, state.header_buf, state.layout = nil, nil, nil, nil, nil
	if layout == "split" and utils.window.valid(win) then
		local tabpage = vim.api.nvim_win_get_tabpage(win)
		pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(tabpage))
	else
		for _, w in ipairs({ win, header_win }) do
			if utils.window.valid(w) then
				vim.api.nvim_win_close(w, true)
			end
		end
	end
	utils.buffer.delete(buf)
	utils.buffer.delete(header_buf)
	require("atlas.ui.dashboard").render()
end

vim.api.nvim_create_autocmd("VimResized", {
	group = vim.api.nvim_create_augroup("AtlasDetailResize", { clear = true }),
	callback = function()
		if not M.is_open() then
			return
		end
		if state.layout ~= "split" then
			pcall(vim.api.nvim_win_set_width, state.win, math.max(math.floor(vim.o.columns * 0.45), 40))
		end
		if state.render then
			state.render()
		end
	end,
})

return M
