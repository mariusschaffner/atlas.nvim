-- Renders a person as initials in a circle + their name, e.g. "(MS) Marius
-- Schaffner" (DESIGN-detail-view.md §4's Assignee field). Pure render
-- function: given a display name, returns the initials text and the full
-- "(XX) Name" line + highlight spans.
local M = {}

---@param name string|nil
---@return string
function M.initials(name)
	name = vim.trim(tostring(name or ""))
	if name == "" then
		return "?"
	end
	local parts = vim.split(name, "%s+")
	if #parts == 1 then
		return vim.fn.strcharpart(parts[1], 0, 2):upper()
	end
	local first = vim.fn.strcharpart(parts[1], 0, 1)
	local last = vim.fn.strcharpart(parts[#parts], 0, 1)
	return (first .. last):upper()
end

--- Renders a single-line "(XX) Name" value, e.g. for the Assignee field.
---@param name string
---@param identifier_hl string|nil Highlight group for the "(XX)" circle; defaults to a dynamic per-name color.
---@return string line
---@return AtlasUIHighlight[] highlights Spans with `line = 0`.
function M.render(name, identifier_hl)
	local initials = M.initials(name)
	local hl = identifier_hl or require("atlas.ui.shared.highlights").dynamic_for(name) or "AtlasTextMuted"
	local badge = string.format("(%s)", initials)
	local line = string.format("%s %s", badge, name)
	return line, {
		{ line = 0, start_col = 0, end_col = #badge, hl_group = hl },
		{ line = 0, start_col = #badge + 1, end_col = #line, hl_group = "AtlasTextBright" },
	}
end

--- Renders just the initials as a background-colored chip, e.g. " MS " in
--- the person's own stable color (timeline comment headers, composers).
---@param name string|nil
---@return string text
---@return string hl_group
function M.chip(name)
	local hl = require("atlas.ui.shared.highlights").dynamic_for_bg(name) or "AtlasChipActive"
	return " " .. M.initials(name) .. " ", hl
end

return M
