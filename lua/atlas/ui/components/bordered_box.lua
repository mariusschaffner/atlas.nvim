-- Generic box-drawn border component (╭─ Title ─╮ / │ content │ / ╰───╯),
-- rendered as literal buffer text. Pure/domain-unaware, like navbar.lua —
-- callers own all domain-specific content so this stays reusable for any
-- future bordered content block (e.g. an issue/PR fields box).
local M = {}

local ui_utils = require("atlas.ui.utils")
local shared_utils = require("atlas.ui.shared.utils")

local text_width = ui_utils.text_width
local pad_right = ui_utils.pad_right
local truncate = shared_utils.truncate

local TL, TR, BL, BR, H, V = "╭", "╮", "╰", "╯", "─", "│"

---@param interior_width integer
---@param title string|nil
---@param title_highlights table[]|nil Spans {start_col, end_col, hl_group} relative to `title` itself.
---@param title_right string|nil Right-aligned segment near the top-right corner (e.g. a notification/help hint).
---@param title_right_highlights table[]|nil Spans {start_col, end_col, hl_group} relative to `title_right` itself.
---@return string top
---@return table[] highlights Spans {start_col, end_col, hl_group} relative to the returned `top` line.
local function build_top(interior_width, title, title_highlights, title_right, title_right_highlights)
	local has_title = title ~= nil and title ~= ""
	local has_right = title_right ~= nil and title_right ~= ""

	if not has_title and not has_right then
		return TL .. string.rep(H, math.max(0, interior_width)) .. TR, {}
	end

	local left_part = has_title and (H .. string.format(" %s ", title)) or H
	local left_w = text_width(left_part)

	local right_part = has_right and (string.format(" %s ", title_right) .. H) or ""
	local right_w = text_width(right_part)

	local fill = math.max(0, interior_width - left_w - right_w)
	local fill_str = string.rep(H, fill)
	local top = TL .. left_part .. fill_str .. right_part .. TR

	local highlights = {}
	if has_title then
		local title_offset = #TL + #H + 1 -- corner + dash + leading space
		local title_len = #title
		for _, span in ipairs(title_highlights or {}) do
			local sc = math.min(span.start_col, title_len)
			local ec = math.min(span.end_col, title_len)
			if ec > sc then
				table.insert(highlights, { start_col = title_offset + sc, end_col = title_offset + ec, hl_group = span.hl_group })
			end
		end
	end
	if has_right then
		local right_offset = #TL + #left_part + #fill_str + 1 -- everything before title_right's own text, +1 for its leading space
		local right_len = #title_right
		for _, span in ipairs(title_right_highlights or {}) do
			local sc = math.min(span.start_col, right_len)
			local ec = math.min(span.end_col, right_len)
			if ec > sc then
				table.insert(highlights, { start_col = right_offset + sc, end_col = right_offset + ec, hl_group = span.hl_group })
			end
		end
	end

	return top, highlights
end

---@param interior_width integer
---@param hint string|nil Left-aligned segment near the bottom-left corner (e.g. action hints).
---@param hint_highlights table[]|nil Spans {start_col, end_col, hl_group} relative to `hint` itself.
---@return string bottom
---@return table[] highlights Spans {start_col, end_col, hl_group} relative to the returned `bottom` line.
local function build_bottom(interior_width, hint, hint_highlights)
	if hint == nil or hint == "" then
		return BL .. string.rep(H, math.max(0, interior_width)) .. BR, {}
	end

	local label = string.format(" %s ", hint)
	local label_w = text_width(label)
	local remaining = math.max(0, interior_width - 1 - label_w)
	local bottom = BL .. H .. label .. string.rep(H, remaining) .. BR

	local hint_offset = #BL + #H + 1 -- corner + dash + leading space
	local hint_len = #hint
	local highlights = {}
	for _, span in ipairs(hint_highlights or {}) do
		local sc = math.min(span.start_col, hint_len)
		local ec = math.min(span.end_col, hint_len)
		if ec > sc then
			table.insert(highlights, { start_col = hint_offset + sc, end_col = hint_offset + ec, hl_group = span.hl_group })
		end
	end

	return bottom, highlights
end

---@param opts {
---  width: integer,
---  title: string|nil,
---  title_highlights: table[]|nil Spans {start_col, end_col, hl_group} relative to `title` itself.
---  title_right: string|nil Right-aligned segment near the top-right corner (e.g. a notification/help hint).
---  title_right_highlights: table[]|nil Spans {start_col, end_col, hl_group} relative to `title_right` itself.
---  content_lines: string[],
---  content_highlights: table[]|nil,
---  box_width: integer|nil Exact box width, bypassing the ratio-based sizing below.
---  box_width_ratio: number|nil,
---  min_box_width: integer|nil,
---  border_hl: string|nil,
---  content_background_hl: string|nil,
---  right_content: { lines: string[], highlights: table[]|nil }|nil,
---  right_content_row: integer|nil,
---  bottom_hint: string|nil Left-aligned segment near the bottom-left corner (e.g. action hints).
---  bottom_hint_highlights: table[]|nil Spans {start_col, end_col, hl_group} relative to `bottom_hint` itself.
--- }
---@return string[] lines
---@return table[] highlights
function M.render(opts)
	opts = opts or {}
	local total_width = math.max(1, opts.width or vim.o.columns)
	local border_hl = opts.border_hl or "AtlasBorder"
	local content_lines = opts.content_lines or { "" }

	local box_width
	if opts.box_width then
		box_width = math.min(opts.box_width, total_width)
	else
		local ratio = opts.box_width_ratio or 0.9
		local min_box_width = opts.min_box_width or 20
		box_width = math.max(min_box_width, math.floor(total_width * ratio))
		box_width = math.min(box_width, total_width)
	end
	box_width = math.max(box_width, 3) -- always room for the two border columns
	local interior_width = box_width - 2
	local right_width = math.max(0, total_width - box_width - 1) -- -1 for the gap space

	local lines = {}
	local highlights = {}

	local top, top_title_highlights =
		build_top(interior_width, opts.title, opts.title_highlights, opts.title_right, opts.title_right_highlights)
	table.insert(lines, top)
	table.insert(highlights, { line = 0, start_col = 0, end_col = #top, hl_group = border_hl })
	for _, span in ipairs(top_title_highlights) do
		table.insert(highlights, { line = 0, start_col = span.start_col, end_col = span.end_col, hl_group = span.hl_group })
	end

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

		local body_len = #body
		for _, span in ipairs((opts.content_highlights or {})) do
			if span.line == i - 1 then
				local sc = math.min(span.start_col, body_len)
				local ec = math.min(span.end_col, body_len)
				if ec > sc then
					table.insert(highlights, {
						line = line_idx,
						start_col = #V + sc,
						end_col = #V + ec,
						hl_group = span.hl_group,
					})
				end
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

	local bottom, bottom_hint_highlights = build_bottom(interior_width, opts.bottom_hint, opts.bottom_hint_highlights)
	local bottom_line_idx = #lines
	table.insert(lines, bottom)
	table.insert(highlights, { line = bottom_line_idx, start_col = 0, end_col = #bottom, hl_group = border_hl })
	for _, span in ipairs(bottom_hint_highlights) do
		table.insert(
			highlights,
			{ line = bottom_line_idx, start_col = span.start_col, end_col = span.end_col, hl_group = span.hl_group }
		)
	end

	return lines, highlights
end

return M
