local M = {}

local help = require("atlas.ui.popups.help")
local resolver = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")

---@param buf integer
function M.register(buf)
	local items = {}

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
					require("atlas.pipelines.ui.detail").close()
				end
			end,
		})
	)

	M.remove(buf)
	help.register("General", items, { index = 300, buffer = buf })
end

---@param buf integer
function M.remove(buf)
	local general = {}
	utils.insert_if(general, resolver.remove_item("ui.help"))
	utils.insert_if(general, resolver.remove_item("ui.close"))
	help.remove("General", general, { buffer = buf })
end

return M
