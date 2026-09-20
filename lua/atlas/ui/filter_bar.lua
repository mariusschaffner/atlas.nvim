-- Unified filter bar: replaces the old "Issues | Pulls" domain tab strip
-- (dashboard_tabs.lua) and the per-domain filter row that used to be
-- duplicated in issues/pulls renderer.lua. One bordered box, always
-- visible, spanning the full width, showing the active domain's
-- filter_text (which always includes a live-editable `view:<domain>`
-- token). The notification hint lives in the statusline instead, next to
-- the help indicator.
local M = {}

local bordered_box = require("atlas.ui.components.bordered_box")
local utils = require("atlas.ui.shared.utils")

local STATE_MODULES = {
	issues = "atlas.issues.state",
	pulls = "atlas.pulls.state",
}

---@param domain "issues"|"pulls"|nil
---@param width integer
---@return string[] lines
---@return table[] highlights
---@return AtlasFieldBoxRegion region The filter text's interior region, relative to the returned `lines`.
function M.render(domain, width)
	local mod = domain and STATE_MODULES[domain]
	local filter_text = (mod and require(mod).filter_text) or ""

	local lines, highlights = bordered_box.render({
		width = width,
		box_width = width,
		title = utils.field_hint_label("ui.filter", "Filter", true),
		content_lines = { filter_text },
		content_highlights = { { line = 0, start_col = 0, end_col = #filter_text, hl_group = "AtlasTextMuted" } },
		border_hl = "AtlasFilterBarBorder",
	})

	local text_col = 1
	local region = { row = 1, col = text_col, width = math.max(1, width - 2 - text_col), height = 1 }
	return lines, highlights, region
end

return M
