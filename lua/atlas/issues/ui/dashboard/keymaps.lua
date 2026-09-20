local M = {}

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

---@param buf integer
---@param views IssuesViewConfig[]
function M.register(buf, views)
	local help = require("atlas.ui.popups.help")
	local controller = require("atlas.issues.ui.dashboard.controller")
	local state = require("atlas.issues.state")
	local provider = assert(state.provider)
	local provider_name = provider.name
	local function context(issue)
		return { provider = provider, issue = issue, current_user = state.current_user }
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
		resolver.item("ui.filter", {
			desc = "Edit filter",
			hint_desc = "Filter",
			index = 10,
			opts = { nowait = true, silent = true },
			callback = function()
				local dashboard = require("atlas.ui.dashboard")
				local dashboard_body = require("atlas.ui.dashboard_body")
				local win = dashboard.win()
				local region = dashboard_body.filter_region()
				if win == nil or region == nil then
					return
				end
				require("atlas.ui.inline_field_edit").start({
					anchor_win = win,
					row = region.row,
					col = region.col,
					width = region.width,
					height = region.height,
					seed_text = state.filter_text or "",
					submit_keys = { "<CR>" },
					word_segment = true,
					completion = require("atlas.ui.filter_completion").for_domain("issues"),
					on_save = function(text, done)
						dashboard.apply_filter_text(text)
						done(true)
					end,
					on_done = function() end,
				})
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
			resolver.item(s.action_id, {
				desc = string.format("Show %s issues", s.status:lower()),
				hint_desc = "Toggle " .. s.status:sub(1, 1):upper() .. s.status:sub(2):lower(),
				hint = not state.status_filters[s.status],
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
			resolver.item("issues.create_issue", {
				desc = "Create issue",
				hint_desc = "Create",
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
		resolver.item("ui.toggle_fold", {
			desc = "Toggle milestone/group fold",
			hint_desc = "Fold",
			opts = { nowait = true, silent = true },
			callback = function()
				controller.toggle_current_issue_collapsed()
			end,
		})
	)

	utils.insert_if(
		items,
		resolver.item("ui.toggle_all_folds", {
			desc = "Toggle all milestone/group folds",
			hint = false,
			opts = { nowait = true, silent = true },
			callback = function()
				controller.toggle_all_issues_collapsed()
			end,
		})
	)

	utils.insert_if(
		items,
		resolver.item("ui.refresh", {
			desc = "Reload selected issue",
			hint = false,
			callback = function()
				controller.refresh_current_issue()
			end,
		})
	)

	utils.insert_if(
		items,
		resolver.item("ui.refresh_view", {
			desc = "Refresh current view",
			hint = false,
			callback = function()
				controller.refresh_current_view()
			end,
		})
	)

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
