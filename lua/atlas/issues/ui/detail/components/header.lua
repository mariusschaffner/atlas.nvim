-- The issue detail view's header (DESIGN-detail-view.md §3): a dim meta line
-- (breadcrumb left, author/updated right), a title line (tinted state pill +
-- bold title + dim #iid), and a chip row (label chips, milestone, checklist
-- progress). Unlike the old `field_box`-based header, nothing here is a
-- bordered box -- just plain lines, matching the spec's "remove the boxes"
-- requirement (§2).
local M = {}

local utils = require("atlas.ui.shared.utils")
local ui_utils = require("atlas.ui.utils")

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

---@param data IssuesDetailHeaderData
---@param width integer
---@return string[] lines
---@return AtlasUIHighlight[] highlights
---@return table<string, AtlasFieldBoxRegion> regions Only `title`, for anchoring its inline-edit overlay.
function M.render(data, width)
	width = math.max(1, width)
	local lines, spans = {}, {}

	-- Meta line.
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

	-- Title line: state pill + title + dim #iid.
	local pill = string.format(" %s %s ", "●", data.state_label or "")
	local title_text = data.title or ""
	local title_prefix = pill .. " "
	local iid_text = data.iid_text or ""
	local title_line = title_prefix .. title_text .. (iid_text ~= "" and (" " .. iid_text) or "")
	local title_line_no = #lines
	table.insert(lines, title_line)
	table.insert(spans, { line = title_line_no, start_col = 0, end_col = #pill, hl_group = data.state_hl })
	table.insert(spans, {
		line = title_line_no,
		start_col = #title_prefix,
		end_col = #title_prefix + #title_text,
		hl_group = "AtlasTextBright",
	})
	if iid_text ~= "" then
		table.insert(
			spans,
			{ line = title_line_no, start_col = #title_line - #iid_text, end_col = #title_line, hl_group = "AtlasTextMuted" }
		)
	end
	local regions = {
		title = { row = title_line_no, col = #title_prefix, width = math.max(1, width - #title_prefix), height = 1 },
	}
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

	return lines, spans, regions
end

return M
