local M = {}

local notify = require("atlas.core.notify")
local resolver = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local registrations = {}

---@return PullRequest|nil, PullsRepo|nil
local function selected_pr()
	local navigation = require("atlas.ui.navigation")
	local node = navigation.current_item()
	if type(node) ~= "table" then
		return nil, nil
	end
	if (node.kind == "pr" or node.kind == "pr_meta") and type(node.pr) == "table" then
		return node.pr, node.repo
	end
	return nil, nil
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
---@param views AtlasPullsViewConfig[]
function M.register(buf, views)
	local help = require("atlas.ui.popups.help")
	M.remove(buf)
	local state = require("atlas.pulls.state")
	local provider_name = state.provider and state.provider.name or "Pulls"

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
					local controller = require("atlas.pulls.ui.dashboard.controller")
					controller.switch_view(v)
				end,
			})
		end
	end

	utils.insert_if(
		items,
		item("ui.filter", {
			desc = "Edit filter",
			hint_desc = "Filter",
			index = 10,
			opts = { nowait = true, silent = true },
			callback = function()
				vim.ui.input({ prompt = "Filter: ", default = state.filter_text or "" }, function(input)
					if input == nil then
						return
					end
					require("atlas.pulls.ui.dashboard.controller").apply_filter_text(input)
				end)
			end,
		})
	)

	local STATUS_TOGGLES = {
		{ status = "OPEN", action_id = "pulls.filters.open", index = 20 },
		{ status = "MERGED", action_id = "pulls.filters.merged", index = 21 },
		{ status = "DECLINED", action_id = "pulls.filters.declined", index = 22 },
	}
	for _, sf in ipairs(STATUS_TOGGLES) do
		local s = sf
		utils.insert_if(
			items,
			item(s.action_id, {
				desc = string.format("Toggle %s filter", s.status:lower()),
				hint_desc = "Toggle " .. s.status:sub(1, 1):upper() .. s.status:sub(2):lower(),
				index = s.index,
				callback = function()
					local controller = require("atlas.pulls.ui.dashboard.controller")
					controller.toggle_status_filter(s.status)
				end,
			})
		)
	end

	if state.provider and state.provider.capabilities.core and state.provider.capabilities.core.create_pr then
		utils.insert_if(
			items,
			item("pulls.create_pr", {
				desc = "Create pull request",
				hint_desc = "Create",
				index = 30,
				callback = function()
					require("atlas.pulls.create.pr").start()
				end,
			})
		)
	end

	utils.insert_if(
		items,
		item("ui.refresh", {
			desc = "Refetch selected PR",
			hint = false,
			callback = function()
				local pr = selected_pr()
				if pr == nil then
					notify.warn("No PR selected")
					return
				end
				require("atlas.pulls.ui.dashboard.controller").refresh_pr(pr)
			end,
		})
	)

	utils.insert_if(
		items,
		item("ui.refresh_view", {
			desc = "Refresh current view",
			hint = false,
			callback = function()
				require("atlas.pulls.ui.dashboard.controller").refresh_current_view()
			end,
		})
	)

	help.register(provider_name, items, { index = 220, buffer = buf })
	registrations[buf] = {
		{ group = provider_name, items = items },
	}
end

---@param buf integer
function M.remove(buf)
	local registered = registrations[buf]
	if registered == nil then
		return
	end
	local help = require("atlas.ui.popups.help")
	for _, registration in ipairs(registered) do
		help.remove(registration.group, registration.items, { buffer = buf })
	end
	registrations[buf] = nil
end

return M
