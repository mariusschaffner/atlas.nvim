local M = {}

local statusline = require("atlas.ui.statusline")
local utils = require("atlas.ui.shared.utils")

local MIN_HEADER_HEIGHT = 3
local MAX_HEADER_RATIO = 0.55
local CONTENT_BORDER = "rounded"
local SIDEBAR_WIDTH = 34
local SIDEBAR_GAP = 1
local SIDEBAR_COLLAPSE_COLUMNS = 100

local state = {
	kind = nil,
	layout = nil, -- "single"|"split"
	win = nil, -- content window: a floating window in "split" layout, a plain split in "single"
	buf = nil, -- content buffer (both layouts)
	header_win = nil, -- sticky header window (split layout only)
	header_buf = nil, -- sticky header buffer (split layout only)
	spacer_win = nil, -- hidden split both the content and sidebar floats overlay (split layout only)
	sidebar_enabled = false, -- whether the current kind opted into a sidebar region
	sidebar_win = nil, -- sidebar floating window (split layout only, when not collapsed)
	sidebar_buf = nil, -- sidebar buffer; kept alive (bufhidden=hide) across collapse/expand
	sidebar_collapsed = false, -- true when narrow-terminal collapse hid the sidebar
	boxed_header = false, -- header draws its own box: floats start on the spacer's first row (no gap row)
	dock = nil, -- { win, buf, height }: float pinned to the content window's bottom rows (see M.set_content_dock)
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
	reset_buffer(state.sidebar_buf, "atlas.detail.sidebar")
	if utils.window.valid(state.win) then
		vim.api.nvim_set_option_value("winbar", "", { win = state.win, scope = "local" })
	end
end

--- Geometry of the content dock float: pinned to the content window's bottom
--- rows, full content width, inside the content pane's own border.
---@param height integer Interior rows (the dock's own rounded border adds 2).
---@return integer row, integer width
local function dock_geometry(height)
	local win_height = vim.api.nvim_win_get_height(state.win)
	local win_width = vim.api.nvim_win_get_width(state.win)
	return math.max(0, win_height - height - 2), math.max(1, win_width - 2)
end

local function close_dock()
	local dock = state.dock
	state.dock = nil
	if dock and utils.window.valid(dock.win) then
		pcall(vim.api.nvim_win_close, dock.win, true)
	end
end

--- Re-syncs the dock float to the content window's current size.
local function sync_dock()
	local dock = state.dock
	if dock == nil then
		return
	end
	if not utils.window.valid(state.win) or not utils.buffer.valid(dock.buf) then
		close_dock()
		return
	end
	local row, width = dock_geometry(dock.height)
	local config = {
		relative = "win",
		win = state.win,
		row = row,
		col = 0,
		width = width,
		height = dock.height,
	}
	if utils.window.valid(dock.win) then
		pcall(vim.api.nvim_win_set_config, dock.win, config)
		return
	end
	dock.win = vim.api.nvim_open_win(
		dock.buf,
		false,
		vim.tbl_extend("force", config, {
			border = "rounded",
			style = "minimal",
			zindex = 60,
			focusable = false,
		})
	)
	vim.api.nvim_set_option_value("wrap", false, { win = dock.win, scope = "local" })
	vim.api.nvim_set_option_value("winhighlight", dock.winhighlight or "", { win = dock.win, scope = "local" })
end

local function deactivate()
	close_dock()
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

--- Both floats (content, and sidebar when shown) overlay the *same* spacer
--- split, side by side, rather than each getting its own spacer -- a plain
--- split window always reserves its own statusline row (visible as a stray
--- bar once its content is just a blank/invisible filler), while floating
--- windows never show one. One shared spacer keeps that row count at
--- exactly one (the content pane's own, already handled deliberately -- see
--- `configure`'s doc comment) regardless of whether the sidebar is shown.
---@param spacer_win integer
---@return integer content_width, integer content_col, integer|nil sidebar_width, integer|nil sidebar_col, integer height, integer row
local function split_geometry(spacer_win)
	local total = math.max(1, vim.api.nvim_win_get_width(spacer_win))
	-- A boxed header already ends in its own bottom border, so the floats
	-- start on the spacer's first row instead of leaving a gap row above them.
	-- They grow by that row too, keeping their bottom edge where it was.
	local row = state.boxed_header and 0 or 1
	local height = math.max(1, vim.api.nvim_win_get_height(spacer_win) - 1 - row)
	if state.sidebar_enabled and not state.sidebar_collapsed then
		-- Reserve SIDEBAR_WIDTH + a gap column for the sidebar, but never let
		-- the content pane shrink below a usable minimum.
		local sidebar_box = math.min(SIDEBAR_WIDTH, math.max(1, total - 24))
		local content_box = math.max(1, total - sidebar_box - SIDEBAR_GAP)
		local content_width = math.max(1, content_box - 2)
		local sidebar_width = math.max(1, sidebar_box - 2)
		local sidebar_col = 1 + content_width + 2 + SIDEBAR_GAP
		return content_width, 1, sidebar_width, sidebar_col, height, row
	end
	return math.max(1, total - 2), 1, nil, nil, height, row
end

--- Re-syncs the content float's position/size to whatever `state.spacer_win`
--- currently measures -- called whenever the spacer's geometry could have
--- changed (header resize, VimResized, sidebar collapse/expand).
local function sync_content_float()
	if state.layout ~= "split" or not utils.window.valid(state.spacer_win) or not utils.window.valid(state.win) then
		return
	end
	local content_width, content_col, _, _, height, row = split_geometry(state.spacer_win)
	pcall(vim.api.nvim_win_set_config, state.win, {
		relative = "win",
		win = state.spacer_win,
		row = row,
		col = content_col,
		width = content_width,
		height = height,
	})
	sync_dock()
end

--- Re-syncs the sidebar float's position/size to whatever `state.spacer_win`
--- currently measures.
local function sync_sidebar_float()
	if
		state.layout ~= "split"
		or not state.sidebar_enabled
		or state.sidebar_collapsed
		or not utils.window.valid(state.spacer_win)
		or not utils.window.valid(state.sidebar_win)
	then
		return
	end
	local _, _, sidebar_width, sidebar_col, height, row = split_geometry(state.spacer_win)
	if sidebar_width == nil then
		return
	end
	pcall(vim.api.nvim_win_set_config, state.sidebar_win, {
		relative = "win",
		win = state.spacer_win,
		row = row,
		col = sidebar_col,
		width = sidebar_width,
		height = height,
	})
end

--- Closes the sidebar floating window (if present). The sidebar buffer
--- itself is left alone (bufhidden is "hide", not "wipe") so its last
--- rendered content survives a later expand.
local function destroy_sidebar_window()
	if utils.window.valid(state.sidebar_win) then
		pcall(vim.api.nvim_win_close, state.sidebar_win, true)
	end
	state.sidebar_win = nil
end

---@param tab integer
local function create_sidebar_window(tab)
	if not utils.window.valid(state.spacer_win) then
		return
	end
	if not utils.buffer.valid(state.sidebar_buf) then
		local sidebar_buf = utils.buffer.create(string.format("atlas://detail/sidebar/%d", tab), "atlas.detail.sidebar")
		vim.api.nvim_set_option_value("bufhidden", "hide", { buf = sidebar_buf })
		state.sidebar_buf = sidebar_buf
	end

	local _, _, sidebar_width, sidebar_col, height, row = split_geometry(state.spacer_win)
	if sidebar_width == nil then
		return
	end
	local sidebar_win = vim.api.nvim_open_win(state.sidebar_buf, false, {
		relative = "win",
		win = state.spacer_win,
		row = row,
		col = sidebar_col,
		width = sidebar_width,
		height = height,
		border = CONTENT_BORDER,
		style = "minimal",
		zindex = 50,
	})
	configure_header(sidebar_win)
	vim.api.nvim_set_option_value("winhighlight", content_winhighlight("AtlasBorder"), { win = sidebar_win, scope = "local" })

	state.sidebar_win = sidebar_win
end

--- Shows/hides the sidebar based on the current terminal width (spec: hide
--- below ~100 columns, collapsing its info into the caller's meta-strip
--- fallback instead). No-op when the current kind didn't opt into a sidebar.
local function update_sidebar_collapse()
	if state.layout ~= "split" or not state.sidebar_enabled then
		return
	end
	local should_collapse = vim.o.columns < SIDEBAR_COLLAPSE_COLUMNS
	if should_collapse == state.sidebar_collapsed then
		return
	end
	state.sidebar_collapsed = should_collapse
	if should_collapse then
		destroy_sidebar_window()
	else
		create_sidebar_window(vim.api.nvim_win_get_tabpage(state.spacer_win))
	end
end

-- Full-screen dedicated tab: a small fixed-height header window on top
-- (fields, chips, reviewers/checks) that never scrolls, and a bordered
-- floating content window below it -- a real sticky header, plus a box
-- whose border stays pinned on screen while only its buffer content scrolls.
-- The float overlays an invisible "spacer" split so its geometry can be
-- tracked via Neovim's own split layout engine instead of manual math
-- against tabline/cmdheight/laststatus.
---@param sidebar_enabled boolean
---@param boxed_header boolean
local function create_split(sidebar_enabled, boxed_header)
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

	-- `configure_header`, not `configure`: this split is pure invisible
	-- chrome (an empty scratch buffer, entirely covered by the content/
	-- sidebar floats) -- it never shows real text, so it should never grow a
	-- real statusline row either. `configure` would attach the live Atlas
	-- statusline here, but since this buffer never has keymaps/hints
	-- registered, that row only ever rendered blank -- a bar with no content,
	-- spanning the full width below both floats. The real statusline lives
	-- on the content float's own border/footer instead (`set_content_footer`).
	local spacer_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = spacer_buf })
	local spacer_win = utils.window.create(header_win, "belowright split", spacer_buf, configure_header)
	pcall(vim.api.nvim_win_set_height, header_win, MIN_HEADER_HEIGHT)

	state.spacer_win = spacer_win
	state.boxed_header = boxed_header
	state.sidebar_enabled = sidebar_enabled
	state.sidebar_collapsed = sidebar_enabled and vim.o.columns < SIDEBAR_COLLAPSE_COLUMNS
	if sidebar_enabled and not state.sidebar_collapsed then
		create_sidebar_window(tab)
	end

	local content_width, content_col, _, _, height, row = split_geometry(spacer_win)
	local content_win = vim.api.nvim_open_win(content_buf, false, {
		relative = "win",
		win = spacer_win,
		row = row,
		col = content_col,
		width = content_width,
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
			local is_sidechrome = current == header_win or current == spacer_win or current == state.sidebar_win
			if is_sidechrome and utils.window.valid(content_win) then
				vim.api.nvim_set_current_win(content_win)
			end
		end,
	})

	local function on_closed()
		vim.schedule(function()
			if state.win ~= content_win and state.header_win ~= header_win and state.spacer_win ~= spacer_win then
				return
			end
			local sidebar_buf = state.sidebar_buf
			destroy_sidebar_window()
			utils.buffer.delete(sidebar_buf)
			state.sidebar_enabled = false
			state.sidebar_buf = nil
			state.sidebar_collapsed = false
			state.boxed_header = false
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

---@param kind "issues"|"pulls"|"repo"|"milestone"|"pipelines"|"create"
---@return "single"|"split"
local function layout_for(kind)
	if kind == "pulls" or kind == "issues" or kind == "milestone" or kind == "pipelines" or kind == "create" then
		return "split"
	end
	return "single"
end

---@class AtlasDetailOpenOpts
---@field sidebar boolean|nil -- opt into the fixed-width sidebar region (split layout only)
---@field boxed_header boolean|nil -- header renders its own bordered box; no gap row above the content box (split layout only)

---@param kind "issues"|"pulls"|"repo"|"milestone"|"pipelines"|"create"
---@param cleanup fun()
---@param render fun()
---@param opts AtlasDetailOpenOpts|nil
---@return integer win, integer buf, integer|nil header_win, integer|nil header_buf
function M.open(kind, cleanup, render, opts)
	require("atlas.ui.shared.highlights").setup()
	local wanted_layout = layout_for(kind)
	local wanted_sidebar = wanted_layout == "split" and opts ~= nil and opts.sidebar == true
	local wanted_boxed = wanted_layout == "split" and opts ~= nil and opts.boxed_header == true
	if M.is_open() and vim.api.nvim_win_get_tabpage(state.win) ~= vim.api.nvim_get_current_tabpage() then
		M.close()
	end
	if
		M.is_open()
		and (
			state.layout ~= wanted_layout
			or state.sidebar_enabled ~= wanted_sidebar
			or state.boxed_header ~= wanted_boxed
		)
	then
		M.close()
	end
	if not M.is_open() then
		deactivate()
		state.win, state.buf, state.header_win, state.header_buf, state.spacer_win = nil, nil, nil, nil, nil
		if wanted_layout == "split" then
			create_split(wanted_sidebar, wanted_boxed)
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

--- The sidebar buffer to render metadata fields into, or `nil` when the
--- current kind didn't opt into a sidebar, or it is currently collapsed by
--- narrow-terminal width (see `M.is_sidebar_collapsed`). Callers should check
--- this on every render (not just once at `M.open` time) since collapse state
--- can change out from under them on `VimResized`.
---@return integer|nil
function M.sidebar_buf()
	if not state.sidebar_enabled or state.sidebar_collapsed or not utils.buffer.valid(state.sidebar_buf) then
		return nil
	end
	return state.sidebar_buf
end

--- Whether the sidebar is unavailable right now -- either because the current
--- kind never opted in, or the terminal is currently too narrow for it. A
--- caller should fall back to rendering sidebar information inline (e.g. the
--- spec's narrow-terminal meta strip) when this is true but `sidebar` was
--- requested at `M.open` time.
---@return boolean
function M.is_sidebar_collapsed()
	return (not state.sidebar_enabled) or state.sidebar_collapsed
end

--- The sidebar's floating window, for anchoring an `inline_field_edit`
--- overlay over one of its fields -- `nil` under the same conditions as
--- `M.sidebar_buf`.
---@return integer|nil
function M.sidebar_win()
	if not state.sidebar_enabled or state.sidebar_collapsed or not utils.window.valid(state.sidebar_win) then
		return nil
	end
	return state.sidebar_win
end

---@param tab integer|nil
---@return boolean
function M.is_open(tab)
	return utils.window.valid(state.win)
		and utils.buffer.valid(state.buf)
		and state.render ~= nil
		and (tab == nil or vim.api.nvim_win_get_tabpage(state.win) == tab)
end

---@param kind "issues"|"pulls"|"repo"|"milestone"|"pipelines"|"create"
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
	local current = vim.api.nvim_win_get_height(state.header_win)
	local total = current + vim.api.nvim_win_get_height(state.win)
	local max_height = math.max(MIN_HEADER_HEIGHT, math.floor(total * MAX_HEADER_RATIO))
	local height = math.max(MIN_HEADER_HEIGHT, math.min(line_count, max_height))
	-- No-op when already the right size -- resizing (even to the same value)
	-- repositions the content float right after, which is a visible flicker
	-- for callers that re-render on every keypress (e.g. cycling job tabs).
	if height == current then
		return
	end
	pcall(vim.api.nvim_win_set_height, state.header_win, height)
	sync_content_float()
	sync_sidebar_float()
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

--- Sets the content float's native footer (bottom border hint) to the given
--- `{text, hl_group}[]` chunks (see `nvim_open_win`'s `footer`). Pass
--- `nil`/`{}` to clear it.
---@param chunks { [1]: string, [2]: string }[]|nil
function M.set_content_footer(chunks)
	if state.layout ~= "split" or not utils.window.valid(state.win) then
		return
	end
	pcall(vim.api.nvim_win_set_config, state.win, {
		footer = (chunks == nil or #chunks == 0) and "" or chunks,
		footer_pos = "left",
	})
end

-- Highlight groups `tabs.title_chunks`'s `border_hl` option may have used to
-- color the title's non-label characters (leading dash, "-" separators,
-- trailing space) -- recognized by `set_content_border` below so it can
-- recolor them in place, without needing to know the active tab list.
local BORDER_HL_GROUPS = {
	AtlasBorder = true,
	AtlasFieldBoxBorderEditable = true,
	AtlasFieldBoxBorderEditing = true,
}

--- Sets the content float's border highlight (e.g. `AtlasFieldBoxBorderEditable`
--- while the active tab is ready for inline editing, matching every other
--- editable field box). Pass `nil`/`""` to reset to the default border color.
--- Also recolors the title's own border-colored characters (see
--- `BORDER_HL_GROUPS`) to match, so the title stays in sync with the border
--- even when nothing re-renders the title itself (e.g. while `inline_edit`
--- is active and content re-rendering is intentionally paused).
---@param hl_group string|nil
function M.set_content_border(hl_group)
	if state.layout ~= "split" or not utils.window.valid(state.win) then
		return
	end
	local border_hl = (hl_group == nil or hl_group == "") and "AtlasBorder" or hl_group
	pcall(vim.api.nvim_set_option_value, "winhighlight", content_winhighlight(border_hl), { win = state.win, scope = "local" })

	local ok, cfg = pcall(vim.api.nvim_win_get_config, state.win)
	if not ok or type(cfg.title) ~= "table" then
		return
	end
	local changed = false
	local new_title = {}
	for _, chunk in ipairs(cfg.title) do
		local text, hl = chunk[1], chunk[2]
		if BORDER_HL_GROUPS[hl] and hl ~= border_hl then
			hl = border_hl
			changed = true
		end
		table.insert(new_title, { text, hl })
	end
	if changed then
		pcall(vim.api.nvim_win_set_config, state.win, { title = new_title, title_pos = "left" })
	end
end

---@class AtlasDetailDockSpec
---@field buf integer Buffer the dock shows (rendered by the caller).
---@field height integer Interior rows.
---@field winhighlight string|nil e.g. "FloatBorder:AtlasComposerBorderActive".

--- Pins a small bordered float to the bottom of the content window (e.g. the
--- Activity tab's "write a new comment…" bar), kept in place across resizes.
--- Calling it again with the same buffer just updates height/colors. Pass
--- `nil` to remove it. The dock is not focusable: callers that need input
--- open their own float anchored to `M.content_dock_win()`. The content
--- buffer should reserve `height + 2` trailing rows so its last lines can
--- scroll clear of the dock.
---@param spec AtlasDetailDockSpec|nil
function M.set_content_dock(spec)
	if spec == nil then
		close_dock()
		return
	end
	if state.layout ~= "split" or not utils.window.valid(state.win) then
		return
	end
	if state.dock and state.dock.buf ~= spec.buf then
		close_dock()
	end
	state.dock = state.dock or { buf = spec.buf }
	state.dock.height = math.max(1, spec.height)
	state.dock.winhighlight = spec.winhighlight
	sync_dock()
	if utils.window.valid(state.dock and state.dock.win) then
		pcall(
			vim.api.nvim_set_option_value,
			"winhighlight",
			spec.winhighlight or "",
			{ win = state.dock.win, scope = "local" }
		)
	end
end

--- The dock's window (see `M.set_content_dock`), or nil when none is shown.
---@return integer|nil
function M.content_dock_win()
	local dock = state.dock
	if dock and utils.window.valid(dock.win) then
		return dock.win
	end
	return nil
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
	local sidebar_buf = state.sidebar_buf
	local layout = state.layout
	deactivate()
	state.win, state.buf, state.header_win, state.header_buf, state.spacer_win, state.layout =
		nil, nil, nil, nil, nil, nil
	state.sidebar_win, state.sidebar_buf = nil, nil
	state.sidebar_enabled, state.sidebar_collapsed = false, false
	state.boxed_header = false
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
	utils.buffer.delete(sidebar_buf)
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
			update_sidebar_collapse()
			sync_content_float()
			sync_sidebar_float()
		end
		if state.render then
			state.render()
		end
	end,
})

return M
