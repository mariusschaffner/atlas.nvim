-- One compact timeline event: "  @  Jane Doe assigned to @john     11:52".
-- A colored icon centered under the avatar column, the actor in bold, the
-- event text as caller-colored segments, optional inline key hints
-- (" · ⏎ expand"), and the local time right-aligned. Always exactly one
-- line: segments are truncated so the time keeps its column.
local M = {}

local line_builder = require("atlas.ui.components.line")
local keyhints = require("atlas.ui.components.keyhints")
local utils = require("atlas.ui.shared.utils")

--- Display column the icon starts at / the text starts at, relative to
--- `padding_x` -- chosen so event icons sit centered under a comment's
--- " XX " avatar chip and event text lines up with the comment author.
M.ICON_OFFSET = 2
M.TEXT_OFFSET = 5

---@class AtlasTimelineEventSegment
---@field [1] string text
---@field [2] string|nil hl_group

---@class AtlasTimelineEvent
---@field icon string
---@field icon_hl string|nil
---@field actor string|nil
---@field segments AtlasTimelineEventSegment[]
---@field time string|nil Already formatted, e.g. "11:52".
---@field hints AtlasKeyHintSegment[]|nil Appended after " · ".

---@param event AtlasTimelineEvent
---@param width integer
---@param opts { padding_x: integer|nil }|nil
---@return string[] lines
---@return AtlasUIHighlight[] spans
function M.render(event, width, opts)
	opts = opts or {}
	local pad = opts.padding_x or 1
	local time = event.time or ""
	local time_width = vim.fn.strdisplaywidth(time)
	-- Everything left of the time must end at least one column before it.
	local budget = math.max(1, width - time_width - 2)

	local line = line_builder.new()
	line:add(string.rep(" ", pad + M.ICON_OFFSET))
	line:add(event.icon, event.icon_hl or "AtlasTimelineIconDefault")
	line:pad_to(pad + M.TEXT_OFFSET)

	local pieces = {}
	if event.actor and event.actor ~= "" then
		table.insert(pieces, { event.actor, "AtlasTimelineActor" })
		table.insert(pieces, { " " })
	end
	vim.list_extend(pieces, event.segments or {})

	local truncated = false
	for _, piece in ipairs(pieces) do
		local text = piece[1] or ""
		local available = budget - line.width
		if available <= 0 then
			truncated = true
			break
		end
		if vim.fn.strdisplaywidth(text) > available then
			line:add(utils.truncate(text, available), piece[2])
			truncated = true
			break
		end
		line:add(text, piece[2])
	end

	if not truncated and event.hints and #event.hints > 0 then
		local hint_text = keyhints.render(event.hints)
		if hint_text ~= "" and line.width + 3 + vim.fn.strdisplaywidth(hint_text) <= budget then
			line:add(" · ", "AtlasTimelineVerb")
			keyhints.append(line, event.hints, { label_hl = "AtlasTimelineVerb" })
		end
	end

	if time ~= "" then
		line:right(time, "AtlasTimelineTime", width)
	end
	local text, spans = line:finish(0)
	return { text }, spans
end

return M
