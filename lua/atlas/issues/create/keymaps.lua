local M = {}

local help = require("atlas.ui.popups.help")
local resolver = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local state = require("atlas.issues.create.state")

---@param buf integer
function M.register(buf)
	local items = {}
	local gitlab = require("atlas.issues.create.gitlab")

	utils.insert_if(
		items,
		resolver.item("issues.create_field_type", {
			desc = "Edit type",
			hint = false,
			opts = { nowait = true, silent = true },
			callback = function()
				gitlab.edit_type()
			end,
		})
	)

	utils.insert_if(
		items,
		resolver.item("issues.edit_issue", {
			desc = "Edit title",
			hint = false,
			opts = { nowait = true, silent = true },
			callback = function()
				gitlab.edit_title()
			end,
		})
	)

	if state.type == "milestone" then
		utils.insert_if(
			items,
			resolver.item("issues.change_milestone_start_date", {
				desc = "Edit start date",
				hint = false,
				opts = { nowait = true, silent = true },
				callback = function()
					gitlab.edit_start_date()
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
					gitlab.edit_due_date()
				end,
			})
		)
	elseif state.type == "issue" then
		utils.insert_if(
			items,
			resolver.item("issues.change_assignee", {
				desc = "Edit assignees",
				hint = false,
				opts = { nowait = true, silent = true },
				callback = function()
					gitlab.edit_assignees()
				end,
			})
		)
		utils.insert_if(
			items,
			resolver.item("issues.change_label", {
				desc = "Edit labels",
				hint = false,
				opts = { nowait = true, silent = true },
				callback = function()
					gitlab.edit_labels()
				end,
			})
		)
		utils.insert_if(
			items,
			resolver.item("issues.change_milestone", {
				desc = "Edit milestone",
				hint = false,
				opts = { nowait = true, silent = true },
				callback = function()
					gitlab.edit_milestone()
				end,
			})
		)
		utils.insert_if(
			items,
			resolver.item("issues.change_start_date", {
				desc = "Edit start date",
				hint = false,
				opts = { nowait = true, silent = true },
				callback = function()
					gitlab.edit_start_date()
				end,
			})
		)
		utils.insert_if(
			items,
			resolver.item("issues.change_due_date", {
				desc = "Edit due date",
				hint = false,
				opts = { nowait = true, silent = true },
				callback = function()
					gitlab.edit_due_date()
				end,
			})
		)
		utils.insert_if(
			items,
			resolver.item("issues.create_field_templates", {
				desc = "Browse issue templates",
				hint = false,
				opts = { nowait = true, silent = true },
				callback = function()
					gitlab.edit_templates()
				end,
			})
		)
	end

	utils.insert_if(
		items,
		resolver.item("ui.edit_description", {
			desc = "Edit description",
			hint = false,
			opts = { nowait = true, silent = true },
			callback = function()
				gitlab.edit_description()
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
			desc = "Discard creation",
			hint = false,
			opts = { nowait = true, silent = true },
			callback = function()
				if not help.is_open() then
					gitlab.close()
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
	utils.insert_if(items, resolver.remove_item("issues.create_field_type"))
	utils.insert_if(items, resolver.remove_item("issues.edit_issue"))
	utils.insert_if(items, resolver.remove_item("issues.change_milestone_start_date"))
	utils.insert_if(items, resolver.remove_item("issues.change_milestone_due_date"))
	utils.insert_if(items, resolver.remove_item("issues.change_assignee"))
	utils.insert_if(items, resolver.remove_item("issues.change_label"))
	utils.insert_if(items, resolver.remove_item("issues.change_milestone"))
	utils.insert_if(items, resolver.remove_item("issues.change_start_date"))
	utils.insert_if(items, resolver.remove_item("issues.change_due_date"))
	utils.insert_if(items, resolver.remove_item("issues.create_field_templates"))
	utils.insert_if(items, resolver.remove_item("ui.edit_description"))
	utils.insert_if(items, resolver.remove_item("ui.help"))
	utils.insert_if(items, resolver.remove_item("ui.close"))
	help.remove("General", items, { buffer = buf })
end

return M
