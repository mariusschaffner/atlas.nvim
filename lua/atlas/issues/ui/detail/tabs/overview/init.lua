local M = {}

local help = require("atlas.ui.popups.help")
local keymaps = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local notify = require("atlas.core.notify")
local detail = require("atlas.issues.ui.detail.state")
local inline_edit = require("atlas.ui.inline_edit")
local markdown_lines = require("atlas.ui.components.markdown_lines")

local PADDING_X = 1
local PADDING = string.rep(" ", PADDING_X)
-- Extra right-side breathing room for a heading's right-aligned "n of m done"
-- suffix, so it doesn't sit flush against the content pane's border.
local RIGHT_HINT_PAD_X = 1
local hint_ns = vim.api.nvim_create_namespace("atlas.issues.detail.overview.hint")

--- The last render's task index (buffer line -> source line / checked),
--- offset by `PADDING_X`'s line-numbering (none -- padding is a column
--- prefix, not an extra line) so the `x` toggle keymap and the cursor-line
--- hint can map the cursor straight back to it.
---@type AtlasMarkdownTask[]
local last_tasks = {}

---@param _issue Issue
---@param details IssueDetails|nil
---@param width integer
---@return string[], table[], table<integer, table>
function M.render(_issue, details, width)
	if details == nil then
		last_tasks = {}
		return {}, {}, {}
	end

	local description = tostring(details.description or "")
	local rendered_lines, rendered_spans, tasks =
		markdown_lines.render(description, { width = width - PADDING_X - RIGHT_HINT_PAD_X })
	last_tasks = tasks

	if #rendered_lines == 0 then
		local lines, spans = {}, {}
		utils.push(lines, spans, "No description", "AtlasTextMuted", PADDING_X)
		return lines, spans, {}
	end

	local lines, spans = {}, {}
	for _, line in ipairs(rendered_lines) do
		table.insert(lines, PADDING .. line)
	end
	for _, span in ipairs(rendered_spans) do
		if span.line_hl_group ~= nil then
			table.insert(spans, span)
		else
			table.insert(spans, {
				line = span.line,
				start_col = span.start_col + PADDING_X,
				end_col = span.end_col + PADDING_X,
				hl_group = span.hl_group,
			})
		end
	end

	return lines, spans, {}
end

---@param win integer
---@param buf integer
local function update_cursor_hint(win, buf)
	vim.api.nvim_buf_clear_namespace(buf, hint_ns, 0, -1)
	if not vim.api.nvim_win_is_valid(win) then
		return
	end
	local cursor_line = vim.api.nvim_win_get_cursor(win)[1] - 1
	local on_task = false
	for _, task in ipairs(last_tasks) do
		if task.line == cursor_line then
			on_task = true
			break
		end
	end
	if not on_task then
		return
	end

	-- `right_align` floats the hint to the content window's right edge
	-- (DESIGN-detail-view.md §5), regardless of the task line's own length.
	vim.api.nvim_buf_set_extmark(buf, hint_ns, cursor_line, 0, {
		virt_text = { { "x toggle", "AtlasKeyHint" } },
		virt_text_pos = "right_align",
	})
end

---@param buf integer
---@param refresh fun()
local function register_toggle_keymap(buf, refresh)
	local provider = detail.provider
	local core = provider and provider.capabilities.core
	local update_description = core and core.update_description
	local keys = update_description and keymaps.resolve("issues.toggle_task_item") or nil
	if keys == nil then
		return
	end

	help.register("Detail", {
		{
			key = #keys == 1 and keys[1] or keys,
			desc = "Toggle task item",
			hint = false,
			opts = { nowait = true, silent = true },
			callback = function()
				local issue = detail.current_issue
				local details = detail.current_details
				if issue == nil or details == nil or inline_edit.is_active(buf) then
					return
				end
				local win = detail.win
				if win == nil or not vim.api.nvim_win_is_valid(win) then
					return
				end
				local cursor_line = vim.api.nvim_win_get_cursor(win)[1] - 1
				local raw_line = nil
				for _, task in ipairs(last_tasks) do
					if task.line == cursor_line then
						raw_line = task.raw_line
						break
					end
				end
				if raw_line == nil then
					return
				end

				local current = tostring(details.description or "")
				local updated = markdown_lines.toggle_task(current, raw_line)
				if updated == current then
					return
				end
				details.description = updated
				refresh()
				update_description(issue, updated, function(ok, err)
					local selected = detail.current_issue
					if selected == nil or tostring(selected.key) ~= tostring(issue.key) then
						return
					end
					if not ok then
						notify.error("Description update failed: " .. tostring(err or "Unknown error"))
						details.description = current
						refresh()
					end
				end)
			end,
		},
	}, { index = 213, buffer = buf })
end

---@param buf integer
---@param refresh fun()
local function register_edit_keymap(buf, refresh)
	local provider = detail.provider
	local core = provider and provider.capabilities.core
	local update_description = core and core.update_description
	local keys = update_description and keymaps.resolve("ui.edit_description") or nil
	if keys == nil then
		return
	end

	help.register("Detail", {
		{
			key = #keys == 1 and keys[1] or keys,
			desc = "Edit description",
			hint = false, -- no hint shown; the content box's editable border color is the only affordance
			opts = { nowait = true, silent = true },
			callback = function()
				local issue = detail.current_issue
				local details = detail.current_details
				if issue == nil or details == nil or inline_edit.is_active(buf) then
					return
				end

				local current = tostring(details.description or "")

				require("atlas.issues.ui.detail.keymaps").remove(buf)
				help.remove("Detail", { { key = #keys == 1 and keys[1] or keys } }, { buffer = buf })

				inline_edit.start({
					buf = buf,
					text = current,
					on_save = function(text, done)
						local updated = text or ""
						if updated == current then
							done(true)
							return
						end
						notify.loading("Updating description...")
						update_description(issue, updated, function(ok, err)
							local selected = detail.current_issue
							if selected == nil or tostring(selected.key) ~= tostring(issue.key) then
								done(true)
								return
							end
							if not ok then
								notify.error("Description update failed: " .. tostring(err or "Unknown error"))
								done(false, err)
								return
							end
							details.description = updated
							notify.success("Description updated", { timeout = 1200 })
							done(true)
						end)
					end,
					on_cancel = function()
						notify.info("Description unchanged", { timeout = 1200 })
					end,
					on_done = function()
						if buf and vim.api.nvim_buf_is_valid(buf) then
							require("atlas.issues.ui.detail.keymaps").register(buf)
							register_edit_keymap(buf, refresh)
							register_toggle_keymap(buf, refresh)
						end
						refresh()
					end,
				})
			end,
		},
	}, { index = 212, buffer = buf })
end

---@param buf integer
---@param refresh fun()
function M.activate(buf, refresh)
	vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })
	vim.api.nvim_set_option_value("syntax", "OFF", { buf = buf })

	register_edit_keymap(buf, refresh)
	register_toggle_keymap(buf, refresh)

	local win = detail.win
	local group = vim.api.nvim_create_augroup("AtlasIssuesDetailOverviewHint" .. tostring(buf), { clear = true })
	vim.api.nvim_create_autocmd("CursorMoved", {
		group = group,
		buffer = buf,
		callback = function()
			if win and vim.api.nvim_win_is_valid(win) then
				update_cursor_hint(win, buf)
			end
		end,
	})
end

---@param buf integer
function M.deactivate(buf)
	pcall(vim.api.nvim_del_augroup_by_name, "AtlasIssuesDetailOverviewHint" .. tostring(buf))
	if vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_clear_namespace(buf, hint_ns, 0, -1)
	end
	local keys = keymaps.resolve("ui.edit_description")
	if keys then
		help.remove("Detail", { { key = #keys == 1 and keys[1] or keys } }, { buffer = buf })
	end
	local toggle_keys = keymaps.resolve("issues.toggle_task_item")
	if toggle_keys then
		help.remove("Detail", { { key = #toggle_keys == 1 and toggle_keys[1] or toggle_keys } }, { buffer = buf })
	end
	vim.api.nvim_set_option_value("filetype", "atlas.detail", { buf = buf })
	vim.api.nvim_set_option_value("syntax", "OFF", { buf = buf })
	pcall(vim.treesitter.stop, buf)
end

return M
