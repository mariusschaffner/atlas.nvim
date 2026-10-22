-- The issue detail view's header (DESIGN-detail-view.md §3): a dim meta line
-- (breadcrumb left, author/updated right), a title line (tinted state pill +
-- bold title + dim #iid), and a chip row (label chips, milestone, checklist
-- progress). Rendered either as plain lines (the milestone view, which appends
-- its own timeline strip below) or, with `opts.boxed`, inside a rounded box
-- whose top border carries the meta line.
local M = {}

local utils = require("atlas.ui.shared.utils")
local ui_utils = require("atlas.ui.utils")

-- Left-indents every header line to line up with where the content box's own
-- title text starts: 1 column for the float's own offset from the spacer's
-- edge, 1 for its rounded-border corner glyph, and 2 for the title's leading
-- "- " (see `tabs.title_chunks`) -- so e.g. "Description" and the header's
-- breadcrumb/title/chips all start in the same screen column.
local LEFT_PAD = 4
local LEFT_PAD_STR = string.rep(" ", LEFT_PAD)
-- Exported so other callers appending their own lines below this header's
-- (e.g. the milestone detail view's timeline strip) can left-align to the
-- same column.
M.LEFT_PAD = LEFT_PAD

-- Boxed layout, by screen column: the box's left border sits at column 1
-- (same as the content float's), its right border on the window's last
-- column, and content keeps the same 2-column gap from each border -- so it
-- still starts at `LEFT_PAD`.
local BOX_LEFT = " │  "
local BOX_RIGHT = "  │"
local BOX_LEFT_COLS = 4
local BOX_RIGHT_COLS = 3

---@class IssuesDetailHeaderData
---@field breadcrumb string e.g. "atlas / semesterarbeit > issues > #17".
---@field meta_right string e.g. "opened by M. Schaffner - 2h ago".
---@field state_label string "Open" | "Closed" (the pill's text).
---@field state_hl string Tinted-pill highlight group.
---@field title string
---@field iid_text string e.g. "#17".
---@field chips { label: string, hl: string|nil }[]|nil Label chips (tinted background).
---@field milestone_text string|nil
---@field progress_bar string|nil Pre-rendered segment bar text (see `ui.components.progress_bar`).
---@field progress_bar_spans table[]|nil Spans {start_col, end_col, hl_group} relative to `progress_bar`.
---@field progress_text string|nil e.g. "4/6 criteria".
---@field meta_strip string|nil Dim one-line summary under the chip row (narrow-terminal sidebar fallback).

--- Title line, blank, chip row (and the optional meta strip), unpadded.
---@param data IssuesDetailHeaderData
---@param width integer
---@return string[] lines
---@return AtlasUIHighlight[] highlights
---@return integer title_line_no
---@return integer title_col Display column where the title text starts.
local function render_body(data, width)
	local lines, spans = {}, {}

	-- Title line: state pill + title + dim #iid.
	local pill = string.format(" %s %s ", "●", data.state_label or "")
	local title_prefix = pill .. " "
	local iid_text = data.iid_text or ""
	local iid_suffix = iid_text ~= "" and (" " .. iid_text) or ""
	local title_text = data.title or ""
	local title_room = width - ui_utils.text_width(title_prefix) - ui_utils.text_width(iid_suffix)
	if title_room > 0 and ui_utils.text_width(title_text) > title_room then
		title_text = utils.truncate(title_text, title_room)
	end
	local title_line = title_prefix .. title_text .. iid_suffix
	table.insert(lines, title_line)
	table.insert(spans, { line = 0, start_col = 0, end_col = #pill, hl_group = data.state_hl })
	table.insert(spans, {
		line = 0,
		start_col = #title_prefix,
		end_col = #title_prefix + #title_text,
		hl_group = "AtlasTextBright",
	})
	if iid_text ~= "" then
		table.insert(spans, { line = 0, start_col = #title_line - #iid_text, end_col = #title_line, hl_group = "AtlasTextMuted" })
	end
	table.insert(lines, "")

	-- Chip row: label chips, then milestone + progress appended to the last
	-- chip line (or a fresh one if there are no labels).
	local chip_lines, chip_spans = {}, {}
	if data.chips and #data.chips > 0 then
		chip_lines, chip_spans = utils.render_chips(data.chips, { width = width, padding_x = 0, rounded = true })
	end
	if #chip_lines == 0 then
		chip_lines = { "" }
	end

	local trailer, trailer_spans = "", {}
	if data.milestone_text and data.milestone_text ~= "" then
		local seg = "◆ " .. data.milestone_text
		table.insert(trailer_spans, { start_col = 0, end_col = #seg, hl_group = "AtlasCyan" })
		trailer = seg
	end
	if data.progress_bar then
		if trailer ~= "" then
			local sep = "  │  "
			table.insert(trailer_spans, { start_col = #trailer, end_col = #trailer + #sep, hl_group = "AtlasBorder" })
			trailer = trailer .. sep
		end
		for _, s in ipairs(data.progress_bar_spans or {}) do
			table.insert(
				trailer_spans,
				{ start_col = #trailer + s.start_col, end_col = #trailer + s.end_col, hl_group = s.hl_group }
			)
		end
		trailer = trailer .. data.progress_bar
		if data.progress_text and data.progress_text ~= "" then
			local txt = " " .. data.progress_text
			table.insert(trailer_spans, { start_col = #trailer, end_col = #trailer + #txt, hl_group = "AtlasTextMuted" })
			trailer = trailer .. txt
		end
	end

	if trailer ~= "" then
		local last_idx = #chip_lines
		local base = chip_lines[last_idx]
		local sep2 = (base ~= "") and "  " or ""
		local offset = #base + #sep2
		chip_lines[last_idx] = base .. sep2 .. trailer
		for _, s in ipairs(trailer_spans) do
			table.insert(
				chip_spans,
				{ line = last_idx - 1, start_col = offset + s.start_col, end_col = offset + s.end_col, hl_group = s.hl_group }
			)
		end
	end

	utils.append_block(lines, spans, { lines = chip_lines, highlights = chip_spans })

	if data.meta_strip and data.meta_strip ~= "" then
		table.insert(lines, data.meta_strip)
		table.insert(spans, { line = #lines - 1, start_col = 0, end_col = #data.meta_strip, hl_group = "AtlasTextMuted" })
	end

	return lines, spans, 0, ui_utils.text_width(title_prefix)
end

--- Highlights the trailing "#iid" of a breadcrumb like the key hints, the
--- rest of it dim.
---@param spans AtlasUIHighlight[]
---@param line integer
---@param col integer Byte column where the breadcrumb starts.
---@param breadcrumb string
local function breadcrumb_spans(spans, line, col, breadcrumb)
	local iid = breadcrumb:match("#%d+$") or ""
	local head = #breadcrumb - #iid
	table.insert(spans, { line = line, start_col = col, end_col = col + head, hl_group = "AtlasTextMuted" })
	if iid ~= "" then
		table.insert(spans, { line = line, start_col = col + head, end_col = col + #breadcrumb, hl_group = "AtlasKeyHint" })
	end
end

---@param data IssuesDetailHeaderData
---@param outer_width integer
---@return string[] lines
---@return AtlasUIHighlight[] highlights
---@return table<string, AtlasFieldBoxRegion> regions
local function render_plain(data, outer_width)
	local width = math.max(1, outer_width - LEFT_PAD)
	local lines, spans = {}, {}

	local meta_left = data.breadcrumb or ""
	local meta_right = data.meta_right or ""
	local meta_gap = math.max(1, width - ui_utils.text_width(meta_left) - ui_utils.text_width(meta_right))
	local meta_line = meta_left .. string.rep(" ", meta_gap) .. meta_right
	table.insert(lines, meta_line)
	table.insert(spans, { line = 0, start_col = 0, end_col = #meta_left, hl_group = "AtlasTextMuted" })
	table.insert(
		spans,
		{ line = 0, start_col = #meta_line - #meta_right, end_col = #meta_line, hl_group = "AtlasTextMuted" }
	)
	table.insert(lines, "")

	local base = #lines
	local body_lines, body_spans, title_line, title_col = render_body(data, width)
	utils.append_block(lines, spans, { lines = body_lines, highlights = body_spans })

	for i, line in ipairs(lines) do
		lines[i] = line ~= "" and (LEFT_PAD_STR .. line) or line
	end
	for _, span in ipairs(spans) do
		if span.line_hl_group == nil then
			span.start_col = span.start_col + LEFT_PAD
			span.end_col = span.end_col + LEFT_PAD
		end
	end

	local regions = {
		title = {
			row = base + title_line,
			col = LEFT_PAD + title_col,
			width = math.max(1, width - title_col),
			height = 1,
		},
	}
	return lines, spans, regions
end

---@param data IssuesDetailHeaderData
---@param outer_width integer
---@return string[] lines
---@return AtlasUIHighlight[] highlights
---@return table<string, AtlasFieldBoxRegion> regions
local function render_boxed(data, outer_width)
	local width = math.max(1, outer_width - BOX_LEFT_COLS - BOX_RIGHT_COLS)
	local lines, spans = {}, {}

	-- Top border: " ╭─ breadcrumb ───── meta_right ─╮", same total width as
	-- the content lines below.
	local meta_left = data.breadcrumb or ""
	local meta_right = data.meta_right or ""
	local head = " ╭─ "
	local tail = " ─╮"
	-- Room for both texts after the corners, the 2 spaces around the fill, and
	-- at least 1 fill dash. Too narrow: shorten the breadcrumb from its start
	-- (keeping the "› #iid" end) down to MIN_BREADCRUMB, then the meta text.
	local MIN_BREADCRUMB = 20
	local room = math.max(0, outer_width - ui_utils.text_width(head) - ui_utils.text_width(tail) - 3)
	local over = ui_utils.text_width(meta_left) + ui_utils.text_width(meta_right) - room
	if over > 0 then
		local left_w = math.max(math.min(MIN_BREADCRUMB, ui_utils.text_width(meta_left)), ui_utils.text_width(meta_left) - over)
		meta_left = utils.truncate(meta_left, left_w, true)
		meta_right = utils.truncate(meta_right, math.max(0, room - ui_utils.text_width(meta_left)))
	end
	local fill = math.max(
		1,
		outer_width
			- ui_utils.text_width(head)
			- ui_utils.text_width(meta_left)
			- ui_utils.text_width(meta_right)
			- ui_utils.text_width(tail)
			- 2
	)
	local left_part = head .. meta_left .. " "
	local fill_str = string.rep("─", fill)
	local top = left_part .. fill_str .. " " .. meta_right .. tail
	table.insert(lines, top)
	table.insert(spans, { line = 0, start_col = 0, end_col = #head, hl_group = "AtlasBorder" })
	breadcrumb_spans(spans, 0, #head, meta_left)
	local fill_start = #left_part
	table.insert(spans, { line = 0, start_col = fill_start, end_col = fill_start + #fill_str, hl_group = "AtlasBorder" })
	table.insert(spans, { line = 0, start_col = #top - #tail - #meta_right, end_col = #top - #tail, hl_group = "AtlasTextMuted" })
	table.insert(spans, { line = 0, start_col = #top - #tail, end_col = #top, hl_group = "AtlasBorder" })

	local body_lines, body_spans, title_line, title_col = render_body(data, width)
	local inner = { "" }
	local inner_spans = {}
	utils.append_block(inner, inner_spans, { lines = body_lines, highlights = body_spans })
	table.insert(inner, "")
	local title_row = #lines + 1 + title_line

	for _, line in ipairs(inner) do
		local pad = math.max(0, width - ui_utils.text_width(line))
		local row = #lines
		local text = BOX_LEFT .. line .. string.rep(" ", pad) .. BOX_RIGHT
		table.insert(lines, text)
		table.insert(spans, { line = row, start_col = 0, end_col = #BOX_LEFT, hl_group = "AtlasBorder" })
		table.insert(spans, { line = row, start_col = #text - #BOX_RIGHT, end_col = #text, hl_group = "AtlasBorder" })
	end
	for _, span in ipairs(inner_spans) do
		if span.line_hl_group == nil then
			table.insert(spans, {
				line = span.line + 1,
				start_col = span.start_col + #BOX_LEFT,
				end_col = span.end_col + #BOX_LEFT,
				hl_group = span.hl_group,
			})
		end
	end

	local bottom = " ╰" .. string.rep("─", math.max(1, outer_width - 3)) .. "╯"
	table.insert(lines, bottom)
	table.insert(spans, { line = #lines - 1, start_col = 0, end_col = #bottom, hl_group = "AtlasBorder" })

	local regions = {
		title = {
			row = title_row,
			col = BOX_LEFT_COLS + title_col,
			width = math.max(1, width - title_col),
			height = 1,
		},
	}
	return lines, spans, regions
end

---@param data IssuesDetailHeaderData
---@param outer_width integer
---@param opts { boxed: boolean|nil }|nil
---@return string[] lines
---@return AtlasUIHighlight[] highlights
---@return table<string, AtlasFieldBoxRegion> regions Only `title`, for anchoring its inline-edit overlay.
function M.render(data, outer_width, opts)
	if opts and opts.boxed then
		return render_boxed(data, outer_width)
	end
	return render_plain(data, outer_width)
end

return M
