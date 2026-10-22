local closing_refs = require("atlas.pulls.ui.detail.closing_refs")

---@param refs AtlasClosingRef[]
---@return string[]
local function flat(refs)
	local out = {}
	for _, ref in ipairs(refs) do
		table.insert(out, (ref.project or "") .. "#" .. ref.iid .. "@" .. ref.line)
	end
	return out
end

describe("pulls.ui.detail.closing_refs.parse", function()
	it("finds Closes/Fixes refs with their line numbers", function()
		local refs = closing_refs.parse("Adds the role.\n\nCloses #22\nFixes #31\n")
		assert.are.same({ "#22@3", "#31@4" }, flat(refs))
		assert.are.equal("Closes", refs[1].keyword)
		assert.are.equal(22, refs[1].iid)
	end)

	it("accepts every tense and case of the closing keywords", function()
		local text = "closed #1\nFIXING #2\nResolves #3\nimplemented #4\nclose #5\nFix #6"
		assert.are.same({ "#1@1", "#2@2", "#3@3", "#4@4", "#5@5", "#6@6" }, flat(closing_refs.parse(text)))
	end)

	it("handles a colon, 'issue(s)' and lists joined by commas and 'and'", function()
		assert.are.same({ "#7@1" }, flat(closing_refs.parse("Closes: #7")))
		assert.are.same({ "#8@1" }, flat(closing_refs.parse("Fixes issue #8")))
		assert.are.same(
			{ "#1@1", "#2@1", "#3@1", "#4@1" },
			flat(closing_refs.parse("Closes issues #1, #2 and #3, and #4"))
		)
	end)

	it("keeps cross-project refs' project path", function()
		local refs = closing_refs.parse("Closes group/other-project#12 and #3")
		assert.are.same({ "group/other-project#12@1", "#3@1" }, flat(refs))
		assert.are.equal("group/other-project", refs[1].project)
		assert.is_nil(refs[2].project)
	end)

	it("finds refs mid-sentence and several per line", function()
		assert.are.same({ "#5@1", "#9@1" }, flat(closing_refs.parse("This closes #5 and also fixes #9.")))
	end)

	it("dedups repeated refs", function()
		assert.are.same({ "#22@1" }, flat(closing_refs.parse("Closes #22\nFixes #22")))
	end)

	it("ignores refs without a closing keyword", function()
		assert.are.same({}, flat(closing_refs.parse("Related to #22, see #23")))
		assert.are.same({}, flat(closing_refs.parse("Closes nothing #22")))
		assert.are.same({}, flat(closing_refs.parse("disclosed #22")))
		assert.are.same({}, flat(closing_refs.parse("Closes#22")))
	end)

	it("copes with empty and CRLF input", function()
		assert.are.same({}, flat(closing_refs.parse(nil)))
		assert.are.same({}, flat(closing_refs.parse("")))
		assert.are.same({ "#2@1", "#3@2" }, flat(closing_refs.parse("Closes #2\r\nFixes #3\r\n")))
	end)
end)
