-- Geometry of the pipeline graph (DESIGN-pipeline-view.md §3): one fixed-width
-- column per stage, 3-row job pills stacked under a stage header row, and the
-- box-drawing connectors in the gap between neighbouring stages. Also the
-- horizontal viewport for pipelines wider than the window. Pure: no editor state.
local M = {}

M.COL_W = 28 -- pill / stage column width (mockup: 236px)
M.GAP = 6 -- connector gap between columns (mockup: 56px)
M.PILL_H = 3
M.SPINE = 3 -- gap column the vertical connector runs in
-- Room kept at each edge for the "‹ n more" / "n more ›" markers once the
-- stages don't all fit.
M.MARKER_W = 9

---@param n_jobs integer
---@return integer rows Stage header row plus the pills.
function M.height(n_jobs)
	return 1 + M.PILL_H * math.max(0, n_jobs)
end

--- 0-based row of a job pill's top border.
---@param job_index integer 1-based
---@return integer
function M.pill_row(job_index)
	return 1 + M.PILL_H * (job_index - 1)
end

--- 0-based row of a job pill's middle (text) row -- where connectors attach.
---@param job_index integer 1-based
---@return integer
function M.mid_row(job_index)
	return M.pill_row(job_index) + 1
end

-- (up, down, left, right) -> glyph
local JUNCTIONS = {
	["0011"] = "─",
	["1100"] = "│",
	["0110"] = "┐",
	["0101"] = "┌",
	["1010"] = "┘",
	["1001"] = "└",
	["0111"] = "┬",
	["1011"] = "┴",
	["1110"] = "┤",
	["1101"] = "├",
	["1111"] = "┼",
	["0010"] = "─",
	["0001"] = "─",
	["1000"] = "│",
	["0100"] = "│",
}

--- Box-drawing glyph joining the given directions ("" when none).
---@param up boolean
---@param down boolean
---@param left boolean
---@param right boolean
---@return string
function M.junction(up, down, left, right)
	local key = (up and "1" or "0") .. (down and "1" or "0") .. (left and "1" or "0") .. (right and "1" or "0")
	return JUNCTIONS[key] or ""
end

--- The connector between a stage with `left_count` jobs and the next one with
--- `right_count`: a stub out of every left job's middle row, a vertical spine
--- in gap column `SPINE`, and a stub into every right job's middle row.
--- Returns the gap's text per 0-based row (each `GAP` cells wide); rows the
--- connector doesn't touch are absent.
---@param left_count integer
---@param right_count integer
---@return table<integer, string>
function M.connector(left_count, right_count)
	local rows = {}
	if left_count <= 0 or right_count <= 0 then
		return rows
	end
	local left, right = {}, {}
	local top, bottom = math.huge, -math.huge
	for j = 1, left_count do
		local r = M.mid_row(j)
		left[r] = true
		top, bottom = math.min(top, r), math.max(bottom, r)
	end
	for j = 1, right_count do
		local r = M.mid_row(j)
		right[r] = true
		top, bottom = math.min(top, r), math.max(bottom, r)
	end
	for r = top, bottom do
		local cells = {}
		for c = 0, M.GAP - 1 do
			cells[c] = " "
		end
		if left[r] then
			for c = 0, M.SPINE - 1 do
				cells[c] = "─"
			end
		end
		if right[r] then
			for c = M.SPINE + 1, M.GAP - 1 do
				cells[c] = "─"
			end
		end
		cells[M.SPINE] = M.junction(r > top, r < bottom, left[r] == true, right[r] == true)
		local parts = {}
		for c = 0, M.GAP - 1 do
			parts[#parts + 1] = cells[c]
		end
		rows[r] = table.concat(parts)
	end
	return rows
end

---@class AtlasPipelineViewport
---@field first integer 1-based index of the first visible stage
---@field last integer
---@field hidden_left integer
---@field hidden_right integer
---@field offset integer Column the first visible stage starts at.

--- Width `count` stage columns take, gaps included.
---@param count integer
---@return integer
function M.span(count)
	if count <= 0 then
		return 0
	end
	return count * M.COL_W + (count - 1) * M.GAP
end

--- Which stages fit into `width`, keeping `selected` visible. While the
--- selection stays inside the previous window (`prev_first`) the window
--- doesn't move; otherwise it shifts just far enough.
---@param n integer Number of stages.
---@param width integer
---@param selected integer 1-based selected stage.
---@param prev_first integer|nil
---@return AtlasPipelineViewport
function M.viewport(n, width, selected, prev_first)
	if n <= 0 then
		return { first = 1, last = 0, hidden_left = 0, hidden_right = 0, offset = 0 }
	end
	if M.span(n) <= width then
		return { first = 1, last = n, hidden_left = 0, hidden_right = 0, offset = 0 }
	end
	local room = width - 2 * M.MARKER_W
	local count = math.max(1, math.floor((room + M.GAP) / (M.COL_W + M.GAP)))
	count = math.min(count, n)
	selected = math.max(1, math.min(n, selected or 1))
	local first = prev_first or 1
	first = math.max(1, math.min(first, n - count + 1))
	if selected < first then
		first = selected
	elseif selected > first + count - 1 then
		first = selected - count + 1
	end
	local last = first + count - 1
	return {
		first = first,
		last = last,
		hidden_left = first - 1,
		hidden_right = n - last,
		offset = M.MARKER_W,
	}
end

--- Index (1-based) of the job in `jobs_count` closest to row `row` -- keeps
--- the vertical position when moving between stages (h/l).
---@param jobs_count integer
---@param from_index integer Job index in the stage being left.
---@return integer
function M.closest_job(jobs_count, from_index)
	if jobs_count <= 0 then
		return 0
	end
	return math.max(1, math.min(jobs_count, from_index))
end

return M
