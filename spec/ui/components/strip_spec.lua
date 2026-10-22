local strip = require("atlas.ui.components.strip")

---@param placed { col: integer, chunks: table[] }[]
---@return string[]
local function flat(placed)
	local out = {}
	for _, item in ipairs(placed) do
		local text = ""
		for _, chunk in ipairs(item.chunks) do
			text = text .. chunk[1]
		end
		table.insert(out, item.col .. ":" .. text)
	end
	return out
end

describe("ui.components.strip.width", function()
	it("counts one column per UTF-8 character", function()
		assert.are.equal(3, strip.width("abc"))
		assert.are.equal(4, strip.width("a·b…"))
		assert.are.equal(0, strip.width(""))
	end)
end)

describe("ui.components.strip.set_text/finalize", function()
	it("writes multi-byte characters into single cells and maps byte ranges", function()
		local cells = strip.cells(6)
		strip.set_glyph(cells, 0, "✓")
		strip.set_text(cells, 2, "a·b")
		local line, byte_range = strip.finalize(cells)
		assert.are.equal("✓ a·b ", line)
		local s, e = byte_range(2, 5)
		assert.are.equal("a·b", line:sub(s + 1, e))
	end)

	it("drops text past the end", function()
		local cells = strip.cells(3)
		strip.set_text(cells, 1, "abcdef")
		assert.are.equal(" ab", (strip.finalize(cells)))
	end)
end)

describe("ui.components.strip.node_columns", function()
	it("spreads nodes evenly, first left and last right", function()
		assert.are.same({ 0, 22, 45, 67 }, strip.node_columns(4, 70, 3))
		assert.are.same({ 0, 17 }, strip.node_columns(2, 20, 3))
		assert.are.same({ 0 }, strip.node_columns(1, 20, 3))
		assert.are.same({}, strip.node_columns(0, 20, 3))
	end)
end)

describe("ui.components.strip.place_labels", function()
	it("aligns first left, last right, the rest centred", function()
		local cols = strip.node_columns(3, 30, 3)
		local placed = strip.place_labels({ { { "aaaa" } }, { { "bb" } }, { { "cccc" } } }, cols, 3, 30)
		-- middle node at col 14 (centre 15): "bb" at 15 - 1 = 14
		assert.are.same({ "0:aaaa", "14:bb", "26:cccc" }, flat(placed))
	end)

	it("skips empty items", function()
		local cols = strip.node_columns(3, 30, 3)
		local placed = strip.place_labels({ { { "aaaa" } }, nil, { { "cccc" } } }, cols, 3, 30)
		assert.are.same({ "0:aaaa", "26:cccc" }, flat(placed))
	end)

	it("pushes overlapping labels apart and truncates when out of room", function()
		local cols = strip.node_columns(3, 20, 3)
		local placed = strip.place_labels({ { { "aaaaaaaa" } }, { { "bbbbbbbb" } }, { { "cccc" } } }, cols, 3, 20)
		-- b is pushed right of a (+2 gap), c pulled back to the edge, and b
		-- truncated to keep 2 columns before c.
		assert.are.same({ "0:aaaaaaaa", "10:bbb…", "16:cccc" }, flat(placed))
	end)
end)

describe("ui.components.strip.render_nodes", function()
	it("draws nodes, coloured segments, labels and hints", function()
		local lines, spans = strip.render_nodes({
			{ glyph = "✓", hl = "AtlasGreen", segment_hl = "AtlasGreen", label = { { "Pipe" } }, hint = { { "gp", "AtlasKeyHint" } } },
			{ glyph = "◷", hl = "AtlasYellow", segment_hl = "AtlasBorder", label = { { "Rev", "AtlasYellow" } } },
			{ glyph = "⇣", hl = "AtlasTextMuted", label = { { "Merge" } } },
		}, 21)
		assert.are.equal(3, #lines)
		assert.are.equal("(✓) ━━━━ (◷) ──── (⇣)", lines[1])
		assert.are.equal("Pipe     Rev    Merge", lines[2])
		assert.are.equal("gp", vim.trim(lines[3]))
		local has_green_segment = false
		for _, s in ipairs(spans) do
			if s.line == 0 and s.hl_group == "AtlasGreen" and lines[1]:sub(s.start_col + 1, s.end_col):find("━") then
				has_green_segment = true
			end
		end
		assert.is_true(has_green_segment)
	end)

	it("omits the hint line when no node has a hint", function()
		local lines = strip.render_nodes({
			{ glyph = "✓", hl = "AtlasGreen", label = { { "a" } } },
			{ glyph = "⇣", hl = "AtlasTextMuted", label = { { "b" } } },
		}, 10)
		assert.are.equal(2, #lines)
	end)
end)
