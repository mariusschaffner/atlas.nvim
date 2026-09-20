-- Inline editing for a single "field box" (Assignee, Labels, Reviewers,
-- Title, the dashboard filter box, ...): opens a small floating window
-- overlaid exactly on the field's existing interior region (as reported by
-- `field_box.render_columns`/`filter_bar.render`) and focuses the cursor
-- there. The underlying header/dashboard buffer is never touched -- read-mode
-- layout is identical before, during, and after the edit; only the overlay
-- appears and disappears. See `atlas.ui.inline_edit` for the sibling
-- "replace the whole buffer" pattern used for tab-body fields (description)
-- that own their entire buffer instead of sharing it with other fields.
local M = {}

local keymaps = require("atlas.core.keymaps")
local notify = require("atlas.core.notify")

local border_ns = vim.api.nvim_create_namespace("AtlasInlineFieldEditBorder")

--- Highlights one span of a border line (e.g. the top/bottom border, or one
--- side's `│`) orange to mark the field as actively being edited. `start_char`/
--- `end_char` are 0-indexed *display columns* (matching the region geometry
--- `field_box`/`filter_bar` report) -- converted to byte offsets here since
--- box-drawing glyphs are multi-byte but always exactly 1 column wide, and
--- `nvim_buf_set_extmark` columns are byte offsets, not display columns.
---@param buf integer
---@param line_idx integer 0-indexed
---@param start_char integer
---@param end_char integer exclusive
local function highlight_border_span(buf, line_idx, start_char, end_char)
	local line = vim.api.nvim_buf_get_lines(buf, line_idx, line_idx + 1, false)[1]
	if line == nil then
		return
	end
	local start_byte = vim.fn.byteidx(line, start_char)
	local end_byte = vim.fn.byteidx(line, end_char)
	if start_byte < 0 or end_byte < 0 or end_byte <= start_byte then
		return
	end
	pcall(vim.api.nvim_buf_set_extmark, buf, border_ns, line_idx, start_byte, {
		end_row = line_idx,
		end_col = end_byte,
		hl_group = "AtlasFieldBoxBorderEditing",
	})
end

--- Recolors the border immediately surrounding an interior region (assumed
--- to be a `bordered_box.lua`-rendered box, one border row/col beyond the
--- interior on every side -- true for every current caller).
---@param buf integer
---@param row integer interior row, 0-indexed
---@param col integer interior col, 0-indexed
---@param width integer interior width
---@param height integer interior height
local function highlight_border(buf, row, col, width, height)
	local top, bottom = row - 1, row + height
	local left, right = col - 1, col + width
	local box_width = width + 2

	highlight_border_span(buf, top, left, left + box_width)
	highlight_border_span(buf, bottom, left, left + box_width)
	for r = row, row + height - 1 do
		highlight_border_span(buf, r, left, left + 1)
		highlight_border_span(buf, r, right, right + 1)
	end
end

---@param buf integer|nil
local function clear_border_highlight(buf)
	if buf and vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_clear_namespace(buf, border_ns, 0, -1)
	end
end

---@class AtlasFieldCompletionItem
---@field name string Canonical value submitted on save (username or label name).
---@field display string|nil Text shown in the completion menu; defaults to `name`.
---@field menu string|nil Short hint shown alongside the candidate (e.g. "member", "label").

---@class AtlasFieldCompletionProvider
---@field fetch fun(query: string, on_items: fun(items: AtlasFieldCompletionItem[]))
---@field debounce_ms integer|nil Default 150.

---@class AtlasInlineFieldEditOptions
---@field anchor_win integer Window the overlay is positioned relative to (`relative = "win"`).
---@field row integer 0-indexed row of the field's interior, within `anchor_win`'s buffer.
---@field col integer 0-indexed col where the field's interior starts.
---@field width integer Interior width (fixed; overlay never grows).
---@field height integer|nil Interior height, default 1.
---@field seed_text string
---@field multi_value boolean|nil Comma-separated accumulation mode.
---@field word_segment boolean|nil Completes against the whitespace-delimited word under the cursor (e.g. the filter bar's `key:value` tokens) instead of the whole line. Ignored when `multi_value` is set.
---@field seed_resolved string[]|nil Canonical names already known valid (the field's current value(s)), so submitting unchanged text -- or adding one value without retyping the rest -- doesn't drop entries that were never re-fetched via completion.
---@field completion AtlasFieldCompletionProvider|nil
---@field submit_keys string[]|nil Overrides the resolved `ui.submit` keys for this field (e.g. the filter box uses `<CR>`).
---@field close_keys string[]|nil Overrides the resolved `ui.field_edit.close` keys for this field.
---@field on_save fun(text: string, done: fun(ok: boolean, err: string|nil))
---@field on_cancel (fun())|nil
---@field on_done fun()

---@type { win: integer, buf: integer, anchor_buf: integer, restore_win: integer|nil, resolved_by_lower: table<string, string>, saving: boolean, augroup: integer, debounce: uv.uv_timer_t|nil, request: AtlasRequestScope|nil }|nil
local active = nil

---@return boolean
function M.is_active()
	return active ~= nil
end

---@param text string
---@param resolved_by_lower table<string, string>
---@return string[] resolved
---@return string[] unresolved
function M.parse_multi_value(text, resolved_by_lower)
	local resolved, unresolved, seen = {}, {}, {}
	for _, segment in ipairs(vim.split(text, ",", { plain = true })) do
		local trimmed = vim.trim(segment)
		if trimmed ~= "" then
			local canonical = resolved_by_lower[trimmed:lower()]
			if canonical then
				if not seen[canonical] then
					seen[canonical] = true
					table.insert(resolved, canonical)
				end
			else
				table.insert(unresolved, trimmed)
			end
		end
	end
	return resolved, unresolved
end

---@param text string
---@return string query, integer start_col 0-indexed byte col where a completion replacement should start.
local function current_multi_value_segment(text)
	local last_comma = nil
	for i = #text, 1, -1 do
		if text:sub(i, i) == "," then
			last_comma = i
			break
		end
	end
	local start_col = last_comma and last_comma or 0
	local segment = text:sub(start_col + 1)
	local leading = segment:match("^%s*") or ""
	return vim.trim(segment), start_col + #leading
end

---@param text string
---@return string query, integer start_col 0-indexed byte col where a completion replacement should start.
local function current_word_segment(text)
	local last_space = nil
	for i = #text, 1, -1 do
		if text:sub(i, i):match("%s") then
			last_space = i
			break
		end
	end
	local start_col = last_space or 0
	local segment = text:sub(start_col + 1)
	local leading = segment:match("^%s*") or ""
	return segment:sub(#leading + 1), start_col + #leading
end

local function stop_debounce()
	if active and active.debounce then
		pcall(function()
			active.debounce:stop()
			active.debounce:close()
		end)
		active.debounce = nil
	end
end

local function cancel_request()
	if active and active.request then
		active.request.cancel()
		active.request = nil
	end
end

---@param opts AtlasInlineFieldEditOptions
---@param query string
---@param start_col integer
local function trigger_completion_fetch(opts, query, start_col)
	if active == nil then
		return
	end
	local request_scope = require("atlas.core.requests")
	local scope = request_scope.new()
	active.request = scope
	scope.run(function(done)
		return opts.completion.fetch(query, function(items)
			done(items)
		end)
	end, function(items)
		if active == nil then
			return
		end
		active.request = nil
		local function apply()
			if active == nil or not vim.api.nvim_buf_is_valid(active.buf) then
				return
			end
			for _, item in ipairs(items or {}) do
				local name = tostring(item.name or "")
				if name ~= "" then
					active.resolved_by_lower[name:lower()] = name
				end
			end
			local complete_items = {}
			for _, item in ipairs(items or {}) do
				local name = tostring(item.name or "")
				if name ~= "" then
					table.insert(complete_items, {
						word = opts.multi_value and (name .. ", ") or name,
						abbr = item.display or name,
						menu = item.menu or "",
					})
				end
			end
			-- The fetch is async, so by the time it resolves the user may
			-- have already left Insert mode (e.g. pressed <Esc>) without
			-- closing the field -- complete() errors outside Insert mode.
			if vim.api.nvim_get_current_win() == active.win and vim.fn.mode() == "i" then
				vim.fn.complete(start_col + 1, complete_items)
			end
		end
		if vim.in_fast_event() then
			vim.schedule(apply)
		else
			apply()
		end
	end)
end

---@param opts AtlasInlineFieldEditOptions
local function trigger_completion(opts)
	if active == nil or opts.completion == nil then
		return
	end
	local buf = active.buf
	local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
	local cursor_col = vim.api.nvim_win_get_cursor(active.win)[2]
	local before = line:sub(1, cursor_col)

	local query, start_col
	if opts.multi_value then
		query, start_col = current_multi_value_segment(before)
	elseif opts.word_segment then
		query, start_col = current_word_segment(before)
	else
		query, start_col = vim.trim(before), 0
	end

	stop_debounce()
	cancel_request()

	local timer = vim.uv.new_timer()
	active.debounce = timer
	timer:start(opts.completion.debounce_ms or 150, 0, function()
		timer:stop()
		timer:close()
		if active then
			active.debounce = nil
		end
		if vim.in_fast_event() then
			vim.schedule(function()
				trigger_completion_fetch(opts, query, start_col)
			end)
		else
			trigger_completion_fetch(opts, query, start_col)
		end
	end)
end

---@param opts AtlasInlineFieldEditOptions
function M.start(opts)
	if active ~= nil then
		return
	end
	if not vim.api.nvim_win_is_valid(opts.anchor_win) then
		return
	end

	local submit_keys = opts.submit_keys or keymaps.resolve("ui.submit") or {}
	local close_keys = opts.close_keys or keymaps.resolve("ui.field_edit.close") or {}

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
	if opts.completion then
		-- Neither "noinsert" nor "noselect": cycling with <Tab>/<S-Tab> below
		-- should fill the highlighted candidate into the buffer immediately,
		-- regardless of the user's global 'completeopt' (commonly tuned for
		-- an LSP completion plugin, which would otherwise suppress that).
		vim.api.nvim_set_option_value("completeopt", "menu,menuone", { buf = buf })
	end
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { opts.seed_text or "" })

	local restore_win = vim.api.nvim_get_current_win()
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "win",
		win = opts.anchor_win,
		row = opts.row,
		col = opts.col,
		width = math.max(1, opts.width),
		height = math.max(1, opts.height or 1),
		style = "minimal",
		border = "none",
		zindex = 200,
		focusable = true,
	})
	vim.api.nvim_set_option_value("wrap", false, { win = win, scope = "local" })
	vim.api.nvim_set_option_value("cursorline", false, { win = win, scope = "local" })
	vim.api.nvim_set_option_value("signcolumn", "no", { win = win, scope = "local" })
	vim.api.nvim_set_option_value(
		"winhighlight",
		"Normal:AtlasFieldBoxBorderEditable,NormalNC:AtlasFieldBoxBorderEditable",
		{ win = win, scope = "local" }
	)

	local augroup = vim.api.nvim_create_augroup("AtlasInlineFieldEdit" .. buf, { clear = true })

	local resolved_by_lower = {}
	for _, name in ipairs(opts.seed_resolved or {}) do
		local n = tostring(name or "")
		if n ~= "" then
			resolved_by_lower[n:lower()] = n
		end
	end

	local anchor_buf = vim.api.nvim_win_get_buf(opts.anchor_win)
	highlight_border(anchor_buf, opts.row, opts.col, opts.width, opts.height or 1)

	active = {
		win = win,
		buf = buf,
		anchor_buf = anchor_buf,
		restore_win = restore_win,
		resolved_by_lower = resolved_by_lower,
		saving = false,
		augroup = augroup,
	}

	vim.api.nvim_win_set_cursor(win, { 1, #(opts.seed_text or "") })
	vim.cmd("startinsert!")

	local function unbind()
		for _, key in ipairs(submit_keys) do
			pcall(vim.keymap.del, "n", key, { buffer = buf })
			pcall(vim.keymap.del, "i", key, { buffer = buf })
		end
		for _, key in ipairs(close_keys) do
			pcall(vim.keymap.del, "n", key, { buffer = buf })
		end
		if opts.completion then
			pcall(vim.keymap.del, "i", "<Tab>", { buffer = buf })
			pcall(vim.keymap.del, "i", "<S-Tab>", { buffer = buf })
		end
	end

	local function finish()
		stop_debounce()
		cancel_request()
		pcall(vim.api.nvim_del_augroup_by_id, augroup)
		unbind()
		clear_border_highlight(anchor_buf)
		active = nil
		if vim.api.nvim_win_is_valid(win) then
			pcall(vim.api.nvim_win_close, win, true)
		end
		if vim.api.nvim_buf_is_valid(buf) then
			pcall(vim.api.nvim_buf_delete, buf, { force = true })
		end
		if vim.api.nvim_win_is_valid(restore_win) then
			pcall(vim.api.nvim_set_current_win, restore_win)
		end
		opts.on_done()
	end

	local function save()
		if active == nil or active.saving then
			return
		end
		active.saving = true
		local raw = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""

		local text
		if opts.multi_value then
			local resolved, unresolved = M.parse_multi_value(raw, active.resolved_by_lower)
			if #unresolved > 0 then
				notify.warn("Skipping unrecognized: " .. table.concat(unresolved, ", "))
			end
			text = table.concat(resolved, ", ")
		else
			text = vim.trim(raw)
		end

		opts.on_save(text, function(ok, err)
			if active == nil then
				return
			end
			if ok then
				finish()
				return
			end
			active.saving = false
			if err then
				notify.error(tostring(err))
			end
		end)
	end

	local function cancel()
		if opts.on_cancel then
			opts.on_cancel()
		end
		finish()
	end

	for _, key in ipairs(submit_keys) do
		vim.keymap.set("n", key, save, { buffer = buf, nowait = true, silent = true })
		vim.keymap.set("i", key, function()
			vim.cmd("stopinsert")
			save()
		end, { buffer = buf, nowait = true, silent = true })
	end
	for _, key in ipairs(close_keys) do
		vim.keymap.set("n", key, cancel, { buffer = buf, nowait = true, silent = true })
	end

	if opts.completion then
		vim.api.nvim_create_autocmd("TextChangedI", {
			group = augroup,
			buffer = buf,
			callback = function()
				trigger_completion(opts)
			end,
		})
		-- Fire once immediately so completion candidates are available before
		-- the user's first keystroke (e.g. re-opening a field to change one value).
		trigger_completion(opts)

		-- <Tab>/<S-Tab> cycle the completion menu (like a fuzzy-completion
		-- plugin's accept-on-select) instead of only <C-n>/<C-p> or the
		-- arrow keys; falls through to a literal tab when the menu isn't up.
		-- Expression-mapping return values are sent as raw keys, not parsed
		-- for `<...>` notation, so termcodes have to be resolved here.
		vim.keymap.set("i", "<Tab>", function()
			return vim.fn.pumvisible() == 1 and vim.keycode("<C-n>") or vim.keycode("<Tab>")
		end, { buffer = buf, nowait = true, silent = true, expr = true })
		vim.keymap.set("i", "<S-Tab>", function()
			return vim.fn.pumvisible() == 1 and vim.keycode("<C-p>") or vim.keycode("<S-Tab>")
		end, { buffer = buf, nowait = true, silent = true, expr = true })
	end

	vim.api.nvim_create_autocmd("BufWipeout", {
		group = augroup,
		buffer = buf,
		once = true,
		callback = function()
			if active ~= nil and active.buf == buf then
				stop_debounce()
				cancel_request()
				pcall(vim.api.nvim_del_augroup_by_id, augroup)
				clear_border_highlight(anchor_buf)
				active = nil
			end
		end,
	})
end

return M
