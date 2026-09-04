local M = {}

local help = require("atlas.ui.popups.help")
local resolver = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local actions = require("atlas.issues.actions")
local state = require("atlas.issues.ui.detail.state")

---@param issue Issue
---@param on_update (fun(issue: Issue|nil, result: IssuesActionResult|nil))|nil
---@param result IssuesActionResult|nil
local function complete_action(issue, on_update, result)
	if not result or not result.issue_key then
		return
	end
	if on_update then
		on_update(issue, result)
		return
	end

	local detail = require("atlas.issues.ui.detail")
	if result.removed then
		detail.close()
	else
		detail.refresh()
	end
end

---@param action_id AtlasKeymapActionId|string
---@param map_item table
---@return table|nil
local function item(action_id, map_item)
	local keys = resolver.resolve(action_id)
	if keys == nil then
		return nil
	end
	local out = vim.tbl_deep_extend("force", {}, map_item)
	out.key = #keys == 1 and keys[1] or keys
	return out
end

---@param action_id AtlasKeymapActionId|string
---@return table|nil
local function remove_item(action_id)
	local keys = resolver.resolve(action_id)
	if keys == nil then
		return nil
	end
	return { key = (#keys == 1 and keys[1] or keys) }
end

---@param buf integer
---@param opts { navigation: boolean|nil }|nil
function M.register(buf, opts)
	opts = opts or {}
	local items = {}
	local nav = require("atlas.issues.ui.detail.navigation")
	local provider = assert(state.provider)
	local function context(issue)
		return { provider = provider, issue = issue }
	end

	if opts.navigation ~= false then
		utils.insert_if(
			items,
			item("ui.next_item", {
				desc = "Next item",
				opts = { nowait = true, silent = true },
				hidden = true,
				hint = false,
				callback = function()
					nav.move_cursor("down")
				end,
			})
		)
		utils.insert_if(
			items,
			item("ui.previous_item", {
				desc = "Previous item",
				opts = { nowait = true, silent = true },
				hidden = true,
				hint = false,
				callback = function()
					nav.move_cursor("up")
				end,
			})
		)
	end
	if provider.capabilities.actions then
		utils.insert_if(
			items,
			item("ui.open_actions", {
				desc = "Open issue actions",
				hint = false,
				callback = function()
					local issue = state.current_issue
					if issue == nil then
						return
					end
					local on_update = state.on_update
					actions.open(context(issue), function(result)
						complete_action(issue, on_update, result)
					end)
				end,
			})
		)
	end

	---@param action_id string
	---@return boolean
	local function supports(action_id)
		if not provider.capabilities.actions then
			return false
		end
		for _, action in ipairs(provider.capabilities.actions.items or {}) do
			if action.id == action_id then
				return true
			end
		end
		return false
	end

	if supports("assign") then
		utils.insert_if(
			items,
			item("issues.change_assignee", {
				desc = "Change assignee",
				hint_desc = "Change Assignee",
				callback = function()
					local issue = state.current_issue
					if issue == nil then
						return
					end
					local on_update = state.on_update
					actions.run("assign", context(issue), function(result)
						complete_action(issue, on_update, result)
					end)
				end,
			})
		)
	end

	if supports("reporter") then
		utils.insert_if(
			items,
			item("issues.change_reporter", {
				desc = "Change reporter",
				hint_desc = "Change Reporter",
				callback = function()
					local issue = state.current_issue
					if issue == nil then
						return
					end
					local on_update = state.on_update
					actions.run("reporter", context(issue), function(result)
						complete_action(issue, on_update, result)
					end)
				end,
			})
		)
	end

	if supports("edit_issue") then
		utils.insert_if(
			items,
			item("issues.edit_issue", {
				desc = "Edit issue",
				hint_desc = "Edit",
				callback = function()
					local issue = state.current_issue
					if issue == nil then
						return
					end
					local on_update = state.on_update
					actions.run("edit_issue", context(issue), function(result)
						complete_action(issue, on_update, result)
					end)
				end,
			})
		)
	end

	if supports("labels") then
		utils.insert_if(
			items,
			item("issues.change_label", {
				desc = "Change labels",
				hint_desc = "Change Label",
				callback = function()
					local issue = state.current_issue
					if issue == nil then
						return
					end
					local on_update = state.on_update
					actions.run("labels", context(issue), function(result)
						complete_action(issue, on_update, result)
					end)
				end,
			})
		)
	end

	M.remove(buf)
	local general = items

	utils.insert_if(
		general,
		item("ui.next_panel_tab", {
			desc = "Next detail tab",
			hint = false,
			opts = { nowait = true },
			callback = function()
				require("atlas.issues.ui.detail").next_tab()
			end,
		})
	)

	utils.insert_if(
		general,
		item("ui.previous_panel_tab", {
			desc = "Previous detail tab",
			hint = false,
			opts = { nowait = true },
			callback = function()
				require("atlas.issues.ui.detail").prev_tab()
			end,
		})
	)

	utils.insert_if(
		general,
		item("ui.help", {
			desc = "Toggle help",
			hint = false,
			opts = { nowait = true, silent = true },
			callback = function()
				help.toggle({ buffer = buf })
			end,
		})
	)

	utils.insert_if(
		general,
		item("ui.toggle_panel", {
			desc = "Toggle detail panel",
			hint = false,
			callback = function()
				require("atlas.issues.ui.detail").close()
			end,
		})
	)

	utils.insert_if(
		general,
		item("ui.close", {
			desc = "Close detail panel",
			hint = false,
			opts = { nowait = true, silent = true },
			callback = function()
				if not help.is_open() then
					require("atlas.issues.ui.detail").close()
				end
			end,
		})
	)

	help.register("General", general, { index = 300, buffer = buf })
end

---@param buf integer
function M.remove(buf)
	local general = {}
	utils.insert_if(general, remove_item("ui.next_item"))
	utils.insert_if(general, remove_item("ui.previous_item"))
	utils.insert_if(general, remove_item("ui.open_actions"))
	utils.insert_if(general, remove_item("issues.change_assignee"))
	utils.insert_if(general, remove_item("issues.change_reporter"))
	utils.insert_if(general, remove_item("issues.change_label"))
	utils.insert_if(general, remove_item("issues.edit_issue"))
	utils.insert_if(general, remove_item("ui.next_panel_tab"))
	utils.insert_if(general, remove_item("ui.previous_panel_tab"))
	utils.insert_if(general, remove_item("ui.help"))
	utils.insert_if(general, remove_item("ui.toggle_panel"))
	utils.insert_if(general, remove_item("ui.close"))
	help.remove("General", general, { buffer = buf })
end

return M
