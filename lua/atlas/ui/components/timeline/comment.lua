-- A comment thread in a timeline: header row (" MS " avatar chip, author,
-- badges like "you" / "◷ unresolved thread", right-aligned time), the body
-- wrapped to a fraction of the width and indented under the author, then
-- each reply behind a tree guide ("├"/"└"). Optionally swaps a comment's body
-- for an inline editor, or appends a reply composer at the end of the
-- thread -- both drawn by caller-supplied render functions (typically
-- `atlas.ui.components.composer.frame`).
--
-- Pure: takes a display-model node, returns lines/spans plus a line_map and
-- interior regions, so it works in a buffer or as virt_lines alike.
local M = {}

local line_builder = require("atlas.ui.components.line")
local avatar = require("atlas.ui.components.avatar")
local utils = require("atlas.ui.shared.utils")

local GUIDE_MID = "├"
local GUIDE_LAST = "└"
--- Each nesting level shifts the avatar/text columns right by this much.
local DEPTH_STEP = 7
--- Text column relative to the avatar chip's start (" XX " + one space).
local TEXT_OFFSET = 5
local DEFAULT_WIDTH_RATIO = 0.8

---@class AtlasTimelineCommentNode
---@field id string
---@field author string
---@field is_you boolean|nil
---@field time string|nil Already formatted, e.g. "07:43".
---@field badges AtlasTimelineEventSegment[]|nil Header chips after the name/"you" badge.
---@field body_lines string[] Raw (unwrapped) body lines.
---@field max_lines integer|nil Show only this many raw body lines, plus a truncation hint.
---@field reactions_text string|nil
---@field reactions_spans { start_col: integer, end_col: integer, hl_group: string }[]|nil
---@field children AtlasTimelineCommentNode[]
---@field collapsed boolean|nil Replies hidden behind an "N replies" row.
---@field data any Caller payload, passed through to every `line_map` entry.

---@class AtlasTimelineComposerContext
---@field indent integer Display column the composer frame starts at.
---@field width integer Total available width.
---@field prefix AtlasLine|nil Builder already holding the first row's lead-in (guide + avatar); continue it for row 1.

---@alias AtlasTimelineComposerRender fun(ctx: AtlasTimelineComposerContext): string[], AtlasUIHighlight[], AtlasFieldBoxRegion|nil

---@class AtlasTimelineCommentOptions
---@field padding_x integer|nil
---@field width_ratio number|nil Fraction of the remaining width body text wraps at (default 0.8).
---@field body_spans (fun(line: string): { start_col: integer, end_col: integer, hl_group: string }[])|nil
---@field truncated_hints AtlasKeyHintSegment[]|nil Shown after "…" on a truncated body.
---@field collapsed_hints AtlasKeyHintSegment[]|nil Shown after "N replies" on a collapsed thread.
---@field editing_id string|nil Comment whose body is replaced by `render_editor`.
---@field render_editor AtlasTimelineComposerRender|nil
---@field reply_parent_id string|nil Thread root a reply composer is appended to.
---@field render_reply AtlasTimelineComposerRender|nil
---@field reply_author string|nil Name whose avatar leads the reply composer.

---@param pad integer
---@param depth integer
---@return integer chip_col, integer text_col, integer guide_col
local function columns(pad, depth)
	local chip_col = pad + depth * DEPTH_STEP
	return chip_col, chip_col + TEXT_OFFSET, chip_col - 2
end

---@param node AtlasTimelineCommentNode
---@param width integer
---@param opts AtlasTimelineCommentOptions|nil
---@return string[] lines
---@return AtlasUIHighlight[] spans
---@return table<integer, table> line_map 1-based rows within the block.
---@return table<string, AtlasFieldBoxRegion> regions 0-based rows within the block: "comment:<id>" (header row + body height) and "composer".
function M.render(node, width, opts)
	opts = opts or {}
	local pad = opts.padding_x or 1
	local ratio = opts.width_ratio or DEFAULT_WIDTH_RATIO
	local lines, spans, line_map, regions = {}, {}, {}, {}

	---@param row_kind string
	---@param current AtlasTimelineCommentNode
	---@param root AtlasTimelineCommentNode
	local function map_row(row_kind, current, root)
		line_map[#lines] = {
			kind = "comment",
			row_kind = row_kind,
			comment = current.data,
			root = root.data,
			comment_id = current.id,
		}
	end

	---@param block_lines string[]
	---@param block_spans AtlasUIHighlight[]
	---@param region AtlasFieldBoxRegion|nil
	---@param current AtlasTimelineCommentNode
	---@param root AtlasTimelineCommentNode
	local function append_composer(block_lines, block_spans, region, current, root)
		local base = line_builder.splice(lines, spans, block_lines, block_spans)
		for i = 1, #block_lines do
			line_map[base + i] = {
				kind = "comment",
				row_kind = "composer",
				comment = current.data,
				root = root.data,
				comment_id = current.id,
			}
		end
		if region then
			regions.composer = vim.tbl_extend("force", {}, region, { row = base + region.row })
		end
	end

	---@param text_col integer
	---@param text string
	---@param hl string
	---@param hints AtlasKeyHintSegment[]|nil
	local function push_meta_row(text_col, text, hl, hints)
		local line = line_builder.new()
		line:pad_to(text_col)
		line:add(text, hl)
		if hints and #hints > 0 then
			line:add(" · ", "AtlasTimelineVerb")
			require("atlas.ui.components.keyhints").append(line, hints, { label_hl = "AtlasTimelineVerb" })
		end
		line:push(lines, spans)
	end

	---@param current AtlasTimelineCommentNode
	---@param root AtlasTimelineCommentNode
	---@param depth integer
	---@param guide string|nil
	local function render_node(current, root, depth, guide)
		local chip_col, text_col, guide_col = columns(pad, depth)
		local editing = opts.editing_id ~= nil and opts.editing_id == current.id and opts.render_editor ~= nil

		-- Header.
		local header = line_builder.new()
		if guide then
			header:pad_to(guide_col)
			header:add(guide, "AtlasTimelineGuide")
		end
		header:pad_to(chip_col)
		local chip, chip_hl = avatar.chip(current.author)
		header:add(chip, chip_hl)
		header:add(" ")
		header:add(current.author, "AtlasTextBright")
		if current.is_you then
			header:add("  ")
			header:add(" you ", "AtlasBadgeYou")
		end
		local badges = editing and { { "✎ editing", "AtlasBadgeEditing" } } or current.badges or {}
		for _, badge in ipairs(badges) do
			header:add("  ")
			header:add(badge[1], badge[2])
		end
		if current.time and current.time ~= "" then
			header:right(current.time, "AtlasTimelineTime", width)
		end
		local header_row = header:push(lines, spans)
		map_row("header", current, root)

		-- Body (or the inline editor replacing it).
		local body_start = #lines
		if editing then
			local block_lines, block_spans, region = opts.render_editor({ indent = text_col, width = width })
			append_composer(block_lines, block_spans, region, current, root)
		else
			local wrap_width = math.max(10, math.floor((width - text_col) * ratio))
			local raw = current.body_lines or {}
			local visible = raw
			local truncated = current.max_lines ~= nil and #raw > current.max_lines
			if truncated then
				visible = vim.list_slice(raw, 1, current.max_lines)
			end
			for _, raw_line in ipairs(visible) do
				for _, wrapped in ipairs(utils.wrap_line(raw_line, wrap_width)) do
					local line = line_builder.new()
					line:pad_to(text_col)
					local offset = line.bytes
					line:add(wrapped, "AtlasTimelineBody")
					for _, span in ipairs(opts.body_spans and opts.body_spans(wrapped) or {}) do
						table.insert(line.spans, {
							start_col = offset + span.start_col,
							end_col = offset + span.end_col,
							hl_group = span.hl_group,
						})
					end
					line:push(lines, spans)
					map_row("body", current, root)
				end
			end
			if truncated then
				push_meta_row(text_col, "…", "AtlasTimelineVerb", opts.truncated_hints)
				map_row("body", current, root)
			end
		end
		regions["comment:" .. current.id] = {
			row = header_row,
			col = text_col,
			width = math.max(1, width - text_col),
			height = math.max(1, #lines - body_start),
		}

		if current.reactions_text and current.reactions_text ~= "" then
			local line = line_builder.new()
			line:pad_to(text_col)
			local offset = line.bytes
			line:add(current.reactions_text)
			for _, span in ipairs(current.reactions_spans or {}) do
				table.insert(line.spans, {
					start_col = offset + span.start_col,
					end_col = offset + span.end_col,
					hl_group = span.hl_group,
				})
			end
			line:push(lines, spans)
			map_row("reactions", current, root)
		end

		local children = current.children or {}
		if depth == 0 and current.collapsed and #children > 0 then
			local count = #children
			push_meta_row(
				text_col,
				string.format("▸ %d %s", count, count == 1 and "reply" or "replies"),
				"AtlasTimelineVerb",
				opts.collapsed_hints
			)
			map_row("collapsed", current, root)
			return
		end

		local has_reply = depth == 0 and opts.render_reply ~= nil and opts.reply_parent_id == current.id
		for index, child in ipairs(children) do
			local last = index == #children and not has_reply
			render_node(child, root, depth + 1, last and GUIDE_LAST or GUIDE_MID)
		end

		if has_reply then
			local reply_chip_col, reply_text_col, reply_guide_col = columns(pad, depth + 1)
			local prefix = line_builder.new()
			prefix:pad_to(reply_guide_col)
			prefix:add(GUIDE_LAST, "AtlasTimelineGuideActive")
			prefix:pad_to(reply_chip_col)
			local reply_chip, reply_chip_hl = avatar.chip(opts.reply_author)
			prefix:add(reply_chip, reply_chip_hl)
			local block_lines, block_spans, region =
				opts.render_reply({ indent = reply_text_col, width = width, prefix = prefix })
			append_composer(block_lines, block_spans, region, current, root)
		end
	end

	render_node(node, node, 0, nil)
	return lines, spans, line_map, regions
end

return M
