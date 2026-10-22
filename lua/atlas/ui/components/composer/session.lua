-- The live half of an inline composer: a borderless editing float laid
-- exactly over a `composer.frame`'s text rows. The host keeps rendering the
-- frame (title, footer, accent bar) into its own buffer; this module owns
-- the text, and reports back what the frame needs to redraw:
--
--   * `on_layout(height)` whenever the wrapped text needs more/fewer rows
--     (the host re-renders the frame that tall, then calls `session.move`),
--   * `on_state({ mode, dirty })` whenever the Vim mode or the unsaved state
--     flips (the host redraws the footer's mode badge / "● unsaved").
--
-- Unlike `atlas.ui.inline_field_edit` (single-line field values with async
-- value completion), this is a multi-line markdown editor: it soft-wraps,
-- grows with its content, and uses the markdown editor's @mention
-- completion (`atlas.ui.popups.editor.attach_completion`).
local M = {}

local resolver = require("atlas.core.keymaps")
local notify = require("atlas.core.notify")
local utils = require("atlas.ui.shared.utils")

local placeholder_ns = vim.api.nvim_create_namespace("atlas.composer.placeholder")
local DEFAULT_MAX_HEIGHT = 12

---@class AtlasComposerKeyBinding
---@field keys string[]
---@field modes string[]|nil Default { "n", "i" }.
---@field callback fun(session: AtlasComposerSession)

---@class AtlasComposerSessionOptions
---@field anchor_win integer Window the float is positioned relative to.
---@field region AtlasFieldBoxRegion Text area: 0-based buffer row in `anchor_win` (or a fixed screen row, see `fixed_rows`), display col, width, height.
---@field fixed_rows boolean|nil `region.row` is already a window-relative screen row (a non-scrolling anchor like the docked composer), not a buffer row.
---@field seed_text string|nil
---@field placeholder string|nil
---@field max_height integer|nil Cap for `on_layout` growth (default 12).
---@field transparent boolean|nil No tinted background (matches a `transparent` frame).
---@field completion AtlasMarkdownCompletionProvider|nil
---@field submit_keys string[]|nil Defaults to the resolved `ui.submit` keys.
---@field close_keys string[]|nil Normal-mode cancel; defaults to the resolved `ui.field_edit.close` keys.
---@field extra_keys AtlasComposerKeyBinding[]|nil
---@field on_submit fun(text: string, done: fun(ok: boolean, err: string|nil))
---@field on_cancel (fun(text: string))|nil Receives the discarded draft.
---@field on_done fun() Runs once after the float is gone (submit, cancel or `close`).
---@field on_layout (fun(height: integer))|nil
---@field on_state (fun(state: { mode: string, dirty: boolean }))|nil

---@class AtlasComposerSession
---@field win integer
---@field buf integer
---@field get_text fun(): string
---@field move fun(region: AtlasFieldBoxRegion)
---@field submit fun()
---@field cancel fun()
---@field close fun() Closes without calling `on_cancel` (e.g. handing the draft to a bigger editor).
---@field is_open fun(): boolean
---@field mode fun(): string
---@field dirty fun(): boolean

---@param anchor_win integer
---@param region AtlasFieldBoxRegion
---@param fixed_rows boolean|nil
---@return integer row, integer col
local function screen_position(anchor_win, region, fixed_rows)
	if fixed_rows then
		return region.row, region.col
	end
	-- `relative = "win"` positions in screen rows from the window's top-left,
	-- not buffer lines: resolve through `screenpos()` so scrolling and
	-- soft-wrapped lines above the region are accounted for (same approach as
	-- `atlas.ui.inline_field_edit`).
	local topline = vim.fn.line("w0", anchor_win)
	local leftcol = vim.api.nvim_win_call(anchor_win, function()
		return vim.fn.winsaveview().leftcol
	end)
	local top = vim.fn.screenpos(anchor_win, topline, 1).row
	local target = vim.fn.screenpos(anchor_win, region.row + 1, 1).row
	if target == 0 then
		-- Off screen: fall back to plain line arithmetic.
		return region.row - (topline - 1), region.col - leftcol
	end
	return target - top, region.col - leftcol
end

---@param opts AtlasComposerSessionOptions
---@return AtlasComposerSession|nil
function M.start(opts)
	if not vim.api.nvim_win_is_valid(opts.anchor_win) then
		return nil
	end
	local submit_keys = opts.submit_keys or resolver.resolve("ui.submit") or {}
	local close_keys = opts.close_keys or resolver.resolve("ui.field_edit.close") or {}
	local max_height = opts.max_height or DEFAULT_MAX_HEIGHT
	local seed_text = utils.normalize_newlines(opts.seed_text or "")

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(seed_text, "\n", { plain = true }))
	vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })

	local region = opts.region
	local row, col = screen_position(opts.anchor_win, region, opts.fixed_rows)
	local restore_win = vim.api.nvim_get_current_win()
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "win",
		win = opts.anchor_win,
		row = row,
		col = col,
		width = math.max(1, region.width),
		height = math.max(1, region.height),
		style = "minimal",
		border = "none",
		zindex = 200,
		focusable = true,
	})
	for name, value in pairs({
		wrap = true,
		linebreak = true,
		breakindent = false,
		cursorline = false,
		signcolumn = "no",
		winhighlight = opts.transparent and "Normal:Normal,NormalFloat:Normal,EndOfBuffer:Normal"
			or "Normal:AtlasComposerText,NormalFloat:AtlasComposerText,EndOfBuffer:AtlasComposerText",
	}) do
		vim.api.nvim_set_option_value(name, value, { win = win, scope = "local" })
	end

	local open = true
	local saving = false
	local current_mode = "i"
	local current_dirty = false
	local current_height = math.max(1, region.height)
	local augroup = vim.api.nvim_create_augroup("AtlasComposerSession" .. buf, { clear = true })

	local function get_text()
		if not vim.api.nvim_buf_is_valid(buf) then
			return ""
		end
		return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
	end

	local function update_placeholder()
		if not vim.api.nvim_buf_is_valid(buf) then
			return
		end
		vim.api.nvim_buf_clear_namespace(buf, placeholder_ns, 0, -1)
		if opts.placeholder and get_text() == "" then
			vim.api.nvim_buf_set_extmark(buf, placeholder_ns, 0, 0, {
				virt_text = { { opts.placeholder, opts.transparent and "AtlasTextMutedItalic" or "AtlasComposerPlaceholder" } },
				virt_text_pos = "overlay",
			})
		end
	end

	local function report_state()
		if opts.on_state then
			opts.on_state({ mode = current_mode, dirty = current_dirty })
		end
	end

	local function measure()
		if not vim.api.nvim_win_is_valid(win) then
			return
		end
		local ok, info = pcall(vim.api.nvim_win_text_height, win, {})
		local height = ok and info.all or vim.api.nvim_buf_line_count(buf)
		height = math.max(1, math.min(max_height, height))
		if height ~= current_height then
			current_height = height
			if opts.on_layout then
				opts.on_layout(height)
			end
		end
	end

	---@type AtlasComposerSession
	local session

	local function finish()
		if not open then
			return
		end
		open = false
		pcall(vim.api.nvim_del_augroup_by_id, augroup)
		if vim.api.nvim_win_is_valid(win) then
			pcall(vim.api.nvim_win_close, win, true)
		end
		if vim.api.nvim_buf_is_valid(buf) then
			pcall(vim.api.nvim_buf_delete, buf, { force = true })
		end
		if vim.api.nvim_win_is_valid(restore_win) then
			pcall(vim.api.nvim_set_current_win, restore_win)
		end
		vim.cmd("stopinsert")
		opts.on_done()
	end

	local function submit()
		if not open or saving then
			return
		end
		saving = true
		local text = vim.trim(get_text())
		opts.on_submit(text, function(ok, err)
			saving = false
			if not open then
				return
			end
			if ok then
				finish()
			elseif err then
				notify.error(tostring(err))
			end
		end)
	end

	local function cancel()
		if not open then
			return
		end
		local text = get_text()
		if opts.on_cancel then
			opts.on_cancel(text)
		end
		finish()
	end

	session = {
		win = win,
		buf = buf,
		get_text = get_text,
		submit = submit,
		cancel = cancel,
		close = finish,
		is_open = function()
			return open
		end,
		mode = function()
			return current_mode
		end,
		dirty = function()
			return current_dirty
		end,
		move = function(new_region)
			if not open or not vim.api.nvim_win_is_valid(win) then
				return
			end
			local new_row, new_col = screen_position(opts.anchor_win, new_region, opts.fixed_rows)
			pcall(vim.api.nvim_win_set_config, win, {
				relative = "win",
				win = opts.anchor_win,
				row = new_row,
				col = new_col,
				width = math.max(1, new_region.width),
				height = math.max(1, new_region.height),
			})
		end,
	}

	local function map(modes, keys, callback)
		for _, key in ipairs(keys) do
			vim.keymap.set(modes, key, callback, { buffer = buf, nowait = true, silent = true })
		end
	end
	map({ "n", "i" }, submit_keys, submit)
	map("n", close_keys, cancel)
	for _, binding in ipairs(opts.extra_keys or {}) do
		map(binding.modes or { "n", "i" }, binding.keys, function()
			binding.callback(session)
		end)
	end

	if opts.completion then
		require("atlas.ui.popups.editor").attach_completion(buf, opts.completion)
	end

	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
		group = augroup,
		buffer = buf,
		callback = function()
			update_placeholder()
			local dirty = get_text() ~= seed_text
			if dirty ~= current_dirty then
				current_dirty = dirty
				report_state()
			end
			measure()
		end,
	})
	vim.api.nvim_create_autocmd("ModeChanged", {
		group = augroup,
		buffer = buf,
		callback = function()
			local mode = vim.v.event.new_mode or vim.fn.mode()
			local simplified = mode:sub(1, 1) == "i" and "i" or "n"
			if simplified ~= current_mode then
				current_mode = simplified
				report_state()
			end
		end,
	})
	-- Leaving the float (mouse click, <C-w>w, ...) abandons the draft the same
	-- way <Esc> does -- an orphaned float would otherwise float over a buffer
	-- that keeps re-rendering underneath it.
	vim.api.nvim_create_autocmd("WinLeave", {
		group = augroup,
		buffer = buf,
		callback = function()
			vim.schedule(function()
				if open and vim.api.nvim_get_current_win() ~= win and not saving then
					local completion_menu = vim.fn.pumvisible() == 1
					if not completion_menu then
						cancel()
					end
				end
			end)
		end,
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = augroup,
		buffer = buf,
		once = true,
		callback = function()
			if open then
				open = false
				pcall(vim.api.nvim_del_augroup_by_id, augroup)
				opts.on_done()
			end
		end,
	})

	update_placeholder()
	local last = vim.api.nvim_buf_line_count(buf)
	local last_line = vim.api.nvim_buf_get_lines(buf, last - 1, last, false)[1] or ""
	vim.api.nvim_win_set_cursor(win, { last, #last_line })
	vim.cmd("startinsert!")
	vim.schedule(measure)
	return session
end

return M
