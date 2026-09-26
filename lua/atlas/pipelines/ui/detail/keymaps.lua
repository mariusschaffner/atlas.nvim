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

	-- Same keys as the dashboard's page switcher, repurposed here to cycle
	-- the stage selected in the graph/bottom part (different buffer, so no
	-- clash -- see core/keymaps.lua's ALLOWED_CONFLICTS for the same pattern).
	utils.insert_if(
		items,
		resolver.item("ui.next_page", {
			desc = "Next stage",
			hint_desc = "Stage+",
			opts = { nowait = true, silent = true },
			callback = function()
				require("atlas.pipelines.ui.detail").next_stage()
			end,
		})
	)

	utils.insert_if(
		items,
		resolver.item("ui.previous_page", {
			desc = "Previous stage",
			hint_desc = "Stage-",
			opts = { nowait = true, silent = true },
			callback = function()
				require("atlas.pipelines.ui.detail").previous_stage()
			end,
		})
	)

	-- Same keys as the issue/pulls detail views' own top-level tab switcher,
	-- repurposed here to cycle the active stage's job tabs.
	utils.insert_if(
		items,
		resolver.item("ui.next_panel_tab", {
			desc = "Next job",
			hint = false,
			opts = { nowait = true },
			callback = function()
				require("atlas.pipelines.ui.detail").next_job()
			end,
		})
	)

	utils.insert_if(
		items,
		resolver.item("ui.previous_panel_tab", {
			desc = "Previous job",
			hint = false,
			opts = { nowait = true },
			callback = function()
				require("atlas.pipelines.ui.detail").previous_job()
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
	utils.insert_if(general, resolver.remove_item("ui.next_page"))
	utils.insert_if(general, resolver.remove_item("ui.previous_page"))
	utils.insert_if(general, resolver.remove_item("ui.next_panel_tab"))
	utils.insert_if(general, resolver.remove_item("ui.previous_panel_tab"))
	help.remove("General", general, { buffer = buf })
end

return M
