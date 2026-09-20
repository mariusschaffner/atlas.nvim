local M = {}

local utils = require("atlas.ui.shared.utils")
local spinner = require("atlas.ui.components.spinner")
local detail = require("atlas.pulls.ui.detail.state")
local help = require("atlas.ui.popups.help")
local keymaps = require("atlas.core.keymaps")
local notify = require("atlas.core.notify")
local inline_edit = require("atlas.ui.inline_edit")
local tab_hints = require("atlas.pulls.ui.detail.tabs.tab_hints")

---@return string|string[]|nil
local function edit_description_keys()
	local provider = detail.provider
	local capability = provider and provider.capabilities.actions
	local supported = false
	for _, action in ipairs(capability and capability.items or {}) do
		if action.id == "edit_description" then
			supported = true
			break
		end
	end
	if not supported then
		return nil
	end
	return keymaps.resolve("ui.comments.edit")
end

local PADDING_X = 1
local PADDING = string.rep(" ", PADDING_X)

---@param details PullRequestDetails
---@param width integer
---@param lines string[]
---@param spans table[]
local function render_description(details, width, lines, spans)
	local desc_text = utils.strip_markup(details.description)
	if desc_text == "" then
		utils.push(lines, spans, "No description provided.", "AtlasTextMuted", PADDING_X)
		table.insert(lines, "")
		return
	end

	local desc_lines = utils.sanitize_lines(desc_text)
	while #desc_lines > 0 and vim.trim(desc_lines[#desc_lines]) == "" do
		table.remove(desc_lines)
	end

	for _, line in ipairs(desc_lines) do
		table.insert(lines, PADDING .. line)
	end

	table.insert(lines, "")
end

---@param _pr PullRequest
---@param details PullRequestDetails|nil
---@param width integer
---@return string[], table[], table<integer, table>|nil
function M.render(_pr, details, width)
	local lines = {}
	local spans = {}

	if details then
		render_description(details, width, lines, spans)
	elseif detail.details_loading then
		utils.push(lines, spans, spinner.with_text("Loading description..."), "AtlasTextMuted", PADDING_X)
	else
		utils.push(lines, spans, "Pull request details unavailable.", "AtlasTextMuted", PADDING_X)
	end

	return lines, spans, {}
end

---@param buf integer
---@param refresh fun()|nil
local function register_edit_keymap(buf, refresh)
	local keys = edit_description_keys()
	if keys == nil then
		return
	end

	help.register("Detail", {
		{
			key = #keys == 1 and keys[1] or keys,
			desc = "Edit PR description",
			hint_desc = "Edit",
			opts = { nowait = true, silent = true },
			callback = function()
				local pr = detail.current_pr
				local details = detail.current_details
				local provider = detail.provider
				if pr == nil or details == nil or provider == nil or inline_edit.is_active(buf) then
					return
				end

				local core = provider.capabilities.core

				local function begin_edit(current)
					require("atlas.pulls.ui.detail.keymaps").remove(buf)
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
							core.update_description(pr, updated, function(ok, err)
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
								require("atlas.pulls.ui.detail.keymaps").register(buf)
								register_edit_keymap(buf, refresh)
							end
							if refresh then
								refresh()
							end
						end,
					})
				end

				-- Always edit against the remote description so a stale panel
				-- does not silently revert someone else's concurrent edit.
				if core.fetch_description then
					notify.loading("Loading description...")
					core.fetch_description(pr, { force_refresh = true }, function(description, err)
						if detail.current_pr ~= pr then
							return
						end
						if err then
							notify.error("Failed to load description: " .. tostring(err))
							return
						end
						details.description = description or details.description
						begin_edit(tostring(details.description or ""))
					end)
				else
					begin_edit(tostring(details.description or ""))
				end
			end,
		},
	}, { index = 212, buffer = buf })
end

---@param buf integer
---@param refresh fun()|nil
function M.activate(buf, refresh)
	if not (buf and vim.api.nvim_buf_is_valid(buf)) then
		return
	end
	vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })
	vim.api.nvim_set_option_value("syntax", "markdown", { buf = buf })

	register_edit_keymap(buf, refresh)
	help.register("Detail", tab_hints.items(detail.provider), { index = 212, buffer = buf })
end

---@param buf integer
function M.deactivate(buf)
	if not (buf and vim.api.nvim_buf_is_valid(buf)) then
		return
	end
	vim.api.nvim_set_option_value("filetype", "atlas.detail", { buf = buf })
	vim.api.nvim_set_option_value("syntax", "OFF", { buf = buf })
	pcall(vim.treesitter.stop, buf)

	local keys = edit_description_keys()
	if keys ~= nil then
		help.remove("Detail", { { key = #keys == 1 and keys[1] or keys } }, { buffer = buf })
	end
	tab_hints.remove(buf, "Detail")
end

return M
