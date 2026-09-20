-- Shared "gd/gp" statusline hints (Open diff / Focus pipeline tab) for tabs
-- that want them visible: they're real keymaps bound once for the whole PR
-- detail buffer (`pulls/ui/detail/keymaps.lua`, registered with `hint =
-- false` there), so these are hint-only entries (no `callback`) added to a
-- tab's own "Detail" group -- shown only while that tab is active, without
-- rebinding the key.
local M = {}

local resolver = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local help = require("atlas.ui.popups.help")

---@param provider PullsProvider|nil
---@return AtlasHelpKeyItem[]
function M.items(provider)
	local items = {}
	utils.insert_if(items, resolver.item("pulls.open_diff", { desc = "Open PR diff", hint_desc = "Diff" }))
	if provider and provider.capabilities.pipelines then
		utils.insert_if(
			items,
			resolver.item("pulls.open_pipeline", { desc = "Focus pipeline tab", hint_desc = "Pipeline" })
		)
	end
	return items
end

---@param buf integer
---@param group string
function M.remove(buf, group)
	local items = {}
	utils.insert_if(items, resolver.remove_item("pulls.open_diff"))
	utils.insert_if(items, resolver.remove_item("pulls.open_pipeline"))
	help.remove(group, items, { buffer = buf })
end

return M
