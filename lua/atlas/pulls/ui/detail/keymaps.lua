local M = {}

local help = require("atlas.ui.popups.help")
local resolver = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local state = require("atlas.pulls.ui.detail.state")
local actions = require("atlas.pulls.actions")
local notify = require("atlas.core.notify")

---@param pr PullRequest
---@return boolean
local function is_current_pr(pr)
	local current = state.current_pr
	return current ~= nil
		and tostring(current.id or "") == tostring(pr.id or "")
		and tostring(current.repo_full_name or "") == tostring(pr.repo_full_name or "")
end

---@param pr PullRequest
---@param buf integer|nil
---@return AtlasPullActionContext|nil
local function action_context(pr, buf)
	local provider = state.provider
	if not provider then
		return nil
	end
	return {
		provider = provider,
		pr = pr,
		details = state.current_details,
		buf = buf,
		notify = function(level, message, duration)
			notify.show(level, message, { timeout = duration })
		end,
	}
end

---@param pr PullRequest
---@param on_update (fun(pr: PullRequest, result: PullsActionResult|nil))|nil
---@param result PullsActionResult|nil
local function complete_action(pr, on_update, result)
	if not result or not result.changed_pr then
		return
	end
	if on_update then
		on_update(pr, result)
	else
		require("atlas.pulls.ui.detail").refresh()
	end
end

---@return PullsDetailTabModule|nil
local function current_tab_mod()
	for _, tab in ipairs(state.tabs) do
		if tab.key == state.current_tab then
			return tab.mod
		end
	end
end

---@param action_id string
---@return boolean
local function supports_action(action_id)
	local capability = state.provider and state.provider.capabilities.actions
	for _, action in ipairs(capability and capability.items or {}) do
		if action.id == action_id then
			return true
		end
	end
	return false
end

---@return boolean
local function open_current_line()
	local win = state.win
	if win == nil or not vim.api.nvim_win_is_valid(win) then
		return false
	end

	local lnum = vim.api.nvim_win_get_cursor(win)[1]
	local entry = (state.line_map or {})[lnum]
	local pr = state.current_pr
	if not entry or not pr then
		return false
	end

	local tab_mod = current_tab_mod()
	if tab_mod and tab_mod.on_enter then
		return tab_mod.on_enter(pr, entry) == true
	end
	return false
end

---@param buf integer
---@param opts { navigation: boolean|nil }|nil
function M.register(buf, opts)
	opts = opts or {}
	local items = {}
	local nav = require("atlas.pulls.ui.detail.navigation")

	if opts.navigation ~= false then
		utils.insert_if(
			items,
			resolver.item("ui.next_item", {
				desc = "Next selectable item",
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
			resolver.item("ui.previous_item", {
				desc = "Previous selectable item",
				opts = { nowait = true, silent = true },
				hidden = true,
				hint = false,
				callback = function()
					nav.move_cursor("up")
				end,
			})
		)
	end
	utils.insert_if(
		items,
		resolver.item("ui.select", {
			desc = "Select item",
			hint = false,
			opts = { nowait = true, silent = true },
			callback = function()
				open_current_line()
			end,
		})
	)

	local refresh_item = {
		desc = "Refresh tab",
		hint = false,
		opts = { nowait = true, silent = true },
		callback = function()
			require("atlas.pulls.ui.detail").refresh()
		end,
	}
	utils.insert_if(items, resolver.item("ui.refresh", refresh_item))
	utils.insert_if(items, resolver.item("ui.refresh_view", refresh_item))

	if state.provider and state.provider.capabilities.actions then
		utils.insert_if(
			items,
			resolver.item("ui.open_actions", {
				desc = "Open PR actions",
				hint = false,
				callback = function()
					local pr = state.current_pr
					if pr == nil then
						return
					end
					local context = action_context(pr, buf)
					if context then
						local on_update = state.on_update
						actions.open(context, function(result)
							complete_action(pr, on_update, result)
						end)
					end
				end,
			})
		)
	end

	utils.insert_if(
		items,
		resolver.item("pulls.open_diff", {
			desc = "Open PR diff",
			hint_desc = "Diff",
			index = 14,
			opts = { nowait = true },
			callback = function()
				local pr = state.current_pr
				if pr == nil then
					return
				end
				local context = action_context(pr, buf)
				if context then
					actions.run("open_diff", context)
				end
			end,
		})
	)

	if state.provider and state.provider.capabilities.pipelines then
		utils.insert_if(
			items,
			resolver.item("pulls.open_pipeline", {
				desc = "Focus pipeline tab",
				hint_desc = "Pipeline",
				index = 15,
				opts = { nowait = true },
				callback = function()
					require("atlas.pulls.ui.detail").select_tab("pipelines")
				end,
			})
		)
	end

	utils.insert_if(
		items,
		resolver.item("pulls.checkout", {
			desc = "Checkout PR branch",
			hint_desc = "Checkout",
			index = 13,
			opts = { nowait = true },
			callback = function()
				local pr = state.current_pr
				if pr == nil then
					return
				end
				local context = action_context(pr, buf)
				if context then
					actions.run("checkout", context)
				end
			end,
		})
	)

	if supports_action("edit_title") then
		utils.insert_if(
			items,
			resolver.item("pulls.edit_title", {
				desc = "Edit PR title",
				hint_desc = "Change Title",
				index = 10,
				opts = { nowait = true, silent = true },
				callback = function()
					local pr = state.current_pr
					if pr == nil then
						return
					end
					local current = action_context(pr)
					if current then
						local on_update = state.on_update
						actions.run("edit_title", current, function(result)
							complete_action(pr, on_update, result)
						end)
					end
				end,
			})
		)
	end

	if supports_action("edit_reviewers") then
		utils.insert_if(
			items,
			resolver.item("pulls.edit_reviewers", {
				desc = "Edit reviewers",
				hint_desc = "Change Reviewer",
				index = 12,
				opts = { nowait = true, silent = true },
				callback = function()
					local pr = state.current_pr
					if pr == nil then
						return
					end
					local current = action_context(pr)
					if current then
						local on_update = state.on_update
						actions.run("edit_reviewers", current, function(result)
							complete_action(pr, on_update, result)
						end)
					end
				end,
			})
		)
	end

	if supports_action("edit_assignees") then
		utils.insert_if(
			items,
			resolver.item("pulls.edit_assignees", {
				desc = "Edit assignees",
				hint_desc = "Change Assignee",
				index = 11,
				opts = { nowait = true, silent = true },
				callback = function()
					local pr = state.current_pr
					if pr == nil then
						return
					end
					local current = action_context(pr)
					if current then
						local on_update = state.on_update
						actions.run("edit_assignees", current, function(result)
							complete_action(pr, on_update, result)
						end)
					end
				end,
			})
		)
	end

	local core = state.provider and state.provider.capabilities.core

	if core and core.update_remove_source_branch then
		utils.insert_if(
			items,
			resolver.item("pulls.toggle_remove_source_branch", {
				desc = "Toggle delete source branch on merge",
				hint_desc = "Toggle Delete Branch",
				opts = { nowait = true, silent = true },
				callback = function()
					local pr = state.current_pr
					if pr == nil then
						return
					end
					local next_value = not (pr.remove_source_branch == true)
					notify.loading(
						next_value and "Enabling delete source branch..." or "Disabling delete source branch..."
					)
					core.update_remove_source_branch(pr, next_value, function(ok, err)
						if not is_current_pr(pr) then
							return
						end
						if not ok then
							notify.error("Failed to update setting: " .. tostring(err or "Unknown error"))
							return
						end
						notify.success(
							next_value and "Source branch will be deleted on merge"
								or "Source branch will be kept after merge",
							{ timeout = 1500 }
						)
						require("atlas.pulls.ui.detail").rerender()
					end)
				end,
			})
		)
	end

	M.remove(buf)
	local general = items

	utils.insert_if(
		general,
		resolver.item("ui.next_panel_tab", {
			desc = "Next detail tab",
			hint = false,
			opts = { nowait = true },
			callback = function()
				if require("atlas.pulls.ui.detail").is_open() then
					require("atlas.pulls.ui.detail").next_tab()
				end
			end,
		})
	)

	utils.insert_if(
		general,
		resolver.item("ui.previous_panel_tab", {
			desc = "Previous detail tab",
			hint = false,
			opts = { nowait = true },
			callback = function()
				if require("atlas.pulls.ui.detail").is_open() then
					require("atlas.pulls.ui.detail").prev_tab()
				end
			end,
		})
	)

	utils.insert_if(
		general,
		resolver.item("ui.help", {
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
		resolver.item("ui.toggle_panel", {
			desc = "Toggle detail panel",
			hint = false,
			callback = function()
				require("atlas.pulls.ui.detail").close()
			end,
		})
	)

	utils.insert_if(
		general,
		resolver.item("ui.close", {
			desc = "Close detail panel",
			hint = false,
			opts = { nowait = true, silent = true },
			callback = function()
				if help.is_open() then
					return
				end
				require("atlas.pulls.ui.detail").close()
			end,
		})
	)

	help.register("General", general, { index = 300, buffer = buf })
end

---@param buf integer
function M.remove(buf)
	local general = {}
	utils.insert_if(general, resolver.remove_item("ui.next_item"))
	utils.insert_if(general, resolver.remove_item("ui.previous_item"))
	utils.insert_if(general, resolver.remove_item("ui.refresh"))
	utils.insert_if(general, resolver.remove_item("ui.refresh_view"))
	utils.insert_if(general, resolver.remove_item("ui.open_actions"))
	utils.insert_if(general, resolver.remove_item("ui.select"))
	utils.insert_if(general, resolver.remove_item("pulls.open_diff"))
	utils.insert_if(general, resolver.remove_item("pulls.open_pipeline"))
	utils.insert_if(general, resolver.remove_item("pulls.checkout"))
	utils.insert_if(general, resolver.remove_item("pulls.edit_title"))
	utils.insert_if(general, resolver.remove_item("pulls.edit_reviewers"))
	utils.insert_if(general, resolver.remove_item("pulls.edit_assignees"))
	utils.insert_if(general, resolver.remove_item("pulls.toggle_remove_source_branch"))
	utils.insert_if(general, resolver.remove_item("ui.next_panel_tab"))
	utils.insert_if(general, resolver.remove_item("ui.previous_panel_tab"))
	utils.insert_if(general, resolver.remove_item("ui.help"))
	utils.insert_if(general, resolver.remove_item("ui.toggle_panel"))
	utils.insert_if(general, resolver.remove_item("ui.close"))
	help.remove("General", general, { buffer = buf })
end

return M
