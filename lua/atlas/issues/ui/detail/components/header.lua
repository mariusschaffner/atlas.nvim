-- The issue/milestone detail views' header (DESIGN-detail-view.md §3): a
-- rounded box whose top border carries the meta line (breadcrumb left,
-- author/updated right), holding a title line (tinted state pill + bold title
-- + dim #iid), a chip row (label chips, milestone, checklist progress), and
-- optionally a caller-provided block below (the milestone view's timeline).
local M = {}

local utils = require("atlas.ui.shared.utils")

-- Not `ui_utils.text_width` (strdisplaywidth): that measures against the
-- current window, and with 'breakindent' on there a line with leading
-- whitespace that's wider than the window counts its repeated indent too --
-- which would nudge the box's right border out of place.
local text_width = vim.api.nvim_strwidth

-- By screen column: the box's left border sits at column 1 (same as the
-- content float's), its right border on the window's last column, and
-- content keeps a 2-column gap from each border -- so it starts at column 4,
-- right where the content box's own title text ("Description", ...) starts.
local BOX_LEFT = " │  "
local BOX_RIGHT = "  │"
local BOX_LEFT_COLS = 4
local BOX_RIGHT_COLS = 3
local MIN_BREADCRUMB = 20

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

---@class IssuesDetailHeaderBlock
---@field lines string[] Rendered at `M.inner_width`, unpadded.
---@field highlights AtlasUIHighlight[]
---@field regions table<string, AtlasFieldBoxRegion>|nil Display columns, relative to the block.

--- Width available for content inside the box.
---@param outer_width integer
---@return integer
function M.inner_width(outer_width)
	return math.max(1, outer_width - BOX_LEFT_COLS - BOX_RIGHT_COLS)
end

--- Title line, then (when there's anything to show) a blank and the chip row,
--- then the optional meta strip. Unpadded.
---@param data IssuesDetailHeaderData
---@param width integer
---@return string[] lines
---@return AtlasUIHighlight[] highlights
---@return integer title_col Display column where the title text starts (title is line 0).
local function render_body(data, width)
	local lines, spans = {}, {}

	local pill = string.format(" %s %s ", "●", data.state_label or "")
	local title_prefix = pill .. " "
	local iid_text = data.iid_text or ""
	local iid_suffix = iid_text ~= "" and (" " .. iid_text) or ""
	local title_text = data.title or ""
	local title_room = width - text_width(title_prefix) - text_width(iid_suffix)
	if title_room > 0 and text_width(title_text) > title_room then
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

	-- Chip row: label chips, then milestone + progress appended to the last
	-- chip line (or a fresh one if there are no labels).
	local chip_lines, chip_spans = {}, {}
	if data.chips and #data.chips > 0 then
		chip_lines, chip_spans = utils.render_chips(data.chips, { width = width, padding_x = 0, rounded = true })
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
		if #chip_lines == 0 then
			chip_lines = { "" }
		end
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

	if #chip_lines > 0 then
		table.insert(lines, "")
		utils.append_block(lines, spans, { lines = chip_lines, highlights = chip_spans })
	end

	if data.meta_strip and data.meta_strip ~= "" then
		table.insert(lines, data.meta_strip)
		table.insert(spans, { line = #lines - 1, start_col = 0, end_col = #data.meta_strip, hl_group = "AtlasTextMuted" })
	end

	return lines, spans, text_width(title_prefix)
end

--- Highlights the trailing "#iid"/"%id" of a breadcrumb like the key hints,
--- the rest of it dim.
---@param spans AtlasUIHighlight[]
---@param col integer Byte column where the breadcrumb starts on line 0.
---@param breadcrumb string
local function breadcrumb_spans(spans, col, breadcrumb)
	local id = breadcrumb:match("[#%%]%d+$") or ""
	local head = #breadcrumb - #id
	table.insert(spans, { line = 0, start_col = col, end_col = col + head, hl_group = "AtlasTextMuted" })
	if id ~= "" then
		table.insert(spans, { line = 0, start_col = col + head, end_col = col + #breadcrumb, hl_group = "AtlasKeyHint" })
	end
end

--- Top border: " ╭─ breadcrumb ───── meta_right ─╮", exactly `outer_width`
--- wide. Too narrow: shortens the breadcrumb from its start (keeping its
--- "› #iid" end) down to MIN_BREADCRUMB, then the meta text.
---@param data IssuesDetailHeaderData
---@param outer_width integer
---@return string line
---@return AtlasUIHighlight[] highlights
local function render_top_border(data, outer_width)
	local meta_left = data.breadcrumb or ""
	local meta_right = data.meta_right or ""
	local head = " ╭─ "
	local tail = " ─╮"
	-- Room for both texts after the corners, the 2 spaces around the fill,
	-- and at least 1 fill dash.
	local room = math.max(0, outer_width - text_width(head) - text_width(tail) - 3)
	local over = text_width(meta_left) + text_width(meta_right) - room
	if over > 0 then
		local left_w = text_width(meta_left)
		meta_left = utils.truncate(meta_left, math.max(math.min(MIN_BREADCRUMB, left_w), left_w - over), true)
		meta_right = utils.truncate(meta_right, math.max(0, room - text_width(meta_left)))
	end
	local fill = math.max(
		1,
		outer_width
			- text_width(head)
			- text_width(meta_left)
			- text_width(meta_right)
			- text_width(tail)
			- 2
	)

	local left_part = head .. meta_left .. " "
	local fill_str = string.rep("─", fill)
	local line = left_part .. fill_str .. " " .. meta_right .. tail
	local spans = { { line = 0, start_col = 0, end_col = #head, hl_group = "AtlasBorder" } }
	breadcrumb_spans(spans, #head, meta_left)
	table.insert(spans, {
		line = 0,
		start_col = #left_part,
		end_col = #left_part + #fill_str,
		hl_group = "AtlasBorder",
	})
	table.insert(spans, {
		line = 0,
		start_col = #line - #tail - #meta_right,
		end_col = #line - #tail,
		hl_group = "AtlasTextMuted",
	})
	table.insert(spans, { line = 0, start_col = #line - #tail, end_col = #line, hl_group = "AtlasBorder" })
	return line, spans
end

---@param data IssuesDetailHeaderData
---@param outer_width integer
---@param extra IssuesDetailHeaderBlock|nil Rendered inside the box, below a blank line after the body.
---@return string[] lines
---@return AtlasUIHighlight[] highlights
---@return table<string, AtlasFieldBoxRegion> regions `title`, plus `extra`'s regions moved into place.
function M.render(data, outer_width, extra)
	local width = M.inner_width(outer_width)

	local top, top_spans = render_top_border(data, outer_width)
	local lines, spans = { top }, top_spans

	-- Inner rows: a blank padding row, the body, then `extra` after a blank.
	local body_lines, body_spans, title_col = render_body(data, width)
	local inner, inner_spans = { "" }, {}
	local title_row = 1
	utils.append_block(inner, inner_spans, { lines = body_lines, highlights = body_spans })
	local extra_row
	if extra and #extra.lines > 0 then
		table.insert(inner, "")
		extra_row = #inner
		utils.append_block(inner, inner_spans, { lines = extra.lines, highlights = extra.highlights })
	end

	for _, line in ipairs(inner) do
		local pad = math.max(0, width - text_width(line))
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
			row = 1 + title_row,
			col = BOX_LEFT_COLS + title_col,
			width = math.max(1, width - title_col),
			height = 1,
		},
	}
	if extra_row then
		for id, region in pairs(extra.regions or {}) do
			regions[id] = {
				row = 1 + extra_row + region.row,
				col = BOX_LEFT_COLS + region.col,
				width = region.width,
				height = region.height,
			}
		end
	end
	return lines, spans, regions
end

return M
