local graph = require("atlas.pipelines.ui.detail.components.graph")

local NOW = 1761480000 -- 2025-10-26T12:00:00Z

local function job(id, name, status, extra)
	local j = { id = id, name = name, status = status, duration = 12 }
	for k, v in pairs(extra or {}) do
		j[k] = v
	end
	return j
end

local function pipeline(stages)
	return { id = "1", status = "running", stages = stages }
end

local function render(p, selected, width)
	return graph.render(p, { width = width or 140, now = NOW, selected_job_id = selected, focused = true, play_key = "p" })
end

--- Highlight groups covering the first occurrence of `needle` on `line`.
local function hl_at(result, row, needle)
	local line = result.lines[row + 1]
	local s = line:find(needle, 1, true)
	local groups = {}
	for _, span in ipairs(result.highlights) do
		if span.line == row and span.start_col <= s - 1 and span.end_col >= s - 1 + #needle then
			table.insert(groups, span.hl_group)
		end
	end
	return groups
end

local function has(list, value)
	for _, v in ipairs(list) do
		if v == value then
			return true
		end
	end
	return false
end

describe("atlas.pipelines.ui.detail.components.graph", function()
	it("draws stage headers, pills and a 2 -> 1 connector", function()
		local result = render(pipeline({
			{ name = "Validate", status = "success", jobs = { job("1", "yamllint", "success"), job("2", "ansible-lint", "success", { duration = 41 }) } },
			{ name = "Build", status = "success", jobs = { job("3", "build-agent-package", "success", { duration = 62 }) } },
		}), "3")
		assert.are.same({
			"Validate ✓                        Build ✓",
			"╭──────────────────────────╮      ┏━━━━━━━━━━━━━━━━━━━━━━━━━━┓",
			"│ ✓ yamllint           12s │───┬──┃ ✓ build-agent-pack… 1:02 ┃",
			"╰──────────────────────────╯   │  ┗━━━━━━━━━━━━━━━━━━━━━━━━━━┛",
			"╭──────────────────────────╮   │",
			"│ ✓ ansible-lint       41s │───┘",
			"╰──────────────────────────╯",
		}, result.lines)
		assert.equal(2, result.selected_row)
	end)

	it("draws manual jobs dashed with the play key and blocked ones dim", function()
		local result = render(pipeline({
			{
				name = "Deploy",
				status = "manual",
				jobs = {
					job("1", "deploy-staging", "manual", { manual = true, playable = true }),
					job("2", "deploy-prod", "created", { manual = true, playable = false }),
				},
			},
		}), nil)
		assert.are.same({
			"Deploy manual",
			"╭╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╮",
			"╎ ▶ deploy-staging  p play ╎",
			"╰╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╯",
			"╭╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╮",
			"╎ ⏸ deploy-prod    blocked ╎",
			"╰╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╯",
		}, result.lines)
		assert.truthy(has(hl_at(result, 1, "╭╌"), "AtlasYellow"))
		assert.truthy(has(hl_at(result, 2, " play"), "AtlasTextMuted"))
		local key_col = result.lines[3]:find("p play", 1, true) - 1
		local key_hl = false
		for _, span in ipairs(result.highlights) do
			if span.line == 2 and span.start_col == key_col and span.end_col == key_col + 1 then
				key_hl = span.hl_group == "AtlasKeyHint"
			end
		end
		assert.is_true(key_hl)
		assert.truthy(has(hl_at(result, 4, "╭╌"), "AtlasTextMuted"))
	end)

	it("colours the selected pill cyan in graph focus and bright otherwise", function()
		local p = pipeline({ { name = "Test", status = "running", jobs = { job("1", "pytest", "failed") } } })
		local focused = render(p, "1")
		assert.truthy(has(hl_at(focused, 1, "┏"), "AtlasCyan"))
		assert.truthy(has(hl_at(focused, 2, "pytest"), "AtlasBgHighlight"))
		local blurred = graph.render(p, { width = 140, now = NOW, selected_job_id = "1", focused = false })
		assert.truthy(has(hl_at(blurred, 1, "┏"), "AtlasTextBright"))
	end)

	it("marks an allowed failure with a yellow ! and a failure with a red ✗", function()
		local result = render(pipeline({
			{ name = "Test", status = "failed", jobs = { job("1", "lint", "failed", { allow_failure = true }), job("2", "unit", "failed") } },
		}), nil)
		assert.truthy(result.lines[3]:find("│ ! lint", 1, true))
		assert.truthy(has(hl_at(result, 2, "!"), "AtlasYellow"))
		assert.truthy(result.lines[6]:find("│ ✗ unit", 1, true))
		assert.truthy(has(hl_at(result, 5, "✗"), "AtlasRed"))
	end)

	it("connects 3 -> 3 jobs with crosses", function()
		local three = function(prefix)
			return { job(prefix .. "1", "a", "success"), job(prefix .. "2", "b", "success"), job(prefix .. "3", "c", "success") }
		end
		local result = render(pipeline({
			{ name = "A", status = "success", jobs = three("a") },
			{ name = "B", status = "success", jobs = three("b") },
		}), nil)
		assert.truthy(result.lines[3]:find("│───┬──│", 1, true))
		assert.truthy(result.lines[6]:find("│───┼──│", 1, true))
		assert.truthy(result.lines[9]:find("│───┴──│", 1, true))
	end)

	it("scrolls wide pipelines and shows how many stages are hidden", function()
		local stages = {}
		for i = 1, 8 do
			stages[i] = { name = "S" .. i, status = "success", jobs = { job(tostring(i), "job" .. i, "success") } }
		end
		local result = render(pipeline(stages), "6", 80)
		assert.equal(5, result.viewport.first)
		assert.truthy(result.lines[1]:find("^‹ 4 more"))
		assert.truthy(result.lines[1]:find("2 more ›$"))
		assert.truthy(result.lines[1]:find("S5", 1, true))
		assert.truthy(result.lines[1]:find("S6", 1, true))
		assert.falsy(result.lines[1]:find("S4", 1, true))
	end)

	it("says so when there are no jobs yet", function()
		assert.are.same({ "No jobs in this pipeline yet." }, render(pipeline({}), nil).lines)
	end)
end)
