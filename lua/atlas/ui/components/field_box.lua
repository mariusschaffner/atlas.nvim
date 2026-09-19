-- Renders GitLab detail fields (Assignee, Reviewer, Labels, ...) as bordered
-- boxes with the same styling as the main filter bar, two per row. Each box
-- is sized to its own content (title/value), capped at a max width so a
-- long value can't stretch the layout or push its row-mate off-screen.
-- Editable fields get a distinct border color so they're noticeable at a
-- glance.
local M = {}

local bordered_box = require("atlas.ui.components.bordered_box")
local shared_utils = require("atlas.ui.shared.utils")
local ui_utils = require("atlas.ui.utils")

local DEFAULT_MAX_FIELD_WIDTH = 40
local MIN_FIELD_WIDTH = 12
local GAP = 2

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

---@param field AtlasFieldBoxField
---@return integer
local function natural_width(field)
	-- bordered_box's top border needs interior_width >= label_w + 1 (where
	-- label_w = title_w + 2, for " Title ") to close the border without
	-- overflowing box_width by a column; box_width = interior_width + 2.
	local title_w = ui_utils.text_width(field.label) + 5
	local value_w = ui_utils.text_width(field.value or "") + 2 -- "│" + "│"
	return math.max(title_w, value_w)
end

---@param field AtlasFieldBoxField
---@param cap integer
---@return integer
local function box_width_for(field, cap)
	return math.max(MIN_FIELD_WIDTH, math.min(cap, natural_width(field)))
end

---@param field AtlasFieldBoxField
---@param box_width integer
---@return string[] lines
---@return table[] highlights
local function render_one(field, box_width)
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

	return bordered_box.render({
		width = box_width,
		box_width = box_width,
		title = field.label,
		content_lines = { value },
		content_highlights = content_highlights,
		border_hl = field.editable and "AtlasFieldBoxBorderEditable" or "AtlasFieldBoxBorder",
	})
end

---@param left_lines string[]
---@param left_spans table[]
---@param right_lines string[]
---@param right_spans table[]
---@return string[] lines
---@return table[] highlights
local function merge_rows(left_lines, left_spans, right_lines, right_spans)
	local gap = string.rep(" ", GAP)
	local lines = {}
	for i = 1, #left_lines do
		lines[i] = left_lines[i] .. gap .. (right_lines[i] or "")
	end

	local spans = {}
	for _, span in ipairs(left_spans) do
		table.insert(spans, span)
	end
	for _, span in ipairs(right_spans) do
		if span.line_hl_group ~= nil then
			table.insert(spans, span)
		else
			local prefix_len = #(left_lines[span.line + 1] or "") + #gap
			table.insert(spans, {
				line = span.line,
				start_col = prefix_len + span.start_col,
				end_col = prefix_len + span.end_col,
				hl_group = span.hl_group,
			})
		end
	end

	return lines, spans
end

---@param fields AtlasFieldBoxField[]
---@param opts { width: integer, max_field_width: integer|nil }
---@return string[] lines
---@return table[] highlights
function M.render(fields, opts)
	local width = math.max(1, opts.width)
	local max_field_width = opts.max_field_width or DEFAULT_MAX_FIELD_WIDTH
	local half_cap = math.max(MIN_FIELD_WIDTH, math.floor((width - GAP) / 2))
	local cap = math.min(max_field_width, half_cap)

	local lines, spans = {}, {}
	local i = 1
	while i <= #fields do
		local left = fields[i]
		local right = fields[i + 1]
		local left_lines, left_spans = render_one(left, box_width_for(left, cap))

		if right then
			local right_lines, right_spans = render_one(right, box_width_for(right, cap))
			local merged_lines, merged_spans = merge_rows(left_lines, left_spans, right_lines, right_spans)
			shared_utils.append_block(lines, spans, { lines = merged_lines, highlights = merged_spans })
		else
			shared_utils.append_block(lines, spans, { lines = left_lines, highlights = left_spans })
		end

		i = i + 2
	end

	return lines, spans
end

return M
