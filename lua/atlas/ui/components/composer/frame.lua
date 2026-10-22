-- The static chrome of an inline composer (reply / edit / new comment):
--
--   ▎↩ Reply to thread
--   ▎write a reply · markdown, @ to mention        <- text rows (overlaid)
--   ▎ INSERT  C-s post  Esc cancel        ● unsaved
--
-- A left accent bar on a tinted background, optional title or header row,
-- the text rows (the live editing float from `composer.session` sits on top
-- of them), and a footer with the mode badge, key hints and an "unsaved"
-- marker. Pure: returns lines/spans plus the text area's region.
local M = {}

local line_builder = require("atlas.ui.components.line")
local keyhints = require("atlas.ui.components.keyhints")
local mode_badge = require("atlas.ui.components.mode_badge")

local BAR = "▎"
local BG = "AtlasComposerBg"

--- Background-free stand-ins for the tinted composer groups (`transparent`).
local TRANSPARENT = {
	AtlasComposerBg = "Normal",
	AtlasComposerBar = "AtlasTimelineGuideActive",
	AtlasComposerTitle = "AtlasTimelineGuideActive",
	AtlasComposerText = "AtlasTimelineBody",
	AtlasComposerPlaceholder = "AtlasTextMutedItalic",
	AtlasComposerKey = "AtlasKeyHint",
	AtlasComposerHintLabel = "AtlasKeyHintLabel",
	AtlasComposerDirty = "AtlasKeyHint",
}

---@class AtlasComposerFrameOptions
---@field indent integer Display column the frame starts at.
---@field width integer Total width; every row's background runs to it.
---@field prefix AtlasLine|nil Lead-in already built for row 1 (e.g. a tree guide + avatar); the frame continues it from `indent`.
---@field bar boolean|nil Draw the left accent bar (default true).
---@field title AtlasTimelineEventSegment[]|nil Title row, e.g. { { "↩ Reply to thread", "AtlasComposerTitle" } }.
---@field header_left AtlasTimelineEventSegment[]|nil Header row's left side (docked composer: avatar + "Comment" chip).
---@field header_right AtlasTimelineEventSegment[]|nil Header row's right side, right-aligned.
---@field text_lines string[]|nil Current text (drawn under the overlay, so the frame reads right without it).
---@field height integer|nil Text rows (default max(1, #text_lines)).
---@field placeholder string|nil Shown when the text is empty.
---@field mode string|nil Vim mode for the footer badge; nil hides the badge.
---@field hints AtlasKeyHintSegment[]|nil
---@field dirty boolean|nil Shows "● unsaved" on the footer's right.
---@field separator boolean|nil Draws a rule between the text rows and the footer.
---@field transparent boolean|nil No tinted background (e.g. the docked composer, which has its own border).

---@param text_lines string[]|nil
---@return boolean
local function is_empty(text_lines)
	return text_lines == nil or #text_lines == 0 or (#text_lines == 1 and text_lines[1] == "")
end

---@param opts AtlasComposerFrameOptions
---@return string[] lines
---@return AtlasUIHighlight[] spans
---@return AtlasFieldBoxRegion region Text area: 0-based row within the block, display col, width, height.
function M.render(opts)
	local indent = opts.indent
	local width = math.max(indent + 4, opts.width)
	local bar = opts.bar ~= false
	local inner_col = indent + (bar and 2 or 1)
	local lines, spans = {}, {}
	local first = true

	---@return AtlasLine
	local function start_row()
		local line
		if first and opts.prefix then
			line = opts.prefix
		else
			line = line_builder.new()
		end
		first = false
		line:pad_to(indent)
		-- Background span first, so every later (explicit-bg) span layers on top.
		table.insert(line.spans, { start_col = line.bytes, end_col = -1, hl_group = BG })
		line.bg_index = #line.spans
		if bar then
			line:add(BAR, "AtlasComposerBar")
		end
		line:pad_to(inner_col, BG)
		return line
	end

	---@param line AtlasLine
	local function finish_row(line)
		line:pad_to(width, BG)
		line.spans[line.bg_index].end_col = line.bytes
		line:push(lines, spans)
	end

	---@param line AtlasLine
	---@param segments AtlasTimelineEventSegment[]
	local function add_segments(line, segments)
		for _, segment in ipairs(segments) do
			line:add(segment[1], segment[2] or BG)
		end
	end

	if opts.title then
		local line = start_row()
		add_segments(line, opts.title)
		finish_row(line)
	end

	if opts.header_left or opts.header_right then
		local line = start_row()
		add_segments(line, opts.header_left or {})
		if opts.header_right then
			local right = line_builder.new()
			add_segments(right, opts.header_right)
			line:pad_to(width - right.width - 1, BG)
			add_segments(line, opts.header_right)
		end
		finish_row(line)
		local spacer = start_row()
		finish_row(spacer)
	end

	local text_lines = opts.text_lines or {}
	local height = math.max(1, opts.height or #text_lines)
	local text_row = #lines
	local empty = is_empty(text_lines)
	for i = 1, height do
		local line = start_row()
		if empty and i == 1 and opts.placeholder then
			line:add(opts.placeholder, "AtlasComposerPlaceholder")
		elseif not empty and text_lines[i] then
			line:add(text_lines[i], "AtlasComposerText")
		end
		finish_row(line)
	end

	if opts.separator then
		local line = start_row()
		line:add(string.rep("─", math.max(0, width - inner_col - 1)), "AtlasComposerBorder")
		finish_row(line)
	end

	local footer = start_row()
	if opts.mode then
		local text, hl = mode_badge.render(opts.mode)
		footer:add(text, hl)
		footer:add(" ", BG)
	end
	keyhints.append(footer, opts.hints or {}, {
		key_hl = "AtlasComposerKey",
		label_hl = "AtlasComposerHintLabel",
		separator = "  ",
	})
	if opts.dirty then
		footer:right("● unsaved", "AtlasComposerDirty", width - 1, BG)
	end
	finish_row(footer)

	if opts.transparent then
		for _, span in ipairs(spans) do
			span.hl_group = TRANSPARENT[span.hl_group] or span.hl_group
		end
	end
	return lines,
		spans,
		{
			row = text_row,
			col = inner_col,
			width = math.max(1, width - inner_col - 1),
			height = height,
		}
end

--- Number of rows `render` produces for the given options, without
--- rendering (lets a host reserve space up front).
---@param opts AtlasComposerFrameOptions
---@return integer
function M.row_count(opts)
	local rows = math.max(1, opts.height or #(opts.text_lines or {})) + 1
	if opts.title then
		rows = rows + 1
	end
	if opts.header_left or opts.header_right then
		rows = rows + 2
	end
	if opts.separator then
		rows = rows + 1
	end
	return rows
end

return M
