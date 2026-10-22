local markdown_sections = require("atlas.issues.ui.detail.milestone.markdown_sections")

describe("atlas.issues.ui.detail.milestone.markdown_sections.parse", function()
	it("returns an empty list for an empty or nil description", function()
		assert.are.same({}, markdown_sections.parse(nil))
		assert.are.same({}, markdown_sections.parse(""))
		assert.are.same({}, markdown_sections.parse("   \n  \n"))
	end)

	it("recognizes both '**Heading**:' and '**Heading**' as section headings", function()
		local sections = markdown_sections.parse("**Beschreibung**:\nSome text.\n\n**Notes**\nMore text.")
		assert.are.equal(2, #sections)
		assert.are.equal("Beschreibung", sections[1].name)
		assert.are.same({ "Some text." }, sections[1].lines)
		assert.are.equal("Notes", sections[2].name)
		assert.are.same({ "More text." }, sections[2].lines)
	end)

	it("keeps content before the first heading as a nameless preamble section", function()
		local sections = markdown_sections.parse("Intro line.\n\n**Details**\nBody.")
		assert.are.equal(2, #sections)
		assert.is_nil(sections[1].name)
		assert.are.same({ "Intro line." }, sections[1].lines)
		assert.are.equal("Details", sections[2].name)
	end)

	it("promotes a Meilenstein/Milestone/Goal section to the front, case-insensitively", function()
		for _, name in ipairs({ "Meilenstein", "Milestone", "Goal", "goal", "MEILENSTEIN" }) do
			local text = string.format("**Beschreibung**\nBody text.\n\n**%s**\nThe goal.", name)
			local sections = markdown_sections.parse(text)
			assert.are.equal(2, #sections)
			assert.is_true(sections[1].is_goal)
			assert.are.same({ "The goal." }, sections[1].lines)
			assert.are.equal("Beschreibung", sections[2].name)
			assert.is_falsy(sections[2].is_goal)
		end
	end)

	it("leaves a single goal section in place (no-op promotion)", function()
		local sections = markdown_sections.parse("**Goal**\nThe goal.\n\n**Beschreibung**\nBody.")
		assert.is_true(sections[1].is_goal)
		assert.are.equal("Beschreibung", sections[2].name)
	end)

	it("hides a Zeitplan section whose body only repeats the start/due dates", function()
		local sections = markdown_sections.parse("**Zeitplan**:\nStart: 20.10.2026\nDue: 16.11.2026")
		assert.are.equal(1, #sections)
		assert.is_true(sections[1].hidden)
	end)

	it("keeps a Zeitplan section that has extra prose beyond the dates", function()
		local sections = markdown_sections.parse("**Zeitplan**:\nStart: 20.10.2026\nSprint 1 continues into sprint 2.")
		assert.are.equal(1, #sections)
		assert.is_falsy(sections[1].hidden)
	end)

	it("preserves the order of non-goal sections", function()
		local sections = markdown_sections.parse("**A**\n1\n\n**B**\n2\n\n**C**\n3")
		local names = {}
		for _, section in ipairs(sections) do
			table.insert(names, section.name)
		end
		assert.are.same({ "A", "B", "C" }, names)
	end)

	it("does not crash on a description with no headings at all", function()
		local sections = markdown_sections.parse("Just a plain paragraph, no sections.")
		assert.are.equal(1, #sections)
		assert.is_nil(sections[1].name)
	end)
end)
