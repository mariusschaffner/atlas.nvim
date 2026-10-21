-- Stacks the issue detail view's sidebar fields (DESIGN-detail-view.md §4):
-- Assignee, Labels, Milestone, Start->Due, a divider, Development, and the
-- "Opened by ..." footer. Each field is `sidebar_field`'s one reusable
-- component; this module just lays them out and tracks a field's region (for
-- `inline_field_edit` anchoring) when it has an `id`.
local M = {}

local sidebar_field = require("atlas.ui.components.sidebar_field")
local shared_utils = require("atlas.ui.shared.utils")

---@class IssuesSidebarEntry : AtlasSidebarField
---@field id string|nil When set, the field's region is reported back via `regions`.
---@field ids string[]|nil Like `id`, but reports the same region under several keys (e.g. a combined "Start -> Due" line anchors both `start_date` and `due_date` edits).
---@field divider boolean|nil When true, renders a horizontal divider instead of a field.
---@field text string|nil When set (no `id`/`divider`), renders a single dim plain line (e.g. the footer).

---@param entries IssuesSidebarEntry[]
---@param width integer
---@return string[] lines
---@return AtlasUIHighlight[] highlights
---@return table<string, AtlasFieldBoxRegion> regions
function M.render(entries, width)
	width = math.max(1, width)
	local lines, spans, regions = {}, {}, {}

	for idx, entry in ipairs(entries) do
		if idx > 1 then
			table.insert(lines, "")
		end
		if entry.divider then
			table.insert(lines, string.rep("─", width))
			table.insert(spans, { line = #lines - 1, line_hl_group = "AtlasBorder" })
		elseif entry.text ~= nil then
			table.insert(lines, entry.text)
			table.insert(spans, { line = #lines - 1, start_col = 0, end_col = #entry.text, hl_group = "AtlasTextMuted" })
		else
			local base = #lines
			local field_lines, field_spans = sidebar_field.render(entry, width)
			shared_utils.append_block(lines, spans, { lines = field_lines, highlights = field_spans })
			-- Value area starts right after the label line -- good enough for
			-- `inline_field_edit`'s positioning needs (it just needs a
			-- row/col/width/height to float its overlay over).
			local region = { row = base + 1, col = 0, width = width, height = math.max(1, #field_lines - 1) }
			if entry.id then
				regions[entry.id] = region
			end
			for _, id in ipairs(entry.ids or {}) do
				regions[id] = region
			end
		end
	end

	return lines, spans, regions
end

return M
