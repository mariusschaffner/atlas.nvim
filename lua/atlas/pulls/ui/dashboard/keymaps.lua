local M = {}

local notify = require("atlas.core.notify")
local resolver = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local actions = require("atlas.pulls.actions")
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
	---@param id AtlasPullActionId
	---@param needs_pr boolean
	local function run_action(id, needs_pr)
		local pr = selected_pr()

		if needs_pr and not pr then
			notify.warn("No PR selected")
			return
		end
		if state.provider then
			actions.run(id, {
				provider = state.provider,
				pr = pr,
				current_user = state.current_user,
				buf = buf,
			}, function(result)
				if pr ~= nil and result ~= nil and result.changed_pr then
					require("atlas.pulls.ui.dashboard.controller").refresh_pr(pr)
				end
			end)
		end
	end

	local items = {}

	for _, view in ipairs(views) do
		if view.key ~= nil and view.key ~= "" then
			local v = view
			table.insert(items, {
				key = v.key,
				desc = string.format("Switch to %s", v.name),
				hidden = true,
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
		{ status = "OPEN", action_id = "pulls.filters.open" },
		{ status = "MERGED", action_id = "pulls.filters.merged" },
		{ status = "DECLINED", action_id = "pulls.filters.declined" },
	}
	for _, sf in ipairs(STATUS_TOGGLES) do
		local s = sf
		utils.insert_if(
			items,
			item(s.action_id, {
				desc = string.format("Toggle %s filter", s.status:lower()),
				callback = function()
					local controller = require("atlas.pulls.ui.dashboard.controller")
					controller.toggle_status_filter(s.status)
				end,
			})
		)
	end

	utils.insert_if(
		items,
		item("pulls.open_diff", {
			desc = "Open PR diff",
			opts = { nowait = true },
			callback = function()
				run_action("open_diff", true)
			end,
		})
	)

	utils.insert_if(
		items,
		item("pulls.checkout", {
			desc = "Checkout PR branch",
			opts = { nowait = true },
			callback = function()
				run_action("checkout", true)
			end,
		})
	)

	utils.insert_if(
		items,
		item("ui.refresh", {
			desc = "Refetch selected PR",
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
			callback = function()
				require("atlas.pulls.ui.dashboard.controller").refresh_current_view()
			end,
		})
	)

	help.register(provider_name, items, { index = 220, buffer = buf })

	local general = {}
	utils.insert_if(
		general,
		item("pulls.toggle_repo_panel", {
			desc = "Open repo panel",
			opts = { nowait = true, silent = true },
			callback = function()
				local _, repo = selected_pr()
				if repo == nil then
					notify.warn("No repository selected")
					return
				end
				local repo_detail = require("atlas.pulls.ui.repo_detail")
				if repo_detail.is_open() then
					repo_detail.close()
					return
				end
				repo_detail.open(repo, {
					provider = require("atlas.pulls.state").provider,
				})
			end,
		})
	)
	help.register("General", general, { buffer = buf })
	registrations[buf] = {
		{ group = provider_name, items = items },
		{ group = "General", items = general },
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
