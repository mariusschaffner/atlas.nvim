local model = require("atlas.pulls.ui.detail.tabs.changes.model")

local entries = {
	{ path = ".gitlab-ci.yml", lines_added = 27, lines_removed = 9 },
	{ path = "README.md", lines_added = 12, lines_removed = 0 },
	{ path = "ansible/roles/webaccess/tasks/main.yml", lines_added = 112, lines_removed = 0 },
	{ path = "webhook/app.py", lines_added = 71, lines_removed = 29 },
	{ path = "webhook/requirements.txt", lines_added = 3, lines_removed = 1 },
}

describe("pulls.ui.detail.tabs.changes.model.max_total/totals", function()
	it("finds the largest file and the sums", function()
		assert.are.equal(112, model.max_total(entries))
		local added, removed = model.totals(entries)
		assert.are.equal(225, added)
		assert.are.equal(39, removed)
	end)

	it("handles no files", function()
		assert.are.equal(0, model.max_total({}))
		assert.are.same({ 0, 0 }, { model.totals({}) })
	end)
end)

describe("pulls.ui.detail.tabs.changes.model.bar_cells", function()
	it("fills the whole bar for the largest file", function()
		assert.are.same({ 10, 0 }, { model.bar_cells(112, 0, 112) })
		assert.are.same({ 7, 3 }, { model.bar_cells(70, 30, 100) })
	end)

	it("scales the rest against the largest file", function()
		-- 36/112 -> 3 cells, 9 of 36 deleted -> 1 red
		assert.are.same({ 2, 1 }, { model.bar_cells(27, 9, 112) })
		-- 100/112 -> 9 cells, 29% deleted -> 3 red
		assert.are.same({ 6, 3 }, { model.bar_cells(71, 29, 112) })
		assert.are.same({ 1, 0 }, { model.bar_cells(12, 0, 112) })
	end)

	it("gives any changed file at least one cell", function()
		assert.are.same({ 1, 0 }, { model.bar_cells(3, 1, 112) })
		assert.are.same({ 0, 1 }, { model.bar_cells(0, 2, 112) })
		assert.are.same({ 0, 1 }, { model.bar_cells(1, 2, 500) })
	end)

	it("keeps one green cell when a file has additions", function()
		-- 30 of 31 deleted would round to 10 red cells; one stays green.
		assert.are.same({ 1, 9 }, { model.bar_cells(1, 30, 31) })
	end)

	it("handles deletion-only files", function()
		assert.are.same({ 0, 10 }, { model.bar_cells(0, 50, 50) })
	end)

	it("is empty for unchanged files or an empty MR", function()
		assert.are.same({ 0, 0 }, { model.bar_cells(0, 0, 112) })
		assert.are.same({ 0, 0 }, { model.bar_cells(5, 5, 0) })
	end)

	it("respects a custom cell count", function()
		assert.are.same({ 5, 0 }, { model.bar_cells(112, 0, 112, 5) })
	end)
end)

describe("pulls.ui.detail.tabs.changes.model.split_path", function()
	it("splits directory and name", function()
		assert.are.same({ "webhook/", "app.py" }, { model.split_path("webhook/app.py", 40) })
		assert.are.same({ "", "README.md" }, { model.split_path("README.md", 40) })
	end)

	it("shortens the directory from the left", function()
		assert.are.same(
			{ "…ebaccess/tasks/", "main.yml" },
			{ model.split_path("ansible/roles/webaccess/tasks/main.yml", 24) }
		)
	end)

	it("drops the directory, then cuts the name", function()
		assert.are.same({ "", "main.yml" }, { model.split_path("ansible/main.yml", 9) })
		assert.are.same({ "", "very_lo…" }, { model.split_path("a/very_long_name.txt", 8) })
	end)
end)
