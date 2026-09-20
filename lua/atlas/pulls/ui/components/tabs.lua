local M = {}

local tabs = require("atlas.ui.components.tabs")

---@param items PullsDetailTab[]|PullsRepoDetailTab[]
---@param active_tab string
---@param opts { width: integer, padding_x?: integer, divider?: boolean }
---@return string[], table[]
function M.render(items, active_tab, opts)
	return tabs.render(items, active_tab, opts.width, {
		active_hl = "AtlasFilterActive",
		inactive_hl = "AtlasTextMuted",
		gap = " ",
		padding_x = opts.padding_x,
		divider = opts.divider,
	})
end

---@param items PullsDetailTab[]|PullsRepoDetailTab[]
---@param active_tab string
---@param border_hl string|nil
---@return { [1]: string, [2]: string }[]
function M.title_chunks(items, active_tab, border_hl)
	return tabs.title_chunks(items, active_tab, {
		active_hl = "AtlasDetailTabActive",
		inactive_hl = "AtlasTextMuted",
		gap = " - ",
		border_hl = border_hl,
	})
end

return M
