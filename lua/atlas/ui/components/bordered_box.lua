-- Generic box-drawn border component (┌─ Title ─┐ / │ content │ / └───┘),
-- rendered as literal buffer text. Pure/domain-unaware, like navbar.lua —
-- callers own all domain-specific content so this stays reusable for any
-- future bordered content block (e.g. an issue/PR fields box).
local M = {}

local ui_utils = require("atlas.ui.utils")
local shared_utils = require("atlas.ui.shared.utils")

local text_width = ui_utils.text_width
local pad_right = ui_utils.pad_right
local truncate = shared_utils.truncate

local TL, TR, BL, BR, H, V = "┌", "┐", "└", "┘", "─", "│"

---@param interior_width integer
---@param title string|nil
---@return string
local function build_top(interior_width, title)
	if title == nil or title == "" then
		return TL .. string.rep(H, math.max(0, interior_width)) .. TR
	end

	local label = string.format(" %s ", title)
	local label_w = text_width(label)
	local remaining = math.max(0, interior_width - 1 - label_w)
	return TL .. H .. label .. string.rep(H, remaining) .. TR
end

---@param interior_width integer
---@return string
local function build_bottom(interior_width)
	return BL .. string.rep(H, math.max(0, interior_width)) .. BR
end

---@param opts {
---  width: integer,
---  title: string|nil,
---  content_lines: string[],
---  content_highlights: table[]|nil,
---  box_width_ratio: number|nil,
---  min_box_width: integer|nil,
---  border_hl: string|nil,
---  content_background_hl: string|nil,
---  right_content: { lines: string[], highlights: table[]|nil }|nil,
---  right_content_row: integer|nil,
--- }
---@return string[] lines
---@return table[] highlights
function M.render(opts)
	opts = opts or {}
	local total_width = math.max(1, opts.width or vim.o.columns)
	local ratio = opts.box_width_ratio or 0.9
	local min_box_width = opts.min_box_width or 20
	local border_hl = opts.border_hl or "AtlasBorder"
	local content_lines = opts.content_lines or { "" }

	local box_width = math.max(min_box_width, math.floor(total_width * ratio))
	box_width = math.min(box_width, total_width)
	box_width = math.max(box_width, 3) -- always room for the two border columns
	local interior_width = box_width - 2
	local right_width = math.max(0, total_width - box_width - 1) -- -1 for the gap space

	local lines = {}
	local highlights = {}

	local top = build_top(interior_width, opts.title)
	table.insert(lines, top)
	table.insert(highlights, { line = 0, start_col = 0, end_col = #top, hl_group = border_hl })

	local right_content_row = opts.right_content_row or math.ceil(#content_lines / 2)

	for i, content in ipairs(content_lines) do
		local body = pad_right(truncate(content or "", interior_width), interior_width)
		local row_line = V .. body .. V
		local line_idx = #lines

		table.insert(lines, row_line)
		table.insert(highlights, { line = line_idx, start_col = 0, end_col = #V, hl_group = border_hl })
		table.insert(highlights, {
			line = line_idx,
			start_col = #V + #body,
			end_col = #V + #body + #V,
			hl_group = border_hl,
		})

		if opts.content_background_hl then
			table.insert(highlights, { line = line_idx, line_hl_group = opts.content_background_hl })
		end

		for _, span in ipairs((opts.content_highlights or {})) do
			if span.line == i - 1 then
				table.insert(highlights, {
					line = line_idx,
					start_col = #V + span.start_col,
					end_col = #V + span.end_col,
					hl_group = span.hl_group,
				})
			end
		end

		if opts.right_content and right_width > 0 and i == right_content_row then
			local raw_right_line = opts.right_content.lines and opts.right_content.lines[1] or ""
			local right_line = truncate(raw_right_line, right_width)
			if right_line ~= "" then
				local gap = " "
				local prefix_len = #row_line + #gap
				local right_len = #right_line
				lines[#lines] = row_line .. gap .. right_line
				for _, span in ipairs(opts.right_content.highlights or {}) do
					local sc = math.min(span.start_col, right_len)
					local ec = math.min(span.end_col, right_len)
					if ec > sc then
						table.insert(highlights, {
							line = line_idx,
							start_col = prefix_len + sc,
							end_col = prefix_len + ec,
							hl_group = span.hl_group,
						})
					end
				end
			end
		end
	end

	local bottom = build_bottom(interior_width)
	table.insert(lines, bottom)
	table.insert(highlights, { line = #lines - 1, start_col = 0, end_col = #bottom, hl_group = border_hl })

	return lines, highlights
end

return M
