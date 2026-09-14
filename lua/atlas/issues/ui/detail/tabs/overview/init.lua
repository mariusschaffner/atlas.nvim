local M = {}

local help = require("atlas.ui.popups.help")
local keymaps = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local notify = require("atlas.core.notify")
local detail = require("atlas.issues.ui.detail.state")
local inline_edit = require("atlas.ui.inline_edit")

local PADDING_X = 1
local PADDING = string.rep(" ", PADDING_X)

---@param _issue Issue
---@param details IssueDetails|nil
---@param _width integer
---@return string[], table[], table<integer, table>
function M.render(_issue, details, _width)
	if details == nil then
		return {}, {}, {}
	end

	local lines = {}
	local spans = {}

	local description = tostring(details.description or "")
	if description == "" then
		utils.push(lines, spans, "No description", "AtlasTextMuted", PADDING_X)
	else
		for _, line in ipairs(utils.sanitize_lines(description)) do
			table.insert(lines, PADDING .. line)
		end
	end

	return lines, spans, {}
end

---@param buf integer
---@param refresh fun()
local function register_edit_keymap(buf, refresh)
	local provider = detail.provider
	local core = provider and provider.capabilities.core
	local update_description = core and core.update_description
	local keys = update_description and keymaps.resolve("ui.comments.edit") or nil
	if keys == nil then
		return
	end

	help.register("Detail", {
		{
			key = #keys == 1 and keys[1] or keys,
			desc = "Edit description",
			hint_desc = "Edit",
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
	vim.api.nvim_set_option_value("syntax", "markdown", { buf = buf })

	register_edit_keymap(buf, refresh)
end

---@param buf integer
function M.deactivate(buf)
	local keys = keymaps.resolve("ui.comments.edit")
	if keys then
		help.remove("Detail", { { key = #keys == 1 and keys[1] or keys } }, { buffer = buf })
	end
	vim.api.nvim_set_option_value("filetype", "atlas.detail", { buf = buf })
	vim.api.nvim_set_option_value("syntax", "OFF", { buf = buf })
	pcall(vim.treesitter.stop, buf)
end

return M
