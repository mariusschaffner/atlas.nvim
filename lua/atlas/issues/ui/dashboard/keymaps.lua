local M = {}

local notify = require("atlas.core.notify")
local resolver = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local actions = require("atlas.issues.actions")
local registrations = {}

---@return Issue|nil
local function selected_issue()
	local navigation = require("atlas.ui.navigation")
	local node = navigation.current_item()
	if type(node) ~= "table" then
		return nil
	end
	if node.kind == "issue" and type(node._issue) == "table" then
		return node._issue
	end
	return nil
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

---@param buf integer
---@param views IssuesViewConfig[]
function M.register(buf, views)
	local help = require("atlas.ui.popups.help")
	local controller = require("atlas.issues.ui.dashboard.controller")
	local state = require("atlas.issues.state")
	local provider = assert(state.provider)
	local provider_name = provider.name
	local capabilities = provider.capabilities
	local function context(issue)
		return { provider = provider, issue = issue, current_user = state.current_user }
	end
	local function supports(action_id)
		for _, action in ipairs((capabilities.actions and capabilities.actions.items) or {}) do
			if action.id == action_id then
				return true
			end
		end
		return false
	end

	local items = {}

	for _, view in ipairs(views) do
		if view.key ~= nil and view.key ~= "" then
			local v = view
			table.insert(items, {
				key = v.key,
				desc = string.format("Switch to %s", v.name),
				hidden = true,
				hint = false,
				callback = function()
					controller.switch_view(v)
				end,
			})
		end
	end

	utils.insert_if(
		items,
		item("ui.filter", {
			desc = "Edit filter",
			hint_desc = "filter",
			index = 10,
			opts = { nowait = true, silent = true },
			callback = function()
				vim.ui.input({ prompt = "Filter: ", default = state.filter_text or "" }, function(input)
					if input == nil then
						return
					end
					controller.apply_filter_text(input)
				end)
			end,
		})
	)

	local STATUS_TOGGLES = {
		{ status = "OPEN", action_id = "issues.filters.open", index = 20 },
		{ status = "CLOSED", action_id = "issues.filters.closed", index = 21 },
	}
	for _, sf in ipairs(STATUS_TOGGLES) do
		local s = sf
		utils.insert_if(
			items,
			item(s.action_id, {
				desc = string.format("Show %s issues", s.status:lower()),
				hint_desc = "toggle " .. s.status:lower(),
				index = s.index,
				opts = { nowait = true, silent = true },
				callback = function()
					controller.set_status_filter(s.status)
				end,
			})
		)
	end

	if actions.is_available("create_issue", context(nil)) then
		utils.insert_if(
			items,
			item("issues.create_issue", {
				desc = "Create issue",
				hint_desc = "create",
				index = 30,
				callback = function()
					local issue = selected_issue()
					actions.run("create_issue", context(issue), controller.apply_action_result)
				end,
			})
		)
	end

	utils.insert_if(
		items,
		item("ui.refresh", {
			desc = "Reload selected issue",
			hint = false,
			callback = function()
				controller.refresh_current_issue()
			end,
		})
	)

	utils.insert_if(
		items,
		item("ui.refresh_view", {
			desc = "Refresh current view",
			hint = false,
			callback = function()
				controller.refresh_current_view()
			end,
		})
	)

	if supports("edit_issue") then
		utils.insert_if(
			items,
			item("issues.edit_issue", {
				desc = "Edit issue",
				hint_desc = "edit",
				index = 31,
				callback = function()
					local issue = selected_issue()
					if issue == nil then
						notify.warn("No issue selected")
						return
					end
					actions.run("edit_issue", context(issue), controller.apply_action_result)
				end,
			})
		)
	end

	M.remove(buf)
	help.register(provider_name, items, {
		index = 230,
		buffer = buf,
	})
	registrations[buf] = { group = provider_name, items = items }
end

---@param buf integer
function M.remove(buf)
	local registration = registrations[buf]
	if registration then
		require("atlas.ui.popups.help").remove(registration.group, registration.items, { buffer = buf })
		registrations[buf] = nil
	end
end

return M
