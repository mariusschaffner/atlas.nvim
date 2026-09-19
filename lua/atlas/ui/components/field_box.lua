-- Renders a stack of single-field bordered boxes (┌─ Label ─┐ / │ value │ /
-- └───┘), one per field, no gap between boxes. Used by the issue/pull/
-- milestone detail headers to show GitLab fields (Assignee, Reviewer,
-- Labels, ...) with the same styling as the main filter bar. Editable
-- fields get a distinct border color so they're noticeable at a glance.
local M = {}

local bordered_box = require("atlas.ui.components.bordered_box")
local shared_utils = require("atlas.ui.shared.utils")

---@class AtlasFieldBoxField
---@field label string
---@field value string
---@field hl string|table[]|nil
---@field editable boolean|nil

---@param text string
---@param hl string|table[]|nil
---@return table[]
local function value_hl_spans(text, hl)
	if type(hl) == "table" then
		return hl
	end
	if type(hl) == "string" and hl ~= "" then
		return { { start_col = 0, end_col = #text, hl_group = hl } }
	end
	return {}
end

---@param fields AtlasFieldBoxField[]
---@param opts { width: integer }
---@return string[] lines
---@return table[] highlights
function M.render(fields, opts)
	local width = opts.width
	local lines, spans = {}, {}

	for _, field in ipairs(fields) do
		local value = field.value or ""
		local content_highlights = {}
		for _, span in ipairs(value_hl_spans(value, field.hl)) do
			table.insert(content_highlights, {
				line = 0,
				start_col = span.start_col,
				end_col = span.end_col,
				hl_group = span.hl_group,
			})
		end

		local box_lines, box_spans = bordered_box.render({
			width = width,
			title = field.label,
			content_lines = { value },
			content_highlights = content_highlights,
			border_hl = field.editable and "AtlasFieldBoxBorderEditable" or "AtlasFieldBoxBorder",
		})
		shared_utils.append_block(lines, spans, { lines = box_lines, highlights = box_spans })
	end

	return lines, spans
end

return M
