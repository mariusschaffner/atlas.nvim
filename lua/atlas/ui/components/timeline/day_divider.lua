-- Day separators for a timeline: "YESTERDAY · 21.10.2026 ───────────" (label
-- left, rule to the right edge), and the centered "──── · NOW · ────"
-- marker shown above the docked comment composer.
local M = {}

local line_builder = require("atlas.ui.components.line")

local RULE = "─"

---@param label string
---@param width integer
---@param opts { padding_x: integer|nil }|nil
---@return string[] lines
---@return AtlasUIHighlight[] spans
function M.render(label, width, opts)
	opts = opts or {}
	local line = line_builder.new()
	line:add(string.rep(" ", opts.padding_x or 1))
	line:add(label, "AtlasTimelineDay")
	line:add(" ")
	local remaining = math.max(0, width - line.width - 1)
	line:add(string.rep(RULE, remaining), "AtlasTimelineRule")
	local text, spans = line:finish(0)
	return { text }, spans
end

---@param label string e.g. "NOW"
---@param width integer
---@param opts { label_hl: string|nil, rule_hl: string|nil }|nil
---@return string[] lines
---@return AtlasUIHighlight[] spans
function M.render_centered(label, width, opts)
	opts = opts or {}
	local center = " · " .. label .. " · "
	local center_width = vim.fn.strdisplaywidth(center)
	local left = math.max(1, math.floor((width - center_width) / 2) - 1)
	local right = math.max(1, width - center_width - left - 2)
	local line = line_builder.new()
	line:add(" ")
	line:add(string.rep(RULE, left), opts.rule_hl or "AtlasTimelineRule")
	line:add(center, opts.label_hl or "AtlasTimelineGuideActive")
	line:add(string.rep(RULE, right), opts.rule_hl or "AtlasTimelineRule")
	local text, spans = line:finish(0)
	return { text }, spans
end

return M
