-- Pure day-math for the milestone detail view's timeline strip
-- (DESIGN-milestone-view.md §4) and its title state pill (§3). Takes/returns
-- plain dates and numbers only -- no vim.api, no "now" of its own (callers
-- pass `today_iso`), so every edge case in §4's table can be driven directly
-- from a busted spec.
local M = {}

local shared_utils = require("atlas.ui.shared.utils")

---@param iso string|nil "YYYY-MM-DD" (optionally followed by a time part, ignored)
---@return integer|nil epoch_seconds
local function parse_date(iso)
	if type(iso) ~= "string" then
		return nil
	end
	local y, m, d = iso:match("^(%d%d%d%d)-(%d%d)-(%d%d)")
	if y == nil then
		return nil
	end
	return shared_utils.utc_epoch(tonumber(y), tonumber(m), tonumber(d), 0, 0, 0)
end
M.parse_date = parse_date

--- Inverse of the civil-to-days conversion `shared_utils.utc_epoch` uses
--- (Howard Hinnant's `civil_from_days`), needed to format a tick's day-number
--- back into a `DD.MM.` label.
---@param day_number integer Days since 1970-01-01.
---@return integer y, integer m, integer d
local function civil_from_days(day_number)
	local z = day_number + 719468
	local era = math.floor((z >= 0 and z or z - 146096) / 146097)
	local doe = z - era * 146097
	local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
	local y = yoe + era * 400
	local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
	local mp = math.floor((5 * doy + 2) / 153)
	local d = doy - math.floor((153 * mp + 2) / 5) + 1
	local m = mp + (mp < 10 and 3 or -9)
	return y + (m <= 2 and 1 or 0), m, d
end

---@param iso string
---@return string|nil -- "DD.MM." label, nil if unparsable
function M.format_date(iso)
	local epoch = parse_date(iso)
	if epoch == nil then
		return nil
	end
	local _, m, d = civil_from_days(math.floor(epoch / 86400))
	return string.format("%02d.%02d.", d, m)
end

---@param iso_a string
---@param iso_b string
---@return integer|nil days -- iso_b - iso_a, in whole days
function M.days_between(iso_a, iso_b)
	local a, b = parse_date(iso_a), parse_date(iso_b)
	if a == nil or b == nil then
		return nil
	end
	return math.floor((b - a) / 86400 + 0.5)
end

--- The timeline strip's effective start date: `milestone.start_date` when
--- set, else `milestone.created_at` as a creation-date fallback when only a
--- due date is set (DESIGN-milestone-view.md §4's "only due date" row). `nil`
--- when neither a start date nor a usable fallback exists.
---@param milestone IssueMilestone
---@return string|nil
function M.resolve_start(milestone)
	if milestone.start_date and milestone.start_date ~= "" then
		return milestone.start_date
	end
	if milestone.due_date and milestone.due_date ~= "" and milestone.created_at and milestone.created_at ~= "" then
		return milestone.created_at
	end
	return nil
end

---@class AtlasMilestoneBarState
---@field state "no_dates"|"before_start"|"in_progress"|"overdue"|"closed"
---@field days integer|nil Present for "before_start" (days until start) and "overdue" (days past due).

---@param today_iso string
---@param start_iso string|nil Already resolved via `M.resolve_start` if applicable.
---@param due_iso string|nil
---@param closed boolean
---@return AtlasMilestoneBarState
function M.bar_state(today_iso, start_iso, due_iso, closed)
	-- Checked before `closed`: a closed milestone with no dates at all still
	-- has nothing to draw a bar or a "closed DD.MM." label from.
	if (start_iso == nil or start_iso == "") and (due_iso == nil or due_iso == "") then
		return { state = "no_dates" }
	end
	if closed then
		return { state = "closed" }
	end
	if start_iso and start_iso ~= "" then
		local days = M.days_between(today_iso, start_iso)
		if days and days > 0 then
			return { state = "before_start", days = days }
		end
	end
	if due_iso and due_iso ~= "" then
		local days = M.days_between(due_iso, today_iso)
		if days and days > 0 then
			return { state = "overdue", days = days }
		end
	end
	return { state = "in_progress" }
end

--- The today-marker's column (0-indexed, clamped to the strip's width),
--- `nil` when either date is missing (caller should hide the bar instead).
---@param today_iso string
---@param start_iso string
---@param due_iso string
---@param width integer
---@return integer|nil
function M.column_for(today_iso, start_iso, due_iso, width)
	local today_epoch, start_epoch, due_epoch = parse_date(today_iso), parse_date(start_iso), parse_date(due_iso)
	if today_epoch == nil or start_epoch == nil or due_epoch == nil then
		return nil
	end
	local start_day = math.floor(start_epoch / 86400)
	local due_day = math.floor(due_epoch / 86400)
	local today_day = math.floor(today_epoch / 86400)
	local total_days = math.max(1, due_day - start_day + 1)
	local offset = math.max(0, math.min(total_days - 1, today_day - start_day))
	local col = math.floor(offset * width / total_days)
	return math.max(0, math.min(width - 1, col))
end

---@class AtlasMilestoneTick
---@field col integer 0-indexed column.
---@field text string|nil "DD.MM." label; nil when dropped for overlapping the next tick.
---@field right_aligned boolean|nil When true (the due date's tick), `text` ends at `col` rather than starting there.

--- Tick marks for the date line: the start date, every Monday strictly
--- between start and due, and the due date (right-aligned at the strip's
--- last column). When two labels would overlap, the earlier one's text is
--- dropped and its tick column kept (DESIGN-milestone-view.md §4).
---@param start_iso string|nil
---@param due_iso string|nil
---@param width integer
---@return AtlasMilestoneTick[]
function M.date_ticks(start_iso, due_iso, width)
	local start_epoch, due_epoch = parse_date(start_iso), parse_date(due_iso)
	if start_epoch == nil or due_epoch == nil or due_epoch < start_epoch or width <= 0 then
		return {}
	end

	local start_day = math.floor(start_epoch / 86400)
	local due_day = math.floor(due_epoch / 86400)
	local total_days = due_day - start_day + 1

	---@param day_number integer
	---@return string
	local function fmt_day(day_number)
		local _, m, d = civil_from_days(day_number)
		return string.format("%02d.%02d.", d, m)
	end
	-- (kept local rather than calling `M.format_date` to avoid re-parsing an
	-- ISO string we've already converted to a day number)

	---@param day_number integer
	---@return integer
	local function col_for(day_number)
		local offset = day_number - start_day
		local col = math.floor(offset * width / total_days)
		return math.max(0, math.min(width - 1, col))
	end

	local ticks = { { col = 0, text = fmt_day(start_day) } }
	for day = start_day + 1, due_day - 1 do
		-- 1970-01-01 (day 0) was a Thursday; day_number % 7 == 4 lands on Monday.
		if ((day % 7) + 7) % 7 == 4 then
			table.insert(ticks, { col = col_for(day), text = fmt_day(day) })
		end
	end
	-- The due date's label is right-aligned (ends at, rather than starts at,
	-- its tick column) -- it's flush against the strip's closing border.
	table.insert(ticks, { col = width - 1, text = fmt_day(due_day), right_aligned = true })

	-- Drop the earlier label when two overlap -- the tick (column) stays,
	-- only its text is cleared. Compares actual rendered [start, end) ranges
	-- rather than raw tick columns, since the due tick's label is
	-- right-aligned (ends at its column instead of starting there).
	---@param tick AtlasMilestoneTick
	---@return integer text_start, integer text_end -- half-open, 1 column per character
	local function text_range(tick)
		if tick.right_aligned then
			return tick.col - #tick.text + 1, tick.col + 1
		end
		return tick.col, tick.col + #tick.text
	end

	for i = 1, #ticks - 1 do
		local tick, next_tick = ticks[i], ticks[i + 1]
		if tick.text ~= nil and next_tick.text ~= nil then
			local _, tick_end = text_range(tick)
			local next_start = text_range(next_tick)
			if tick_end > next_start then
				tick.text = nil
			end
		end
	end

	return ticks
end

---@param milestone IssueMilestone
---@param today_iso string
---@return { label: string, hl: string }
function M.state_pill(milestone, today_iso)
	if milestone.state == "closed" then
		return { label = "Closed", hl = "AtlasGLIssueClosedPillChip" }
	end

	if milestone.start_date and milestone.start_date ~= "" then
		local days = M.days_between(today_iso, milestone.start_date)
		if days and days > 0 then
			return { label = "Upcoming", hl = "AtlasGLMilestoneUpcomingPillChip" }
		end
	end

	if milestone.due_date and milestone.due_date ~= "" then
		local days = M.days_between(milestone.due_date, today_iso)
		if days and days > 0 then
			return { label = "Overdue", hl = "AtlasGLMilestoneOverduePillChip" }
		end
	end

	return { label = "Active", hl = "AtlasGLMilestoneActivePillChip" }
end

return M
