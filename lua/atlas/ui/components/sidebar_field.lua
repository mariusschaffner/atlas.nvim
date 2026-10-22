-- Renders a single metadata field for a detail-view sidebar
-- (DESIGN-detail-view.md §4): a dim label line with an optional right-aligned
-- key hint, followed by either the field's value lines or a dim empty-state
-- line. No border, no box -- just two building blocks stacked, unlike
-- `field_box.lua`'s bordered fields. Pure render function: takes plain data,
-- returns lines + highlight spans, no window/buffer/state of its own.
local M = {}

local ui_utils = require("atlas.ui.utils")

---@class AtlasSidebarField
---@field label string Field label, e.g. "Assignee" (rendered upper-cased).
---@field key_hint string|nil Display text for the field's key(s), e.g. "ga".
---@field value_lines string[]|nil Pre-rendered value line(s); ignored when `empty` is true.
---@field value_highlights AtlasUIHighlight[]|nil Spans relative to `value_lines` (0-indexed `line`).
---@field empty boolean|nil When true, renders `empty_text` instead of `value_lines`.
---@field empty_text string|nil Empty-state text, e.g. "+ assign" or "not scheduled".
---@field label_hl string|nil Label highlight group override, default "AtlasTextMuted" (e.g. "AtlasFieldBoxBorderEditing" while the field is actively being edited).
---@field label_line string|nil Pre-rendered label line, bypassing the usual "LABEL ... hint" layout (e.g. the split Start/Due line). Used together with `label_spans`.
---@field label_spans AtlasUIHighlight[]|nil Spans for `label_line` (0-indexed `line`, always 0 here).

---@param field AtlasSidebarField
---@param width integer
---@return string[] lines
---@return AtlasUIHighlight[] highlights
function M.render(field, width)
	width = math.max(1, width)
	local lines, spans = {}, {}

	if field.label_line ~= nil then
		table.insert(lines, field.label_line)
		for _, span in ipairs(field.label_spans or {}) do
			table.insert(spans, { line = 0, start_col = span.start_col, end_col = span.end_col, hl_group = span.hl_group })
		end
	else
		local label = string.upper(field.label or "")
		local hint = field.key_hint
		local label_line
		if hint and hint ~= "" then
			local gap = math.max(1, width - ui_utils.text_width(label) - ui_utils.text_width(hint))
			label_line = label .. string.rep(" ", gap) .. hint
		else
			label_line = label
		end
		table.insert(lines, label_line)
		table.insert(spans, { line = 0, start_col = 0, end_col = #label, hl_group = field.label_hl or "AtlasTextMuted" })
		if hint and hint ~= "" then
			table.insert(spans, { line = 0, start_col = #label_line - #hint, end_col = #label_line, hl_group = "AtlasKeyHint" })
		end
	end

	if field.empty then
		local text = field.empty_text or ""
		table.insert(lines, text)
		table.insert(spans, { line = #lines - 1, start_col = 0, end_col = #text, hl_group = "AtlasTextMutedItalic" })
		return lines, spans
	end

	local base = #lines
	for _, line in ipairs(field.value_lines or {}) do
		table.insert(lines, line)
	end
	for _, span in ipairs(field.value_highlights or {}) do
		if span.line_hl_group ~= nil then
			table.insert(spans, { line = base + span.line, line_hl_group = span.line_hl_group })
		else
			table.insert(spans, {
				line = base + span.line,
				start_col = span.start_col,
				end_col = span.end_col,
				hl_group = span.hl_group,
			})
		end
	end

	return lines, spans
end

return M
