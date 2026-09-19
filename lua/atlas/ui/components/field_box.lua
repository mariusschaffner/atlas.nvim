-- Renders GitLab detail fields (Assignee, Reviewer, Labels, ...) as bordered
-- boxes with the same styling as the main filter bar. Each box is sized to
-- its own content (title/value), capped at a max width so a long value
-- can't stretch the layout or push its row-mate off-screen. Editable fields
-- get a distinct border color so they're noticeable at a glance; a field
-- can also set an explicit `border_hl` (e.g. to reflect open/closed status
-- on a title box) which takes precedence over the editable convention. A
-- field with `kind = "toggle"` renders as a compact checkbox line instead
-- of a bordered box, for on/off settings that don't need their own frame.
-- `kind = "text"` renders as a plain, unboxed value line (no label shown),
-- for read-only info that doesn't need its own frame either.
local M = {}

local bordered_box = require("atlas.ui.components.bordered_box")
local shared_utils = require("atlas.ui.shared.utils")
local ui_utils = require("atlas.ui.utils")

local DEFAULT_MAX_FIELD_WIDTH = 40
local MIN_FIELD_WIDTH = 12
local GAP = 2
local DEFAULT_COLUMN_GAP = 4

---@class AtlasFieldBoxField
---@field label string
---@field value string
---@field hl string|table[]|nil
---@field editable boolean|nil
---@field border_hl string|nil Explicit border color override, takes precedence over `editable`.
---@field kind "toggle"|"text"|nil
---@field enabled boolean|nil Toggle state, only used when kind == "toggle".
---@field right_content { lines: string[], highlights: table[]|nil }|nil Only meaningful on a full-width `top_field`.

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
	if field.kind == "toggle" then
		return math.max(MIN_FIELD_WIDTH, math.min(cap, ui_utils.text_width(field.label) + 2))
	end
	if field.kind == "text" then
		return math.max(MIN_FIELD_WIDTH, math.min(cap, ui_utils.text_width(field.value or "")))
	end
	return math.max(MIN_FIELD_WIDTH, math.min(cap, natural_width(field)))
end

---@param field AtlasFieldBoxField
---@param box_width integer
---@return string[] lines
---@return table[] highlights
local function render_toggle(field, box_width)
	local checked = field.enabled == true
	local mark = checked and "◉" or "○"
	local text = string.format("%s %s", mark, field.label)
	local hl = checked and "AtlasTextPositive" or "AtlasTextMuted"
	local line = ui_utils.pad_right(text, box_width)
	return { line }, { { line = 0, start_col = 0, end_col = #text, hl_group = hl } }
end

---@param field AtlasFieldBoxField
---@param box_width integer
---@return string[] lines
---@return table[] highlights
local function render_text(field, box_width)
	local value = field.value or ""
	local line = ui_utils.pad_right(value, box_width)
	local spans = {}
	for _, span in ipairs(value_hl_spans(value, field.hl)) do
		table.insert(spans, { line = 0, start_col = span.start_col, end_col = span.end_col, hl_group = span.hl_group })
	end
	return { line }, spans
end

---@param field AtlasFieldBoxField
---@param box_width integer
---@param total_width integer|nil Available width for right_content; defaults to box_width (no reserved space).
---@return string[] lines
---@return table[] highlights
local function render_one(field, box_width, total_width)
	if field.kind == "toggle" then
		return render_toggle(field, box_width)
	end
	if field.kind == "text" then
		return render_text(field, box_width)
	end

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
		width = total_width or box_width,
		box_width = box_width,
		title = field.label,
		content_lines = { value },
		content_highlights = content_highlights,
		right_content = field.right_content,
		border_hl = field.border_hl or (field.editable and "AtlasFieldBoxBorderEditable" or "AtlasFieldBoxBorder"),
	})
end

---@param left_lines string[]
---@param left_spans table[]
---@param right_lines string[]
---@param right_spans table[]
---@param gap_width integer|nil
---@return string[] lines
---@return table[] highlights
local function merge_rows(left_lines, left_spans, right_lines, right_spans, gap_width)
	local gap = string.rep(" ", gap_width or GAP)
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
---@param box_width integer
---@return string[] lines
---@return table[] highlights
local function stack(fields, box_width)
	local lines, spans = {}, {}
	for _, field in ipairs(fields) do
		local field_lines, field_spans = render_one(field, box_width)
		shared_utils.append_block(lines, spans, { lines = field_lines, highlights = field_spans })
	end
	return lines, spans
end

--- N independent, full-height column stacks (e.g. Author/Assignee on the
--- left, Labels/Milestone in the middle, Linked MR/Linked Branches on the
--- right) rather than row-major pairing — every box in a column shares that
--- column's width, so they align below each other regardless of what's in
--- the other columns. An optional `top_field` renders full-width above all
--- columns (e.g. a title box with no second column). Empty columns are
--- skipped entirely (no reserved space, no stray gap).
---@param columns AtlasFieldBoxField[][]
---@param opts { width: integer, max_field_width: integer|nil, column_gap: integer|nil, top_field: AtlasFieldBoxField|nil }
---@return string[] lines
---@return table[] highlights
function M.render_columns(columns, opts)
	local width = math.max(1, opts.width)
	local column_gap = opts.column_gap or DEFAULT_COLUMN_GAP
	local max_field_width = opts.max_field_width or DEFAULT_MAX_FIELD_WIDTH

	local lines, spans = {}, {}

	if opts.top_field then
		local reserve = 0
		if opts.top_field.right_content then
			local rc_text = opts.top_field.right_content.lines and opts.top_field.right_content.lines[1] or ""
			reserve = ui_utils.text_width(rc_text) + 2
		end
		local top_box_width = math.max(MIN_FIELD_WIDTH, width - reserve)
		local top_lines, top_spans = render_one(opts.top_field, top_box_width, width)
		shared_utils.append_block(lines, spans, { lines = top_lines, highlights = top_spans })
	end

	local nonempty = {}
	for _, col in ipairs(columns) do
		if #col > 0 then
			table.insert(nonempty, col)
		end
	end
	local n = #nonempty
	if n == 0 then
		return lines, spans
	end

	local total_gap = column_gap * (n - 1)
	local cap = math.min(max_field_width, math.max(MIN_FIELD_WIDTH, math.floor((width - total_gap) / n)))

	---@param fields AtlasFieldBoxField[]
	---@return integer
	local function column_width(fields)
		local w = MIN_FIELD_WIDTH
		for _, field in ipairs(fields) do
			w = math.max(w, box_width_for(field, cap))
		end
		return math.min(cap, w)
	end

	local col_widths, col_lines, col_spans, max_rows = {}, {}, {}, 0
	for i, col in ipairs(nonempty) do
		local w = column_width(col)
		col_widths[i] = w
		local l, s = stack(col, w)
		col_lines[i] = l
		col_spans[i] = s
		max_rows = math.max(max_rows, #l)
	end

	local gap = string.rep(" ", column_gap)
	local blanks = {}
	for i = 1, n do
		blanks[i] = string.rep(" ", col_widths[i])
	end

	local columns_lines = {}
	for row = 1, max_rows do
		local parts = {}
		for i = 1, n do
			table.insert(parts, col_lines[i][row] or blanks[i])
		end
		columns_lines[row] = table.concat(parts, gap)
	end

	local columns_spans = {}
	for i = 1, n do
		for _, span in ipairs(col_spans[i]) do
			if span.line_hl_group ~= nil then
				table.insert(columns_spans, span)
			else
				local prefix_len = 0
				for j = 1, i - 1 do
					prefix_len = prefix_len + #(col_lines[j][span.line + 1] or blanks[j]) + #gap
				end
				table.insert(columns_spans, {
					line = span.line,
					start_col = prefix_len + span.start_col,
					end_col = prefix_len + span.end_col,
					hl_group = span.hl_group,
				})
			end
		end
	end

	shared_utils.append_block(lines, spans, { lines = columns_lines, highlights = columns_spans })
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
