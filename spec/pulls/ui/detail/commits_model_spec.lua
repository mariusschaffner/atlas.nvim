local model = require("atlas.pulls.ui.detail.tabs.commits.model")

describe("pulls.ui.detail.tabs.commits.model.parse", function()
	it("splits type, scope and subject", function()
		local c = model.parse("fix(docs): fix missing links to supported env")
		assert.are.equal("fix", c.type)
		assert.are.equal("docs", c.scope)
		assert.are.equal("fix missing links to supported env", c.subject)
		assert.is_false(c.breaking)
		assert.is_false(c.merge)
	end)

	it("handles a type without scope, breaking marks and case", function()
		local c = model.parse("Feat!: drop the old API")
		assert.are.equal("feat", c.type)
		assert.is_nil(c.scope)
		assert.is_true(c.breaking)
		assert.are.equal("drop the old API", c.subject)
		assert.are.equal("ci", model.parse("testing(ci)!: x").scope)
	end)

	it("uses only the first line", function()
		assert.are.equal("subject", model.parse("feat: subject\r\n\nbody text").subject)
	end)

	it("recognises merge commits", function()
		local c = model.parse("Merge branch '22-create-pipeline' into 'master'")
		assert.are.equal("merge", c.type)
		assert.is_true(c.merge)
		assert.are.equal("22-create-pipeline → master", c.subject)
		assert.are.equal("feature", model.parse("Merge branch 'feature'").subject)
		assert.are.equal(
			"origin/main → dev",
			model.parse("Merge remote-tracking branch 'origin/main' into dev").subject
		)
	end)

	it("leaves non-conventional subjects untyped", function()
		for _, message in ipairs({ "Update README.md", "fix: ", "wip stuff: more", "(scope): x", "" }) do
			assert.is_nil(model.parse(message).type, message)
		end
		assert.are.equal("Update README.md", model.parse("Update README.md").subject)
	end)
end)

describe("pulls.ui.detail.tabs.commits.model.tally", function()
	it("counts per type, most frequent first, ties by first appearance", function()
		local tally = model.tally({
			"Merge branch 'a' into 'b'",
			"fix(docs): a",
			"fix: b",
			"feat(ci): c",
			"feat(docs): d",
			"testing(ci): e",
			"fix(ci): f",
			"testing: g",
			"feat: h",
			"no type here",
		})
		assert.are.same({
			{ type = "fix", count = 3 },
			{ type = "feat", count = 3 },
			{ type = "testing", count = 2 },
			{ type = "merge", count = 1 },
		}, tally)
	end)

	it("is empty without typed commits", function()
		assert.are.same({}, model.tally({ "plain", "another" }))
		assert.are.same({}, model.tally({}))
	end)
end)
