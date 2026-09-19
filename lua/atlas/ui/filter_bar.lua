-- Unified filter bar: replaces the old "Issues | Pulls" domain tab strip
-- (dashboard_tabs.lua) and the per-domain filter row that used to be
-- duplicated in issues/pulls renderer.lua. One bordered box, always
-- visible, spanning the full width, showing the active domain's
-- filter_text (which always includes a live-editable `view:<domain>`
-- token). The notification hint lives in the statusline instead, next to
-- the help indicator.
local M = {}

local bordered_box = require("atlas.ui.components.bordered_box")
local icons = require("atlas.ui.shared.icons")

local STATE_MODULES = {
	issues = "atlas.issues.state",
	pulls = "atlas.pulls.state",
}

---@param domain "issues"|"pulls"|nil
---@param width integer
---@return string[] lines
---@return table[] highlights
function M.render(domain, width)
	local mod = domain and STATE_MODULES[domain]
	local filter_text = (mod and require(mod).filter_text) or ""
	local search_icon = icons.general("search")
	local content = string.format("%s %s", search_icon, filter_text)

	return bordered_box.render({
		width = width,
		box_width = width,
		title = "Filter",
		content_lines = { content },
		content_highlights = { { line = 0, start_col = 0, end_col = #content, hl_group = "AtlasTextMuted" } },
		border_hl = "AtlasFilterBarBorder",
	})
end

return M
