-- Generic "edit this buffer in place" helper: makes a read-only detail
-- buffer temporarily writable, seeds it with raw text, and wires up
-- save/discard on the shared `ui.submit` / `ui.close` keys -- the same
-- convention used by the floating markdown editor (atlas.ui.popups.editor),
-- just without the popup.
local M = {}

local keymaps = require("atlas.core.keymaps")
local notify = require("atlas.core.notify")
local utils = require("atlas.ui.shared.utils")

---@type table<integer, { saving: boolean }>
local active = {}

---@param buf integer
---@return boolean
function M.is_active(buf)
	return active[buf] ~= nil
end

---@class AtlasInlineEditOptions
---@field buf integer
---@field text string|nil
---@field on_save fun(text: string, done: fun(ok: boolean, err: string|nil))
---@field on_cancel (fun())|nil
---@field on_done fun()

---@param opts AtlasInlineEditOptions
function M.start(opts)
	local buf = opts.buf
	if buf == nil or not vim.api.nvim_buf_is_valid(buf) or active[buf] ~= nil then
		return
	end

	local submit_keys = keymaps.resolve("ui.submit") or {}
	local close_keys = keymaps.resolve("ui.close") or {}

	local lines = vim.split(utils.normalize_newlines(opts.text), "\n", { plain = true })
	if #lines == 0 then
		lines = { "" }
	end

	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_buf_clear_namespace(buf, -1, 0, -1)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modified", false, { buf = buf })

	active[buf] = { saving = false }

	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = buf,
		once = true,
		callback = function()
			active[buf] = nil
		end,
	})

	local function unbind()
		for _, key in ipairs(submit_keys) do
			pcall(vim.keymap.del, "n", key, { buffer = buf })
			pcall(vim.keymap.del, "i", key, { buffer = buf })
		end
		for _, key in ipairs(close_keys) do
			pcall(vim.keymap.del, "n", key, { buffer = buf })
		end
	end

	local function finish()
		active[buf] = nil
		unbind()
		if vim.api.nvim_buf_is_valid(buf) then
			vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
		end
		opts.on_done()
	end

	local function save()
		local state = active[buf]
		if state == nil or state.saving then
			return
		end
		state.saving = true
		local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
		opts.on_save(text, function(ok, err)
			if active[buf] == nil then
				return
			end
			if ok then
				finish()
				return
			end
			active[buf].saving = false
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

	if #submit_keys > 0 or #close_keys > 0 then
		local hint = {}
		if #submit_keys > 0 then
			table.insert(hint, table.concat(submit_keys, "/") .. " save")
		end
		if #close_keys > 0 then
			table.insert(hint, table.concat(close_keys, "/") .. " discard")
		end
		notify.info("Editing: " .. table.concat(hint, ", "), { timeout = 2000 })
	end
end

return M
