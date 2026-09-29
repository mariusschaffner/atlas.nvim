local M = {}

local help = require("atlas.ui.popups.help")
local resolver = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local state = require("atlas.ui.create.state")

---@param buf integer
function M.register(buf)
	local items = {}
	local shell = require("atlas.ui.create")

	utils.insert_if(
		items,
		resolver.item("ui.create.field_type", {
			desc = "Edit type",
			hint = false,
			opts = { nowait = true, silent = true },
			callback = function()
				shell.edit_type()
			end,
		})
	)

	utils.insert_if(
		items,
		resolver.item("ui.create.field_title", {
			desc = "Edit title",
			hint = false,
			opts = { nowait = true, silent = true },
			callback = function()
				shell.edit_title()
			end,
		})
	)

	if state.type == "milestone" then
		local issues_gitlab = require("atlas.issues.create.gitlab")
		utils.insert_if(
			items,
			resolver.item("issues.change_milestone_start_date", {
				desc = "Edit start date",
				hint = false,
				opts = { nowait = true, silent = true },
				callback = function()
					issues_gitlab.edit_start_date()
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
					issues_gitlab.edit_due_date()
				end,
			})
		)
	elseif state.type == "issue" then
		local issues_gitlab = require("atlas.issues.create.gitlab")
		utils.insert_if(
			items,
			resolver.item("issues.change_assignee", {
				desc = "Edit assignees",
				hint = false,
				opts = { nowait = true, silent = true },
				callback = function()
					issues_gitlab.edit_assignees()
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
					issues_gitlab.edit_labels()
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
					issues_gitlab.edit_milestone()
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
					issues_gitlab.edit_start_date()
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
					issues_gitlab.edit_due_date()
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
					issues_gitlab.edit_templates()
				end,
			})
		)
	elseif state.type == "merge_request" then
		local pulls_gitlab = require("atlas.pulls.create.gitlab")
		utils.insert_if(
			items,
			resolver.item("pulls.create_field_source_branch", {
				desc = "Edit source branch",
				hint = false,
				opts = { nowait = true, silent = true },
				callback = function()
					pulls_gitlab.edit_source_branch()
				end,
			})
		)
		utils.insert_if(
			items,
			resolver.item("pulls.edit_target_branch", {
				desc = "Edit target branch",
				hint = false,
				opts = { nowait = true, silent = true },
				callback = function()
					pulls_gitlab.edit_target_branch()
				end,
			})
		)
		utils.insert_if(
			items,
			resolver.item("pulls.edit_assignees", {
				desc = "Edit assignees",
				hint = false,
				opts = { nowait = true, silent = true },
				callback = function()
					pulls_gitlab.edit_assignees()
				end,
			})
		)
		utils.insert_if(
			items,
			resolver.item("pulls.edit_labels", {
				desc = "Edit labels",
				hint = false,
				opts = { nowait = true, silent = true },
				callback = function()
					pulls_gitlab.edit_labels()
				end,
			})
		)
		utils.insert_if(
			items,
			resolver.item("pulls.edit_reviewers", {
				desc = "Edit reviewers",
				hint = false,
				opts = { nowait = true, silent = true },
				callback = function()
					pulls_gitlab.edit_reviewers()
				end,
			})
		)
		utils.insert_if(
			items,
			resolver.item("pulls.create_field_draft", {
				desc = "Toggle draft",
				hint = false,
				opts = { nowait = true, silent = true },
				callback = function()
					pulls_gitlab.toggle_draft()
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
				shell.edit_description()
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
					shell.close()
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
	utils.insert_if(items, resolver.remove_item("ui.create.field_type"))
	utils.insert_if(items, resolver.remove_item("ui.create.field_title"))
	utils.insert_if(items, resolver.remove_item("issues.change_milestone_start_date"))
	utils.insert_if(items, resolver.remove_item("issues.change_milestone_due_date"))
	utils.insert_if(items, resolver.remove_item("issues.change_assignee"))
	utils.insert_if(items, resolver.remove_item("issues.change_label"))
	utils.insert_if(items, resolver.remove_item("issues.change_milestone"))
	utils.insert_if(items, resolver.remove_item("issues.change_start_date"))
	utils.insert_if(items, resolver.remove_item("issues.change_due_date"))
	utils.insert_if(items, resolver.remove_item("issues.create_field_templates"))
	utils.insert_if(items, resolver.remove_item("pulls.create_field_source_branch"))
	utils.insert_if(items, resolver.remove_item("pulls.edit_target_branch"))
	utils.insert_if(items, resolver.remove_item("pulls.edit_assignees"))
	utils.insert_if(items, resolver.remove_item("pulls.edit_labels"))
	utils.insert_if(items, resolver.remove_item("pulls.edit_reviewers"))
	utils.insert_if(items, resolver.remove_item("pulls.create_field_draft"))
	utils.insert_if(items, resolver.remove_item("ui.edit_description"))
	utils.insert_if(items, resolver.remove_item("ui.help"))
	utils.insert_if(items, resolver.remove_item("ui.close"))
	help.remove("General", items, { buffer = buf })
end

return M
