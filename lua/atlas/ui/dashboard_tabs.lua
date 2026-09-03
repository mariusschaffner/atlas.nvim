local M = {}

local tabs = require("atlas.ui.components.tabs")

M.items = {
	{ key = "issues", label = "Issues" },
	{ key = "pulls", label = "Pulls" },
}

---@param active_domain string|nil
---@param width integer
---@return string[], table[]
function M.render(active_domain, width)
	return tabs.render(M.items, active_domain, width, {
		active_hl = "Title",
		inactive_hl = "AtlasTextMuted",
		gap = "  ",
		padding_x = 1,
	})
end

return M
