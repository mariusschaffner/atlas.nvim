local M = {}

local help = require("atlas.ui.popups.help")
local resolver = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local state = require("atlas.issues.ui.detail.milestone.state")

---@param buf integer
function M.register(buf)
	local items = {}

	utils.insert_if(
		items,
		resolver.item("ui.next_panel_tab", {
			desc = "Next detail tab",
			hint = false,
			opts = { nowait = true },
			callback = function()
				require("atlas.issues.ui.detail.milestone").next_tab()
			end,
		})
	)

	utils.insert_if(
		items,
		resolver.item("ui.previous_panel_tab", {
			desc = "Previous detail tab",
			hint = false,
			opts = { nowait = true },
			callback = function()
				require("atlas.issues.ui.detail.milestone").prev_tab()
			end,
		})
	)

	utils.insert_if(
		items,
		resolver.item("issues.change_milestone_title", {
			desc = "Edit title",
			hint = false,
			opts = { nowait = true, silent = true },
			callback = function()
				require("atlas.issues.ui.detail.milestone").edit_title()
			end,
		})
	)

	-- Both share the "i" key (see core/keymaps.lua's ALLOWED_CONFLICTS): only
	-- one of the two tabs is ever active, so only one of these is ever
	-- actually registered at a time -- re-registered on every tab switch
	-- (see change_tab) to stay in sync.
	if state.current_tab == "work_items" then
		utils.insert_if(
			items,
			resolver.item("ui.inspect", {
				desc = "Open selected work item",
				hint = false, -- no hint shown; matches the Description tab's own edit_description affordance
				opts = { nowait = true, silent = true },
				callback = function()
					require("atlas.issues.ui.detail.milestone").open_selected_work_item()
				end,
			})
		)
	else
		utils.insert_if(
			items,
			resolver.item("ui.edit_description", {
				desc = "Edit description",
				hint = false, -- no hint shown; the content box's editable border color is the only affordance
				opts = { nowait = true, silent = true },
				callback = function()
					require("atlas.issues.ui.detail.milestone").edit_description()
				end,
			})
		)
	end

	utils.insert_if(
		items,
		resolver.item("issues.change_milestone_start_date", {
			desc = "Edit start date",
			hint = false,
			opts = { nowait = true, silent = true },
			callback = function()
				require("atlas.issues.ui.detail.milestone").edit_start_date()
			end,
		})
	)

	utils.insert_if(
		items,
		resolver.item("issues.change_milestone_due_date", {
			desc = "Edit due date",
			hint = false,
			opts = { nowait = true, silent = true },
			callback = function()
				require("atlas.issues.ui.detail.milestone").edit_due_date()
			end,
		})
	)

	utils.insert_if(
		items,
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
		items,
		resolver.item("ui.close", {
			desc = "Close detail panel",
			hint = false,
			opts = { nowait = true, silent = true },
			callback = function()
				if not help.is_open() then
					require("atlas.issues.ui.detail.milestone").close()
				end
			end,
		})
	)

	M.remove(buf)
	help.register("General", items, { index = 300, buffer = buf })
end

---@param buf integer
function M.remove(buf)
	local items = {}
	utils.insert_if(items, resolver.remove_item("ui.next_panel_tab"))
	utils.insert_if(items, resolver.remove_item("ui.previous_panel_tab"))
	utils.insert_if(items, resolver.remove_item("issues.change_milestone_title"))
	utils.insert_if(items, resolver.remove_item("ui.edit_description"))
	utils.insert_if(items, resolver.remove_item("ui.inspect"))
	utils.insert_if(items, resolver.remove_item("issues.change_milestone_start_date"))
	utils.insert_if(items, resolver.remove_item("issues.change_milestone_due_date"))
	utils.insert_if(items, resolver.remove_item("ui.help"))
	utils.insert_if(items, resolver.remove_item("ui.close"))
	help.remove("General", items, { buffer = buf })
end

return M
