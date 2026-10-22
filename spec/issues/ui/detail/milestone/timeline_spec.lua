local timeline = require("atlas.issues.ui.detail.milestone.timeline")

describe("atlas.issues.ui.detail.milestone.timeline.days_between", function()
	it("computes whole days between two dates", function()
		assert.are.equal(7, timeline.days_between("2026-10-20", "2026-10-27"))
		assert.are.equal(0, timeline.days_between("2026-10-20", "2026-10-20"))
		assert.are.equal(-7, timeline.days_between("2026-10-27", "2026-10-20"))
	end)

	it("returns nil for an unparsable date", function()
		assert.is_nil(timeline.days_between("2026-10-20", "not-a-date"))
		assert.is_nil(timeline.days_between(nil, "2026-10-20"))
	end)
end)

describe("atlas.issues.ui.detail.milestone.timeline.resolve_start", function()
	it("prefers start_date when set", function()
		local milestone = { start_date = "2026-10-01", due_date = "2026-10-20", created_at = "2026-09-01T00:00:00Z" }
		assert.are.equal("2026-10-01", timeline.resolve_start(milestone))
	end)

	it("falls back to created_at when only due_date is set", function()
		local milestone = { due_date = "2026-10-20", created_at = "2026-09-01T00:00:00Z" }
		assert.are.equal("2026-09-01T00:00:00Z", timeline.resolve_start(milestone))
	end)

	it("returns nil when neither a start date nor a usable fallback exists", function()
		assert.is_nil(timeline.resolve_start({}))
		assert.is_nil(timeline.resolve_start({ due_date = "2026-10-20" }))
	end)
end)

describe("atlas.issues.ui.detail.milestone.timeline.bar_state", function()
	it("is 'before_start' when today is before the start date", function()
		local result = timeline.bar_state("2026-10-15", "2026-10-20", "2026-11-01", false)
		assert.are.equal("before_start", result.state)
		assert.are.equal(5, result.days)
	end)

	it("is 'overdue' when today is after the due date and the milestone is open", function()
		local result = timeline.bar_state("2026-11-05", "2026-10-20", "2026-11-01", false)
		assert.are.equal("overdue", result.state)
		assert.are.equal(4, result.days)
	end)

	it("is 'closed' regardless of dates", function()
		local result = timeline.bar_state("2026-11-05", "2026-10-20", "2026-11-01", true)
		assert.are.equal("closed", result.state)
	end)

	it("is 'no_dates' when both start and due are missing", function()
		local result = timeline.bar_state("2026-11-05", nil, nil, false)
		assert.are.equal("no_dates", result.state)
	end)

	it("is 'in_progress' when today falls within the range", function()
		local result = timeline.bar_state("2026-10-25", "2026-10-20", "2026-11-01", false)
		assert.are.equal("in_progress", result.state)
	end)

	it("is 'in_progress' on the exact start or due date", function()
		assert.are.equal("in_progress", timeline.bar_state("2026-10-20", "2026-10-20", "2026-11-01", false).state)
		assert.are.equal("in_progress", timeline.bar_state("2026-11-01", "2026-10-20", "2026-11-01", false).state)
	end)
end)

describe("atlas.issues.ui.detail.milestone.timeline.column_for", function()
	it("places today at column 0 on the start date", function()
		assert.are.equal(0, timeline.column_for("2026-10-20", "2026-10-20", "2026-11-01", 100))
	end)

	it("places today at the start of the due date's own segment (10-day span, 100-wide strip)", function()
		-- 2026-10-20 .. 2026-10-29 is a 10-day span; the due date is the 10th
		-- day (offset 9), so its segment starts at column 90 of 100.
		assert.are.equal(90, timeline.column_for("2026-10-29", "2026-10-20", "2026-10-29", 100))
	end)

	it("places today roughly at the midpoint for a date exactly between start and due", function()
		-- 2026-10-20 .. 2026-10-30 is an 11-day span (inclusive); day 5 (2026-10-25) is the midpoint.
		local col = timeline.column_for("2026-10-25", "2026-10-20", "2026-10-30", 110)
		assert.are.equal(50, col)
	end)

	it("doesn't divide by zero for a 1-day milestone", function()
		assert.are.equal(0, timeline.column_for("2026-10-20", "2026-10-20", "2026-10-20", 100))
	end)

	it("returns nil when a date is missing", function()
		assert.is_nil(timeline.column_for("2026-10-20", nil, "2026-11-01", 100))
	end)
end)

describe("atlas.issues.ui.detail.milestone.timeline.date_ticks", function()
	it("includes the start date, each following Monday, and the due date", function()
		-- 2026-10-20 is a Tuesday; Mondays in range: 2026-10-26, 2026-11-02.
		local ticks = timeline.date_ticks("2026-10-20", "2026-11-05", 80)
		local texts = {}
		for _, tick in ipairs(ticks) do
			table.insert(texts, tick.text)
		end
		assert.are.same({ "20.10.", "26.10.", "02.11.", "05.11." }, texts)
	end)

	it("drops the earlier label when two ticks would overlap, keeping the tick column", function()
		local ticks = timeline.date_ticks("2026-10-20", "2026-10-21", 4)
		-- A 2-day span squeezed into 4 columns forces the start and due ticks together.
		assert.are.equal(2, #ticks)
		assert.is_nil(ticks[1].text)
		assert.is_not_nil(ticks[2].text)
	end)

	it("returns an empty list when a date is missing", function()
		assert.are.same({}, timeline.date_ticks(nil, "2026-11-01", 80))
	end)
end)

describe("atlas.issues.ui.detail.milestone.timeline.state_pill", function()
	it("is Closed/purple when the milestone is closed", function()
		local pill = timeline.state_pill({ state = "closed" }, "2026-10-22")
		assert.are.same({ label = "Closed", hl = "AtlasGLIssueClosedPillChip" }, pill)
	end)

	it("is Upcoming/blue when the start date is in the future", function()
		local pill = timeline.state_pill({ state = "active", start_date = "2026-11-01" }, "2026-10-22")
		assert.are.same({ label = "Upcoming", hl = "AtlasGLMilestoneUpcomingPillChip" }, pill)
	end)

	it("is Overdue/red when the due date is in the past", function()
		local pill = timeline.state_pill({ state = "active", due_date = "2026-10-01" }, "2026-10-22")
		assert.are.same({ label = "Overdue", hl = "AtlasGLMilestoneOverduePillChip" }, pill)
	end)

	it("is Active/green otherwise", function()
		local milestone = { state = "active", start_date = "2026-10-01", due_date = "2026-11-01" }
		local pill = timeline.state_pill(milestone, "2026-10-22")
		assert.are.same({ label = "Active", hl = "AtlasGLMilestoneActivePillChip" }, pill)
	end)
end)
