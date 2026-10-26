local log_model = require("atlas.pipelines.ui.detail.log_model")

local E = "\27"
local function start(epoch, key, title)
	return string.format("section_start:%d:%s\r%s[0K%s[36;1m%s%s[0;m\n", epoch, key, E, E, title, E)
end
local function finish(epoch, key)
	return string.format("section_end:%d:%s\r%s[0K\n", epoch, key, E)
end

local TRACE = table.concat({
	start(100, "prepare_executor", "Preparing the executor"),
	"Using Docker\n",
	"Pulling image\n",
	finish(103, "prepare_executor"),
	start(103, "step_script", "step_script"),
	E .. "[32;1m$ molecule test" .. E .. "[0;m\n",
	"[WARNING]: placeholder\n",
	E .. "[31;1mERROR: Job failed" .. E .. "[0;m\n",
}, "")

local function texts(rows)
	local out = {}
	for _, row in ipairs(rows) do
		table.insert(out, row.text)
	end
	return out
end

describe("atlas.pipelines.ui.detail.log_model", function()
	describe("build", function()
		it("turns sections into header rows and strips the colour codes", function()
			local rows = log_model.build(TRACE)
			assert.are.same({
				"▾ Preparing the executor · 3s",
				"Using Docker",
				"Pulling image",
				"▾ step_script",
				"$ molecule test",
				"[WARNING]: placeholder",
				"ERROR: Job failed",
			}, texts(rows))
		end)

		it("records each section's fold range, depth and duration", function()
			local rows = log_model.build(TRACE)
			assert.are.same(
				{ "Preparing the executor", "prepare_executor", 3, 3, 0 },
				{ rows[1].section.name, rows[1].section.key, rows[1].section.duration, rows[1].section.last, rows[1].section.depth }
			)
			assert.is_nil(rows[4].section.duration)
			assert.equal(7, rows[4].section.last)
		end)

		it("colours section headers in the accent colour with a dim duration", function()
			local row = log_model.build(TRACE)[1]
			assert.are.same({
				{ start_col = 0, end_col = #"▾ Preparing the executor", hl_group = "AtlasAccent" },
				{ start_col = #"▾ Preparing the executor", end_col = #row.text, hl_group = "AtlasTextMuted" },
			}, row.spans)
		end)

		it("keeps ANSI colours as spans", function()
			local row = log_model.build(TRACE)[5]
			assert.are.same({ { start_col = 0, end_col = #"$ molecule test", hl_group = "AtlasGreen" } }, row.spans)
		end)

		it("tints WARNING and ERROR lines", function()
			local rows = log_model.build(TRACE)
			assert.are.same({ "AtlasLogWarnLine", "AtlasYellow" }, { rows[6].line_hl, rows[6].number_hl })
			assert.are.same({ "AtlasLogErrorLine", "AtlasRed" }, { rows[7].line_hl, rows[7].number_hl })
			assert.is_nil(rows[2].line_hl)
		end)

		it("falls back to the log classifier for uncoloured lines", function()
			local rows = log_model.build("$ make test\nerror: boom\n")
			assert.equal("AtlasLogInfo", rows[1].spans[1].hl_group)
			assert.equal("AtlasLogError", rows[2].spans[1].hl_group)
			assert.equal("AtlasLogErrorLine", rows[2].line_hl)
		end)

		it("nests sections", function()
			local rows = log_model.build(table.concat({
				start(1, "outer", "outer"),
				start(2, "inner", "inner"),
				"x\n",
				finish(3, "inner"),
				"y\n",
				finish(4, "outer"),
			}, ""))
			assert.are.same({ "▾ outer · 3s", "▾ inner · 1s", "x", "y" }, texts(rows))
			assert.are.same({ 0, 4 }, { rows[1].section.depth, rows[1].section.last })
			assert.are.same({ 1, 3 }, { rows[2].section.depth, rows[2].section.last })
		end)
	end)

	describe("folds", function()
		it("lists sections with content, marking finished ones", function()
			local folds = log_model.folds(log_model.build(TRACE))
			assert.are.same({ { row = 1, last = 3, finished = true }, { row = 4, last = 7, finished = false } }, folds)
		end)

		it("skips empty sections", function()
			local rows = log_model.build(start(1, "a", "a") .. finish(2, "a") .. "after\n")
			assert.are.same({}, log_model.folds(rows))
		end)
	end)

	describe("first_diff", function()
		it("is nil for identical logs", function()
			assert.is_nil(log_model.first_diff(log_model.build(TRACE), log_model.build(TRACE)))
		end)

		it("points at the first new row when lines are appended", function()
			local old = log_model.build(TRACE)
			local new = log_model.build(TRACE .. "more\n")
			assert.equal(8, log_model.first_diff(old, new))
		end)

		it("points at a partial last line once it's completed", function()
			local old = log_model.build(TRACE .. "wait")
			local new = log_model.build(TRACE .. "waiting done\n")
			assert.equal(8, log_model.first_diff(old, new))
		end)

		it("doesn't treat a running section growing as a header change", function()
			local old = log_model.build(TRACE)
			local new = log_model.build(TRACE .. "one more\n")
			assert.equal(8, log_model.first_diff(old, new))
		end)

		it("points at the header when the running section finishes", function()
			local old = log_model.build(TRACE)
			local new = log_model.build(TRACE .. finish(200, "step_script"))
			assert.equal(4, log_model.first_diff(old, new))
		end)
	end)

	describe("first_error_row", function()
		it("finds the first error line", function()
			assert.equal(7, log_model.first_error_row(log_model.build(TRACE)))
			assert.is_nil(log_model.first_error_row(log_model.build("all good\n")))
		end)
	end)
end)
