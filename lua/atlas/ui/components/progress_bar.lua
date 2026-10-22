-- Pure-render progress indicators shared across detail views: a compact
-- tick-segment bar (DESIGN-detail-view.md §3's checklist progress, e.g.
-- "● ● ● ● ○ ○ 4/6 criteria") and a bracketed block gauge with a percentage
-- (the milestone detail view's "[██████░░░░] 67% (2/3)").
local M = {}

---@param completed integer
---@param total integer
---@param opts { segments: integer|nil, fill_hl: string|nil, empty_hl: string|nil, fill_char: string|nil, empty_char: string|nil }|nil
---@return string value
---@return table[] highlights Spans {start_col, end_col, hl_group} relative to `value`.
function M.render_segments(completed, total, opts)
	opts = opts or {}
	local segments = math.max(1, opts.segments or math.max(1, total))
	local fill_char = opts.fill_char or "●"
	local empty_char = opts.empty_char or "○"
	local fill_hl = opts.fill_hl or "AtlasProgressFill"
	local empty_hl = opts.empty_hl or "AtlasProgressEmpty"

	local filled = 0
	if total > 0 then
		filled = math.max(0, math.min(segments, math.floor((completed / total) * segments + 0.5)))
	end

	-- Built (and colored) one char at a time, space-separated, rather than
	-- `string.rep` + two blob spans -- the gap between segments needs each
	-- circle's own start/end tracked individually.
	local parts, spans = {}, {}
	local col = 0
	for i = 1, segments do
		local char = i <= filled and fill_char or empty_char
		table.insert(parts, char)
		table.insert(spans, { start_col = col, end_col = col + #char, hl_group = i <= filled and fill_hl or empty_hl })
		col = col + #char + 1
	end
	local value = table.concat(parts, " ")
	return value, spans
end

--- Bracketed block gauge with a trailing percentage and "(done/total)" count,
--- e.g. "[██████░░░░] 67% (2/3)".
---@param completed integer
---@param total integer
---@param percent integer
---@param opts { width: integer|nil, fill_hl: string|nil, empty_hl: string|nil }|nil
---@return string value
---@return table[] highlights
function M.render_gauge(completed, total, percent, opts)
	opts = opts or {}
	local width = opts.width or 16
	local fill_hl = opts.fill_hl or "AtlasTextPositive"
	local empty_hl = opts.empty_hl or "AtlasTextMuted"

	local filled = math.max(0, math.min(width, math.floor((percent / 100) * width + 0.5)))
	local filled_str = string.rep("█", filled)
	local empty_str = string.rep("█", width - filled)

	local spans = {}
	local cursor = 0
	local value = "["
	cursor = cursor + 1

	local filled_start = cursor
	value = value .. filled_str
	cursor = cursor + #filled_str
	if #filled_str > 0 then
		table.insert(spans, { start_col = filled_start, end_col = cursor, hl_group = fill_hl })
	end

	local empty_start = cursor
	value = value .. empty_str
	cursor = cursor + #empty_str
	if #empty_str > 0 then
		table.insert(spans, { start_col = empty_start, end_col = cursor, hl_group = empty_hl })
	end

	value = value .. "] "
	cursor = cursor + 2

	local pct_text = string.format("%d%%", percent)
	local pct_start = cursor
	value = value .. pct_text
	cursor = cursor + #pct_text
	table.insert(spans, {
		start_col = pct_start,
		end_col = cursor,
		hl_group = percent >= 100 and fill_hl or empty_hl,
	})

	value = value .. string.format(" (%d/%d)", completed, total)

	return value, spans
end

return M
