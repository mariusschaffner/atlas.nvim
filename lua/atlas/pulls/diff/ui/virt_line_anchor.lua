-- Geometry only: locates a row inside a `virt_lines` block (attached to a
-- diff buffer line via `nvim_buf_set_extmark`) on screen, so a
-- `relative = "win"` floating window (e.g. `atlas.ui.inline_field_edit`) can
-- be anchored onto it. Virtual lines have no addressable buffer line of
-- their own, so this can't be done with a plain line/col like the Activity
-- tab's real-buffer comment boxes -- it's derived from
-- `nvim_win_text_height` (Neovim >=0.10), which is the only API that folds
-- wrapping, folds, and virt_lines into a single screen-row count.
--
-- Empirically (verified against `screenpos()` in a headless Neovim probe):
-- virt_lines attached *below* a line only count towards a text-height query
-- once the query range extends *past* that line, and a single-line query at
-- that line's own row never includes its own below-block; virt_lines
-- attached *above* a line, by contrast, are already included in a
-- single-line query at that line's own row. `M.screen_row` below is built
-- around exactly that asymmetry -- don't "simplify" the two branches without
-- re-checking both cases against real screen rows.
local M = {}

---@param win integer
---@param opts { anchor_line: integer, above: boolean, block_row: integer }
---@return integer|nil screen_row 0-indexed, relative to `win`'s top-left corner.
function M.screen_row(win, opts)
	if not vim.api.nvim_win_is_valid(win) then
		return nil
	end
	local anchor_line = opts.anchor_line
	local ok_fold, folded = pcall(vim.api.nvim_win_call, win, function()
		return vim.fn.foldclosed(anchor_line)
	end)
	if not ok_fold or folded ~= -1 then
		return nil
	end

	local topline0 = vim.fn.line("w0", win) - 1
	if anchor_line - 1 < topline0 then
		return nil
	end

	local ok, rows_before = pcall(vim.api.nvim_win_text_height, win, {
		start_row = topline0,
		end_row = anchor_line - 2,
	})
	if not ok then
		return nil
	end
	local ok_own, own = pcall(vim.api.nvim_win_text_height, win, {
		start_row = anchor_line - 1,
		end_row = anchor_line - 1,
	})
	if not ok_own then
		return nil
	end

	local own_real = own.all - own.fill
	local base = opts.above and rows_before.all or (rows_before.all + own_real)
	local screen_row = base + opts.block_row
	if screen_row < 0 or screen_row >= vim.api.nvim_win_get_height(win) then
		return nil
	end
	return screen_row
end

--- Moves the cursor to `line` and scrolls it into view (opening any closed
--- fold over it first), mirroring the `zv`/`zz` idiom `comments.jump` already
--- uses. Callers must do this before `M.screen_row`, matching
--- `inline_field_edit`'s own documented assumption that the target row is
--- already visible.
---@param win integer
---@param line integer
function M.ensure_visible(win, line)
	if not vim.api.nvim_win_is_valid(win) then
		return
	end
	vim.api.nvim_win_call(win, function()
		pcall(vim.api.nvim_win_set_cursor, win, { line, 0 })
		vim.cmd.normal({ args = { "zv" }, bang = true })
		local topline0 = vim.fn.line("w0", win) - 1
		local height = vim.api.nvim_win_get_height(win)
		if line - 1 < topline0 or line - 1 >= topline0 + height then
			vim.cmd.normal({ args = { "zz" }, bang = true })
		end
	end)
end

return M
