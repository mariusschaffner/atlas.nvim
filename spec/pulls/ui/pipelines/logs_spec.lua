local logs = require("atlas.pulls.ui.pipelines.logs")

describe("atlas.pulls.ui.pipelines.logs.clean_lines", function()
	it("strips a leading UTF-8 BOM", function()
		assert.same({ "hello" }, logs.clean_lines("\239\187\191hello"))
	end)

	it("normalizes CRLF line endings", function()
		assert.same({ "one", "two" }, logs.clean_lines("one\r\ntwo"))
	end)

	it("strips SGR/CSI color and cursor sequences", function()
		assert.same({ "hello world" }, logs.clean_lines("\27[31mhello\27[0m \27[1mworld\27[0m"))
	end)

	it("strips OSC hyperlink sequences terminated by BEL", function()
		assert.same({ "click me" }, logs.clean_lines("\27]8;;https://example.com\7click me\27]8;;\7"))
	end)

	it("strips a dangling CSI sequence left at end of line by a split redraw", function()
		assert.same({ "done" }, logs.clean_lines("\27[0Kdone"))
	end)

	it("leaves a bare mid-line CR untouched (collapsed later, in M.parse)", function()
		assert.same({ "10%\r55%\r100%" }, logs.clean_lines("10%\r55%\r100%"))
	end)

	it("drops a single trailing empty line but keeps intentional blank lines", function()
		assert.same({ "a", "", "b" }, logs.clean_lines("a\n\nb\n"))
	end)

	it("returns an empty list for an empty trace", function()
		assert.same({}, logs.clean_lines(""))
	end)
end)

describe("atlas.pulls.ui.pipelines.logs.parse carriage-return collapsing", function()
	it("collapses a bare-CR progress redraw to its last segment", function()
		assert.same({ { kind = "line", text = "100%" } }, logs.parse("10%\r55%\r100%\n"))
	end)
end)

describe("atlas.pulls.ui.pipelines.logs.parse stream coalescing", function()
	it("joins consecutive same-stream '+' continuations into one line", function()
		local entries = logs.parse("00O Compil\n00O+ing\n")
		assert.same({ { kind = "line", text = "Compiling" } }, entries)
	end)

	it("starts a new line on a space-separated frame for the same stream", function()
		local entries = logs.parse("00O first\n00O second\n")
		assert.same({
			{ kind = "line", text = "first" },
			{ kind = "line", text = "second" },
		}, entries)
	end)

	it("keeps separate streams independent", function()
		local entries = logs.parse("00O out\n01E err\n00O+put\n")
		assert.same({
			{ kind = "line", text = "output" },
			{ kind = "line", text = "err" },
		}, entries)
	end)
end)

describe("atlas.pulls.ui.pipelines.logs.parse GitLab sections", function()
	it("groups lines between section_start/section_end and computes duration", function()
		local raw = table.concat({
			"section_start:1000:build_image\r\27[0KBuilding image",
			"Step 1/3",
			"section_end:1010:build_image",
			"done",
		}, "\n")

		local entries = logs.parse(raw)

		assert.equal(2, #entries)
		assert.equal("group", entries[1].kind)
		assert.equal("Building image", entries[1].name)
		assert.equal("build_image", entries[1].key)
		assert.equal(10, entries[1].duration)
		assert.same({ { kind = "line", text = "Step 1/3" } }, entries[1].entries)
		assert.same({ kind = "line", text = "done" }, entries[2])
	end)

	it("falls back to the section key as the name when no title follows the CR", function()
		local entries = logs.parse("section_start:1000:setup\nsection_end:1005:setup\n")
		assert.equal("setup", entries[1].name)
	end)

	it("supports nested sections", function()
		local raw = table.concat({
			"section_start:1000:outer\rOuter",
			"section_start:1001:inner\rInner",
			"inner line",
			"section_end:1002:inner",
			"outer line",
			"section_end:1005:outer",
		}, "\n")

		local entries = logs.parse(raw)
		assert.equal(1, #entries)
		local outer = entries[1]
		assert.equal("Outer", outer.name)
		assert.equal(5, outer.duration)
		assert.equal("group", outer.entries[1].kind)
		assert.equal("Inner", outer.entries[1].name)
		assert.equal(1, outer.entries[1].duration)
		assert.same({ { kind = "line", text = "inner line" } }, outer.entries[1].entries)
		assert.same({ kind = "line", text = "outer line" }, outer.entries[2])
	end)

	it("drops an unmatched section_end instead of corrupting the stack or showing raw marker text", function()
		local raw = table.concat({
			"section_start:1000:a\rA",
			"section_end:1010:not_open",
			"line inside a",
			"section_end:1020:a",
		}, "\n")

		local entries = logs.parse(raw)
		assert.equal(1, #entries)
		assert.equal("A", entries[1].name)
		assert.equal(20, entries[1].duration)
		assert.same({ { kind = "line", text = "line inside a" } }, entries[1].entries)
	end)

	it("recovers a title split into its own stream-continuation frame with no real newline between markers", function()
		-- Reproduces a real GitLab trace: every line (control lines included)
		-- carries a leading ISO-8601 timestamp, and a `section_end`/
		-- `section_start` pair emitted back to back arrives as a single
		-- stream's "+"-continuation with no `\r`/`\n` of its own -- exactly
		-- the shape that used to leak raw `section_start:`/`section_end:`
		-- text and misclassify the whole job log as a (grey) header line.
		local raw = table.concat({
			"2026-08-17T10:03:33.152370Z 00O Running with gitlab-runner 18.7.0",
			"2026-08-17T10:03:33.152896Z 00O section_start:1786961013:prepare_executor",
			'2026-08-17T10:03:33.152896Z 00O+Preparing the "shell" executor',
			"2026-08-17T10:03:33.153969Z 00O Using Shell (powershell) executor...",
			"2026-08-17T10:03:33.153969Z 00O section_end:1786961013:prepare_executor",
			"2026-08-17T10:03:33.153969Z 00O+section_start:1786961013:prepare_script",
			"2026-08-17T10:03:33.155027Z 00O+Preparing environment",
			"2026-08-17T10:03:34.487210Z 00O section_end:1786961014:prepare_script",
			"",
		}, "\n")

		local flat = logs.flatten(logs.parse(raw))

		for _, line in ipairs(flat) do
			assert.is_nil(line:match("section_start:"))
			assert.is_nil(line:match("section_end:"))
			if not line:match("^▸") then
				assert.are_not.equal("AtlasColumnHeader", logs.classify_log_line(line))
			end
		end

		local joined = table.concat(flat, "\n")
		assert.truthy(joined:find('Preparing the "shell" executor', 1, true))
		assert.truthy(joined:find("Preparing environment", 1, true))
		assert.truthy(joined:find("Running with gitlab%-runner 18%.7%.0"))
	end)
end)

describe("atlas.pulls.ui.pipelines.logs.flatten", function()
	it("renders a group as one header line followed by its indented children", function()
		local entries = logs.parse("section_start:1000:build\rBuild\nStep 1\nsection_end:1005:build\n")
		assert.same({ "▸ Build (5s)", "  Step 1" }, logs.flatten(entries))
	end)

	it("leaves plain (non-sectioned) logs looking exactly as before", function()
		local entries = logs.parse("line one\nline two\n")
		assert.same({ "line one", "line two" }, logs.flatten(entries))
	end)
end)

describe("atlas.pulls.ui.pipelines.logs.classify_log_line", function()
	it("classifies an error line", function()
		assert.equal("AtlasLogError", logs.classify_log_line("error: build failed"))
	end)

	it("classifies a flattened section header", function()
		assert.equal("AtlasColumnHeader", logs.classify_log_line("▸ Build (5s)"))
	end)

	it("returns nil for an ordinary line", function()
		assert.is_nil(logs.classify_log_line("just some output"))
	end)
end)

describe("atlas.pulls.ui.pipelines.logs keep_ansi", function()
	it("keeps SGR sequences but still strips cursor/erase sequences", function()
		assert.same({ "\27[31mred\27[0m done" }, logs.clean_lines("\27[0K\27[31mred\27[0m\27[2K done", { keep_ansi = true }))
	end)

	it("leaves the default path stripping everything", function()
		assert.same({ "red done" }, logs.clean_lines("\27[0K\27[31mred\27[0m\27[2K done"))
	end)

	it("recognises section markers behind a kept reset sequence", function()
		local entries = logs.parse(
			"section_start:1:build\r\27[0K\27[36;1mBuild\27[0;m\nmake\n\27[0;msection_end:4:build\r\27[0K\n",
			{ keep_ansi = true }
		)
		assert.equal(1, #entries)
		assert.equal("group", entries[1].kind)
		assert.equal(3, entries[1].duration)
		assert.equal("\27[36;1mBuild\27[0;m", entries[1].name)
		assert.same({ { kind = "line", text = "make" } }, entries[1].entries)
	end)
end)

describe("atlas.pulls.ui.pipelines.logs.ansi_spans", function()
	it("returns plain lines unchanged", function()
		assert.same({ "plain", {} }, { logs.ansi_spans("plain") })
	end)

	it("maps foreground colours to highlight groups", function()
		local text, spans = logs.ansi_spans("\27[32mok\27[0m and \27[91mfail\27[0m")
		assert.equal("ok and fail", text)
		assert.same({
			{ start_col = 0, end_col = 2, hl_group = "AtlasGreen" },
			{ start_col = 7, end_col = 11, hl_group = "AtlasRed" },
		}, spans)
	end)

	it("treats bold without a colour as bright and ignores backgrounds and 256 colours", function()
		local text, spans = logs.ansi_spans("\27[1mbold\27[22m \27[38;5;208;44mx\27[0m")
		assert.equal("bold x", text)
		assert.same({ { start_col = 0, end_col = 4, hl_group = "AtlasTextBright" } }, spans)
	end)

	it("merges adjacent runs of the same colour", function()
		local _, spans = logs.ansi_spans("\27[33mab\27[33mcd\27[0m")
		assert.same({ { start_col = 0, end_col = 4, hl_group = "AtlasYellow" } }, spans)
	end)
end)
