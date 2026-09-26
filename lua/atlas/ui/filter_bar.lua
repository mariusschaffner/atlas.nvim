-- Unified filter bar: replaces the old "Issues | Pulls" domain tab strip
-- (dashboard_tabs.lua) and the per-domain filter row that used to be
-- duplicated in issues/pulls renderer.lua. One bordered box, always
-- visible, spanning the full width, showing the active domain's
-- filter_text (which always includes a live-editable `view:<domain>`
-- token). The notification bell and the "g? help" hint live in this box's
-- own title border (right-aligned), not the statusline -- see
-- `title_right` below.
local M = {}

local bordered_box = require("atlas.ui.components.bordered_box")
local utils = require("atlas.ui.shared.utils")
local icons = require("atlas.ui.shared.icons")
local keymaps = require("atlas.core.keymaps")

local STATE_MODULES = {
	issues = "atlas.issues.state",
	pulls = "atlas.pulls.state",
	pipelines = "atlas.pipelines.state",
}

--- Notification bell + unread count, and the "g? Help" hint, right-aligned
--- in the filter box's title border. The bell segment is omitted entirely
--- (not shown as a "no unread" icon) when there are no unread notifications.
---@param domain "issues"|"pulls"|nil
---@return string|nil text
---@return table[]|nil highlights Spans {start_col, end_col, hl_group} relative to `text`.
local function title_right(domain)
	local parts, highlights, cursor = {}, {}, 0

	local mod = domain and STATE_MODULES[domain]
	local provider = mod and require(mod).provider
	if provider and provider.capabilities and provider.capabilities.notifications then
		local count = require("atlas.ui.notifications.state").unread_count or 0
		if count > 0 then
			local bell, bell_hl = icons.general("bell_unread")
			local segment = string.format("%s %d", bell, count)
			table.insert(parts, segment)
			table.insert(highlights, { start_col = cursor, end_col = cursor + #segment, hl_group = bell_hl })
			cursor = cursor + #segment
		end
	end

	local help_keys = keymaps.resolve("ui.help")
	if help_keys and help_keys[1] then
		if #parts > 0 then
			local sep = " - "
			table.insert(parts, sep)
			cursor = cursor + #sep
		end
		local segment = string.format("%s Help", help_keys[1])
		table.insert(highlights, { start_col = cursor, end_col = cursor + #segment, hl_group = "AtlasFooterWarning" })
		table.insert(parts, segment)
		cursor = cursor + #segment
	end

	if #parts == 0 then
		return nil, nil
	end
	return table.concat(parts), highlights
end

---@param domain "issues"|"pulls"|nil
---@param width integer
---@return string[] lines
---@return table[] highlights
---@return AtlasFieldBoxRegion region The filter text's interior region, relative to the returned `lines`.
function M.render(domain, width)
	local mod = domain and STATE_MODULES[domain]
	local filter_text = (mod and require(mod).filter_text) or ""
	local right_text, right_highlights = title_right(domain)

	local lines, highlights = bordered_box.render({
		width = width,
		box_width = width,
		title = utils.field_hint_label("ui.filter", "Filter", true),
		content_lines = { filter_text },
		content_highlights = { { line = 0, start_col = 0, end_col = #filter_text, hl_group = "AtlasTextMuted" } },
		border_hl = "AtlasFilterBarBorder",
		title_right = right_text,
		title_right_highlights = right_highlights,
	})

	-- Full interior width (box_width - 2 for the left/right border columns);
	-- text_col is where the interior starts, not something to subtract from
	-- its width again. Getting this one column short used to be near-
	-- invisible against a plain dash-filled border, but it now clips the
	-- inline-edit border highlight (and the edit overlay itself) short of
	-- the right border, right where title_right lives.
	local text_col = 1
	local region = { row = 1, col = text_col, width = math.max(1, width - 2), height = 1 }
	return lines, highlights, region
end

return M
