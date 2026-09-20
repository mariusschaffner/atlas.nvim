local M = {}

local statusline = require("atlas.ui.statusline")
local utils = require("atlas.ui.shared.utils")

local MIN_HEADER_HEIGHT = 3
local MAX_HEADER_RATIO = 0.55
local CONTENT_BORDER = "rounded"

local state = {
	kind = nil,
	layout = nil, -- "single"|"split"
	win = nil, -- content window: a floating window in "split" layout, a plain split in "single"
	buf = nil, -- content buffer (both layouts)
	header_win = nil, -- sticky header window (split layout only)
	header_buf = nil, -- sticky header buffer (split layout only)
	spacer_win = nil, -- hidden split the content float overlays (split layout only)
	previous_win = nil,
	cleanup = nil,
	render = nil,
}

---@param border_hl string
---@return string
local function content_winhighlight(border_hl)
	return "Normal:Normal,NormalFloat:Normal,FloatBorder:" .. border_hl .. ",CursorLine:CursorLine"
end

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
		colorcolumn = "",
		winhighlight = content_winhighlight("AtlasBorder"),
	}) do
		vim.api.nvim_set_option_value(name, value, { win = win, scope = "local" })
	end
	statusline.attach(win)
end

--- Same as `configure`, but for the sticky header window: no cursorline (it's
--- never meant to hold the cursor) and no atlas statusline of its own -- only
--- the content window at the bottom should show one.
---@param win integer
local function configure_header(win)
	for name, value in pairs({
		number = false,
		relativenumber = false,
		signcolumn = "no",
		statuscolumn = "",
		foldcolumn = "0",
		foldmethod = "manual",
		foldenable = false,
		-- Never wrap: resize_header() sizes the window from the logical line
		-- count, so a wrapped line would silently push content below the
		-- visible area.
		wrap = false,
		breakindent = true,
		cursorline = false,
		scrollbind = false,
		cursorbind = false,
		diff = false,
		winbar = "",
		colorcolumn = "",
		winhighlight = "Normal:Normal,NormalFloat:Normal,FloatBorder:FloatBorder,CursorLine:CursorLine,StatusLine:Normal,StatusLineNC:Normal",
		statusline = " ",
	}) do
		vim.api.nvim_set_option_value(name, value, { win = win, scope = "local" })
	end
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

--- Interior width/height the content float should have so that its border
--- ring lands exactly on `spacer_win`'s edges (i.e. float+border fills the
--- spacer's rectangle).
---@param spacer_win integer
---@return integer width, integer height
local function content_geometry(spacer_win)
	local width = math.max(1, vim.api.nvim_win_get_width(spacer_win) - 2)
	local height = math.max(1, vim.api.nvim_win_get_height(spacer_win) - 2)
	return width, height
end

--- Re-syncs the content float's position/size to whatever `state.spacer_win`
--- currently measures -- called whenever the spacer's geometry could have
--- changed (header resize, VimResized).
local function sync_content_float()
	if state.layout ~= "split" or not utils.window.valid(state.spacer_win) or not utils.window.valid(state.win) then
		return
	end
	local width, height = content_geometry(state.spacer_win)
	pcall(vim.api.nvim_win_set_config, state.win, {
		relative = "win",
		win = state.spacer_win,
		row = 1,
		col = 1,
		width = width,
		height = height,
	})
end

-- Full-screen dedicated tab: a small fixed-height header window on top
-- (fields, chips, reviewers/checks) that never scrolls, and a bordered
-- floating content window below it -- a real sticky header, plus a box
-- whose border stays pinned on screen while only its buffer content scrolls.
-- The float overlays an invisible "spacer" split so its geometry can be
-- tracked via Neovim's own split layout engine instead of manual math
-- against tabline/cmdheight/laststatus.
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
	configure_header(header_win)

	local spacer_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = spacer_buf })
	local spacer_win = utils.window.create(header_win, "belowright split", spacer_buf, configure)
	pcall(vim.api.nvim_win_set_height, header_win, MIN_HEADER_HEIGHT)

	local width, height = content_geometry(spacer_win)
	local content_win = vim.api.nvim_open_win(content_buf, false, {
		relative = "win",
		win = spacer_win,
		row = 1,
		col = 1,
		width = width,
		height = height,
		border = CONTENT_BORDER,
		style = "minimal",
		zindex = 50,
	})
	configure(content_win)

	if placeholder_buf ~= header_buf and placeholder_buf ~= content_buf and vim.api.nvim_buf_is_valid(placeholder_buf) then
		utils.buffer.delete(placeholder_buf)
	end

	vim.api.nvim_set_current_win(content_win)

	state.layout = "split"
	state.win = content_win
	state.buf = content_buf
	state.header_win = header_win
	state.header_buf = header_buf
	state.spacer_win = spacer_win

	-- The header and its invisible spacer are purely informational: never let
	-- them hold focus, so tab navigation and other content-window keymaps
	-- always work regardless of where the cursor happened to land.
	local focus_guard = vim.api.nvim_create_augroup("AtlasDetailHeaderFocusGuard" .. tostring(tab), { clear = true })
	vim.api.nvim_create_autocmd("WinEnter", {
		group = focus_guard,
		callback = function()
			local current = vim.api.nvim_get_current_win()
			if (current == header_win or current == spacer_win) and utils.window.valid(content_win) then
				vim.api.nvim_set_current_win(content_win)
			end
		end,
	})

	local function on_closed()
		vim.schedule(function()
			if state.win ~= content_win and state.header_win ~= header_win and state.spacer_win ~= spacer_win then
				return
			end
			deactivate()
			pcall(vim.api.nvim_del_augroup_by_id, focus_guard)
			if vim.api.nvim_tabpage_is_valid(tab) then
				pcall(vim.cmd, "tabclose " .. vim.api.nvim_tabpage_get_number(tab))
			end
			state.win = nil
			state.buf = nil
			state.header_win = nil
			state.header_buf = nil
			state.spacer_win = nil
			state.layout = nil
			require("atlas.ui.dashboard").render()
		end)
	end

	vim.api.nvim_create_autocmd("WinClosed", { pattern = tostring(content_win), once = true, callback = on_closed })
	vim.api.nvim_create_autocmd("WinClosed", { pattern = tostring(header_win), once = true, callback = on_closed })
	vim.api.nvim_create_autocmd("WinClosed", { pattern = tostring(spacer_win), once = true, callback = on_closed })
end

---@param kind "issues"|"pulls"|"repo"|"milestone"
---@return "single"|"split"
local function layout_for(kind)
	if kind == "pulls" or kind == "issues" or kind == "milestone" then
		return "split"
	end
	return "single"
end

---@param kind "issues"|"pulls"|"repo"|"milestone"
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
		state.win, state.buf, state.header_win, state.header_buf, state.spacer_win = nil, nil, nil, nil, nil
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

---@param kind "issues"|"pulls"|"repo"|"milestone"
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
	sync_content_float()
end

--- Sets the content float's native title to the given `{text, hl_group}[]`
--- chunks (see `nvim_open_win`'s `title`). Pass `nil`/`{}` to clear it.
---@param chunks { [1]: string, [2]: string }[]|nil
function M.set_content_title(chunks)
	if state.layout ~= "split" or not utils.window.valid(state.win) then
		return
	end
	pcall(vim.api.nvim_win_set_config, state.win, {
		title = (chunks == nil or #chunks == 0) and "" or chunks,
		title_pos = "left",
	})
end

--- Sets the content float's border highlight (e.g. `AtlasFieldBoxBorderEditable`
--- while the active tab is ready for inline editing, matching every other
--- editable field box). Pass `nil`/`""` to reset to the default border color.
---@param hl_group string|nil
function M.set_content_border(hl_group)
	if state.layout ~= "split" or not utils.window.valid(state.win) then
		return
	end
	local border_hl = (hl_group == nil or hl_group == "") and "AtlasBorder" or hl_group
	pcall(vim.api.nvim_set_option_value, "winhighlight", content_winhighlight(border_hl), { win = state.win, scope = "local" })
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
	state.win, state.buf, state.header_win, state.header_buf, state.spacer_win, state.layout =
		nil, nil, nil, nil, nil, nil
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
		else
			sync_content_float()
		end
		if state.render then
			state.render()
		end
	end,
})

return M
