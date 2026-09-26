local M = {}

local resolver = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local registrations = {}

---@param buf integer
---@param views PipelinesViewConfig[]
function M.register(buf, views)
	local help = require("atlas.ui.popups.help")
	local controller = require("atlas.pipelines.ui.dashboard.controller")
	local state = require("atlas.pipelines.state")
	local provider = assert(state.provider)
	local provider_name = provider.name

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
			hint = false,
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
					completion = require("atlas.ui.filter_completion").for_domain("pipelines"),
					on_save = function(text, done)
						dashboard.apply_filter_text(text)
						done(true)
					end,
					on_done = function() end,
				})
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
