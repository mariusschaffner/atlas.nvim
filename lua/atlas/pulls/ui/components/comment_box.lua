-- Shared single-comment rendering: a bordered box titled with the author's
-- name, the comment body as content, and an optional hint (e.g. "[gc] -
-- Reply") in the bottom border. Used by both the pulls detail view's
-- Activity tab (conversation/renderer.lua) and Review tab (review/renderer.lua)
-- so a comment looks and is structured identically in both places; each
-- caller owns its own interactivity (inline editing vs. a popup editor) and
-- just supplies the border color / bottom hint that reflects it.
local M = {}

local bordered_box = require("atlas.ui.components.bordered_box")
local emojis = require("atlas.ui.shared.emojis")
local presentation = require("atlas.pulls.ui.presentation")
local review_threads = require("atlas.pulls.ui.components.review_threads")
local utils = require("atlas.ui.shared.utils")

local CONTENT_PAD = " "
local MIN_BOX_WIDTH = 20
local BOX_WIDTH_RATIO = 0.8

---@param available_width integer
---@return integer box_width
function M.box_width(available_width)
	return math.max(MIN_BOX_WIDTH, math.floor(available_width * BOX_WIDTH_RATIO))
end

--- Joins a list of "[key] - Label" segments with " ── " into one bottom-hint
--- string, e.g. "[gc] - Reply ── [ge] - Edit ── [dd] - Delete".
---@param segments { action_id: string, label: string, hl: string }[]
---@return string|nil text
---@return table[]|nil highlights
function M.build_hint(segments)
	local parts, out_highlights, cursor = {}, {}, 0
	for _, seg in ipairs(segments) do
		if #parts > 0 then
			local sep = " ── "
			table.insert(parts, sep)
			cursor = cursor + #sep
		end
		local segment = utils.field_hint_label(seg.action_id, seg.label, true)
		table.insert(out_highlights, { start_col = cursor, end_col = cursor + #segment, hl_group = seg.hl })
		table.insert(parts, segment)
		cursor = cursor + #segment
	end
	if #parts == 0 then
		return nil, nil
	end
	return table.concat(parts), out_highlights
end

---@param line string
---@return table[] spans
local function mention_spans(line)
	local spans = {}
	local search_from = 1
	while true do
		local s, e, handle = line:find("@([%w_%.%-]+)", search_from)
		if not s then
			break
		end
		table.insert(spans, { start_col = s - 1, end_col = e, hl_group = presentation.author_hl(handle) })
		search_from = e + 1
	end
	return spans
end

---@param comment PullsComment
---@param reaction_options PullsReactionOption[]|nil
---@param wrap_width integer
---@param max_lines integer|nil Truncate the body to this many lines, with a "... (key to expand)" trailer.
---@param fold_key string|nil Key shown in the truncation trailer; no trailer text without it.
---@return string[] lines
---@return table[] highlights
---@return integer body_start
---@return integer body_line_count
local function comment_content(comment, reaction_options, wrap_width, max_lines, fold_key)
	local lines, out_highlights = {}, {}
	local date_text = utils.format_datetime(comment.created_on)
	if date_text ~= "" then
		table.insert(lines, date_text)
		table.insert(out_highlights, { line = 0, start_col = 0, end_col = #date_text, hl_group = "AtlasTextMuted" })
	end
	local body_start = #lines

	if comment.state == "DELETED" then
		local text = "(deleted comment)"
		table.insert(lines, text)
		table.insert(
			out_highlights,
			{ line = #lines - 1, start_col = 0, end_col = #text, hl_group = "AtlasTextMutedItalic" }
		)
		return lines, out_highlights, body_start, 0
	end

	local body_lines = utils.sanitize_lines(utils.strip_markup(comment.content_display or comment.content_raw or ""))
	while #body_lines > 0 and vim.trim(body_lines[#body_lines]) == "" do
		table.remove(body_lines)
	end
	if #body_lines == 0 then
		body_lines = { "(empty comment)" }
	end

	local truncated = max_lines ~= nil and #body_lines > max_lines
	local visible_count = truncated and max_lines or #body_lines
	for i = 1, visible_count do
		for _, wrapped_line in ipairs(utils.wrap_line(body_lines[i], wrap_width)) do
			table.insert(lines, wrapped_line)
			local line_idx = #lines - 1
			for _, span in ipairs(mention_spans(wrapped_line)) do
				table.insert(
					out_highlights,
					{ line = line_idx, start_col = span.start_col, end_col = span.end_col, hl_group = span.hl_group }
				)
			end
		end
	end
	local body_line_count = #lines - body_start
	if truncated then
		local text = fold_key and string.format("... (%s to expand)", fold_key) or "..."
		table.insert(lines, text)
		table.insert(out_highlights, { line = #lines - 1, start_col = 0, end_col = #text, hl_group = "AtlasTextMuted" })
	end

	local reactions_text, reaction_highlights = emojis.format(comment.reactions, reaction_options)
	if reactions_text ~= "" then
		table.insert(lines, reactions_text)
		local line_idx = #lines - 1
		for _, span in ipairs(reaction_highlights) do
			table.insert(
				out_highlights,
				{ line = line_idx, start_col = span.start_col, end_col = span.end_col, hl_group = span.hl_group }
			)
		end
	end

	return lines, out_highlights, body_start, body_line_count
end

---@param comment PullsComment
---@return string title
---@return table[] title_highlights
local function title_for(comment)
	local name = review_threads.author_name(comment.author)
	return name, { { start_col = 0, end_col = #name, hl_group = presentation.author_hl(name) } }
end

---@param lines string[]
---@param in_highlights table[]
---@return string[] lines
---@return table[] highlights
local function frame_content(lines, in_highlights)
	local framed_lines = {}
	for _, line in ipairs(lines) do
		table.insert(framed_lines, CONTENT_PAD .. line)
	end
	local framed_highlights = {}
	for _, span in ipairs(in_highlights) do
		table.insert(framed_highlights, {
			line = span.line,
			start_col = span.start_col + #CONTENT_PAD,
			end_col = span.end_col + #CONTENT_PAD,
			hl_group = span.hl_group,
		})
	end
	return framed_lines, framed_highlights
end

---@param box_lines string[]
---@param box_highlights table[]
---@param indent integer
local function apply_indent(box_lines, box_highlights, indent)
	if indent <= 0 then
		return
	end
	local pad = string.rep(" ", indent)
	for i, line in ipairs(box_lines) do
		box_lines[i] = pad .. line
	end
	for _, span in ipairs(box_highlights) do
		span.start_col = span.start_col + indent
		span.end_col = span.end_col + indent
	end
end

---@class AtlasCommentBoxOpts
---@field comment PullsComment
---@field depth integer|nil Indent level (0 = top-level); default 0.
---@field padding_x integer|nil Left padding before the box; default 1.
---@field width integer Available width to lay the box out in.
---@field reaction_options PullsReactionOption[]|nil
---@field max_lines integer|nil Truncate the body to this many lines; nil = never truncate.
---@field fold_key string|nil Key shown in the truncation trailer, when truncated.
---@field border_hl string|nil Defaults to "AtlasFieldBoxBorder" (grey/non-editable).
---@field bottom_hint string|nil
---@field bottom_hint_highlights table[]|nil
---@field extra_content_lines string[]|nil Appended after the body/reactions (e.g. a "N replies" summary).
---@field extra_content_highlights table[]|nil

---@param opts AtlasCommentBoxOpts
---@return string[] lines
---@return table[] highlights
---@return AtlasFieldBoxRegion region The body's interior region, relative to the returned `lines` --
--- for anchoring an inline-edit overlay.
function M.render(opts)
	local comment = opts.comment
	local depth = opts.depth or 0
	local padding_x = opts.padding_x or 1
	local indent = padding_x + depth * 2
	local available = math.max(MIN_BOX_WIDTH, opts.width - indent)
	local box_width = M.box_width(available)
	local wrap_width = math.max(1, box_width - 2 - #CONTENT_PAD)

	local content_lines, content_highlights, body_start, body_line_count =
		comment_content(comment, opts.reaction_options, wrap_width, opts.max_lines, opts.fold_key)
	for _, line in ipairs(opts.extra_content_lines or {}) do
		table.insert(content_lines, line)
	end
	for _, span in ipairs(opts.extra_content_highlights or {}) do
		table.insert(content_highlights, span)
	end

	local title, title_highlights = title_for(comment)
	local framed_lines, framed_highlights = frame_content(content_lines, content_highlights)

	local box_lines, box_highlights = bordered_box.render({
		width = box_width,
		box_width = box_width,
		title = title,
		title_highlights = title_highlights,
		content_lines = framed_lines,
		content_highlights = framed_highlights,
		border_hl = opts.border_hl or "AtlasFieldBoxBorder",
		bottom_hint = opts.bottom_hint,
		bottom_hint_highlights = opts.bottom_hint_highlights,
	})
	apply_indent(box_lines, box_highlights, indent)

	local region = {
		row = 1 + body_start,
		col = indent + 1,
		width = box_width - 2,
		height = math.max(1, body_line_count),
	}
	return box_lines, box_highlights, region
end

---@class AtlasComposingBoxOpts
---@field title string
---@field title_highlights table[]|nil
---@field depth integer|nil Indent level (0 = top-level); default 0.
---@field padding_x integer|nil Left padding before the box; default 1.
---@field width integer Available width to lay the box out in.
---@field content_height integer|nil Blank content rows reserved for typing; default 3.
---@field bottom_hint string|nil
---@field bottom_hint_highlights table[]|nil

--- An empty, orange-bordered box ("New Comment" while composing) -- the
--- placeholder an inline-edit overlay gets anchored onto while adding a new
--- top-level comment or reply.
---@param opts AtlasComposingBoxOpts
---@return string[] lines
---@return table[] highlights
---@return AtlasFieldBoxRegion region
function M.render_composing(opts)
	local depth = opts.depth or 0
	local padding_x = opts.padding_x or 1
	local indent = padding_x + depth * 2
	local available = math.max(MIN_BOX_WIDTH, opts.width - indent)
	local box_width = M.box_width(available)

	local content_lines = {}
	for _ = 1, (opts.content_height or 3) do
		table.insert(content_lines, "")
	end

	local box_lines, box_highlights = bordered_box.render({
		width = box_width,
		box_width = box_width,
		title = opts.title,
		title_highlights = opts.title_highlights,
		content_lines = content_lines,
		border_hl = "AtlasFieldBoxBorderEditing",
		bottom_hint = opts.bottom_hint,
		bottom_hint_highlights = opts.bottom_hint_highlights,
	})
	apply_indent(box_lines, box_highlights, indent)

	local region = { row = 1, col = indent + 1, width = box_width - 2, height = #content_lines }
	return box_lines, box_highlights, region
end

return M
