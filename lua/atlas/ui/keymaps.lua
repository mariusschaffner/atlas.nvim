local M = {}

local help = require("atlas.ui.popups.help")
local navigation = require("atlas.ui.navigation")
local resolver = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")

local function domain_dashboard()
	local domain = require("atlas.ui.state").domain
	return domain and require("atlas." .. domain .. ".ui.dashboard") or nil
end

---@param buf integer
function M.register(buf)
	local items = {}

	utils.insert_if(
		items,
		resolver.item("ui.next_item", {
			desc = "Next item",
			hidden = true,
			hint = false,
			callback = function()
				navigation.move_cursor("down")
			end,
		})
	)

	utils.insert_if(
		items,
		resolver.item("ui.previous_item", {
			desc = "Previous item",
			hidden = true,
			hint = false,
			callback = function()
				navigation.move_cursor("up")
			end,
		})
	)

	utils.insert_if(
		items,
		resolver.item("ui.first_item", {
			desc = "Go to first item",
			hidden = true,
			hint = false,
			callback = function()
				navigation.focus_first_item()
			end,
		})
	)

	utils.insert_if(
		items,
		resolver.item("ui.last_item", {
			desc = "Go to last item",
			hidden = true,
			hint = false,
			callback = function()
				navigation.focus_last_item()
			end,
		})
	)

	utils.insert_if(
		items,
		resolver.item("ui.help", {
			desc = "Toggle this help popup",
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
			desc = "Close Atlas window",
			hint = false,
			opts = { nowait = true, silent = true },
			callback = function()
				if help.is_open() then
					return
				end
				require("atlas.ui.dashboard").close()
			end,
		})
	)

	utils.insert_if(
		items,
		resolver.item("ui.inspect", {
			desc = "Inspect",
			index = 10,
			opts = { nowait = true, silent = true },
			callback = function()
				local dashboard = domain_dashboard()
				if dashboard then
					dashboard.toggle_detail()
				end
			end,
		})
	)

	utils.insert_if(
		items,
		resolver.item("ui.next_panel_tab", {
			desc = "Tabs",
			hint = false,
			opts = { nowait = true },
			callback = function()
				require("atlas.ui.dashboard").next_domain()
			end,
		})
	)

	utils.insert_if(
		items,
		resolver.item("ui.previous_panel_tab", {
			desc = "Tabs",
			hint = false,
			opts = { nowait = true },
			callback = function()
				require("atlas.ui.dashboard").prev_domain()
			end,
		})
	)

	utils.insert_if(
		items,
		resolver.item("ui.notifications.open", {
			desc = "Open notifications",
			hint = false,
			callback = function()
				require("atlas.ui.notifications").open()
			end,
		})
	)

	M.remove(buf)
	navigation.attach(buf)
	help.register("General", items, { index = 210, buffer = buf })
end

---@param buf integer
function M.remove(buf)
	navigation.detach(buf)
	local items = {}
	utils.insert_if(items, resolver.remove_item("ui.next_item"))
	utils.insert_if(items, resolver.remove_item("ui.previous_item"))
	utils.insert_if(items, resolver.remove_item("ui.first_item"))
	utils.insert_if(items, resolver.remove_item("ui.last_item"))
	utils.insert_if(items, resolver.remove_item("ui.help"))
	utils.insert_if(items, resolver.remove_item("ui.close"))
	utils.insert_if(items, resolver.remove_item("ui.inspect"))
	utils.insert_if(items, resolver.remove_item("ui.next_panel_tab"))
	utils.insert_if(items, resolver.remove_item("ui.previous_panel_tab"))
	utils.insert_if(items, resolver.remove_item("ui.notifications.open"))

	help.remove("General", items, { buffer = buf })
end

return M
