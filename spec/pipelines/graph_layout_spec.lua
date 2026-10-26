local layout = require("atlas.pipelines.ui.detail.graph_layout")

--- The connector as a list of strings, top to bottom (`.` = untouched row).
local function draw(left, right)
	local rows = layout.connector(left, right)
	local out = {}
	local last = -1
	for r in pairs(rows) do
		last = math.max(last, r)
	end
	for r = 0, last do
		out[#out + 1] = rows[r] or "."
	end
	return out
end

describe("atlas.pipelines.ui.detail.graph_layout", function()
	describe("rows", function()
		it("puts the stage header on row 0 and 3-row pills under it", function()
			assert.equal(1, layout.pill_row(1))
			assert.equal(2, layout.mid_row(1))
			assert.equal(4, layout.pill_row(2))
			assert.equal(5, layout.mid_row(2))
			assert.equal(8, layout.mid_row(3))
			assert.equal(1, layout.height(0))
			assert.equal(7, layout.height(2))
		end)
	end)

	describe("junction", function()
		it("joins every direction combination", function()
			assert.equal("─", layout.junction(false, false, true, true))
			assert.equal("│", layout.junction(true, true, false, false))
			assert.equal("┬", layout.junction(false, true, true, true))
			assert.equal("┴", layout.junction(true, false, true, true))
			assert.equal("┘", layout.junction(true, false, true, false))
			assert.equal("└", layout.junction(true, false, false, true))
			assert.equal("┐", layout.junction(false, true, true, false))
			assert.equal("┌", layout.junction(false, true, false, true))
			assert.equal("┤", layout.junction(true, true, true, false))
			assert.equal("├", layout.junction(true, true, false, true))
			assert.equal("┼", layout.junction(true, true, true, true))
			assert.equal("", layout.junction(false, false, false, false))
		end)
	end)

	describe("connector", function()
		it("draws a straight line between single jobs", function()
			assert.are.same({ ".", ".", "──────" }, draw(1, 1))
		end)

		it("fans in 2 -> 1", function()
			assert.are.same({ ".", ".", "───┬──", "   │  ", "   │  ", "───┘  " }, draw(2, 1))
		end)

		it("fans out 1 -> 2", function()
			assert.are.same({ ".", ".", "───┬──", "   │  ", "   │  ", "   └──" }, draw(1, 2))
		end)

		it("joins 2 -> 2", function()
			assert.are.same({ ".", ".", "───┬──", "   │  ", "   │  ", "───┴──" }, draw(2, 2))
		end)

		it("fans in 3 -> 1 with a tee on the middle job", function()
			local rows = draw(3, 1)
			assert.equal("───┬──", rows[3])
			assert.equal("───┤  ", rows[6])
			assert.equal("───┘  ", rows[9])
		end)

		it("fans out 1 -> 3", function()
			local rows = draw(1, 3)
			assert.equal("───┬──", rows[3])
			assert.equal("   ├──", rows[6])
			assert.equal("   └──", rows[9])
		end)

		it("joins 3 -> 3 with crosses in the middle", function()
			local rows = draw(3, 3)
			assert.equal("───┬──", rows[3])
			assert.equal("───┼──", rows[6])
			assert.equal("───┴──", rows[9])
		end)

		it("joins uneven stages (2 -> 3) down to the deepest job", function()
			local rows = draw(2, 3)
			assert.equal("───┬──", rows[3])
			assert.equal("───┼──", rows[6])
			assert.equal("   └──", rows[9])
			assert.equal(9, #rows)
		end)

		it("draws nothing next to an empty stage", function()
			assert.are.same({}, layout.connector(0, 2))
			assert.are.same({}, layout.connector(2, 0))
		end)
	end)

	describe("viewport", function()
		local stride = layout.COL_W + layout.GAP

		it("shows everything when it fits", function()
			local vp = layout.viewport(4, layout.span(4), 4, nil)
			assert.are.same({ 1, 4, 0, 0, 0 }, { vp.first, vp.last, vp.hidden_left, vp.hidden_right, vp.offset })
		end)

		it("reserves marker room and scrolls right to the selection", function()
			local width = 2 * layout.MARKER_W + layout.span(2)
			local vp = layout.viewport(8, width, 5, nil)
			assert.are.same({ 4, 5, 3, 3, layout.MARKER_W }, { vp.first, vp.last, vp.hidden_left, vp.hidden_right, vp.offset })
		end)

		it("doesn't move while the selection stays inside the window", function()
			local width = 2 * layout.MARKER_W + layout.span(3)
			local vp = layout.viewport(8, width, 4, 3)
			assert.are.same({ 3, 5 }, { vp.first, vp.last })
		end)

		it("scrolls back left", function()
			local width = 2 * layout.MARKER_W + layout.span(3)
			local vp = layout.viewport(8, width, 2, 4)
			assert.are.same({ 2, 4, 1, 4 }, { vp.first, vp.last, vp.hidden_left, vp.hidden_right })
		end)

		it("always shows at least one stage", function()
			local vp = layout.viewport(5, 10, 3, nil)
			assert.are.same({ 3, 3 }, { vp.first, vp.last })
		end)

		it("clamps a stale window to the stage count", function()
			local width = 2 * layout.MARKER_W + layout.span(2)
			local vp = layout.viewport(3, width, 3, 7)
			assert.are.same({ 2, 3 }, { vp.first, vp.last })
			assert.equal(stride, layout.COL_W + layout.GAP)
		end)
	end)

	describe("closest_job", function()
		it("keeps the row, clamped to the target stage", function()
			assert.equal(2, layout.closest_job(3, 2))
			assert.equal(1, layout.closest_job(1, 2))
			assert.equal(0, layout.closest_job(0, 2))
		end)
	end)
end)
