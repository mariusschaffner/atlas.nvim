local detail_header = require("atlas.ui.components.detail_header")

local function base()
	return {
		breadcrumb = "atlas / semesterarbeit › pipelines › #12",
		meta_right = "opened by me · updated 2h ago",
		state_label = "Running",
		state_hl = "AtlasGLPipelineRunningPillChip",
		title = "Merge test into master",
		iid_text = "#12",
	}
end

local function spans_on(highlights, row)
	local out = {}
	for _, span in ipairs(highlights) do
		if span.line == row then
			table.insert(out, span)
		end
	end
	return out
end

local function text_of(line, span)
	return line:sub(span.start_col + 1, span.end_col)
end

describe("atlas.ui.components.detail_header", function()
	it("keeps the default ● pill glyph", function()
		local lines = detail_header.render(base(), 100)
		assert.truthy(lines[3]:find(" ● Running ", 1, true))
	end)

	it("uses state_icon for the pill glyph", function()
		local data = base()
		data.state_icon = "◐"
		local lines = detail_header.render(data, 100)
		assert.truthy(lines[3]:find(" ◐ Running ", 1, true))
	end)

	it("right-aligns title_right chunks against the box's right padding", function()
		local data = base()
		data.title_right = { { "3:05", "AtlasCyan" }, { " elapsed", "AtlasTextMuted" } }
		local lines, highlights = detail_header.render(data, 100)
		local title = lines[3]
		assert.truthy(title:find("3:05 elapsed  │$"))
		local cyan
		for _, span in ipairs(spans_on(highlights, 2)) do
			if span.hl_group == "AtlasCyan" then
				cyan = text_of(title, span)
			end
		end
		assert.equal("3:05", cyan)
		assert.equal(vim.api.nvim_strwidth(lines[1]), vim.api.nvim_strwidth(title))
	end)

	it("shortens the title to make room for title_right", function()
		local data = base()
		data.title = string.rep("very long title ", 10)
		data.title_right = { { "R retry failed   gX cancel", "AtlasKeyHint" } }
		local lines = detail_header.render(data, 80)
		assert.equal(80, vim.api.nvim_strwidth(lines[3]))
		assert.truthy(lines[3]:find("R retry failed   gX cancel  │$"))
	end)

	it("colours meta_right_chunks over the dim meta text", function()
		local data = base()
		data.meta_right = nil
		data.meta_right_chunks = { { "⎇ test", "AtlasCyan" }, { " · abc123 · " }, { "!36", "AtlasAccent" } }
		local lines, highlights = detail_header.render(data, 100)
		local top = lines[1]
		assert.truthy(top:find("⎇ test · abc123 · !36 ─╮$"))
		local colored = {}
		for _, span in ipairs(spans_on(highlights, 0)) do
			colored[span.hl_group] = colored[span.hl_group] or text_of(top, span)
		end
		assert.equal("⎇ test", colored.AtlasCyan)
		assert.equal("!36", colored.AtlasAccent)
	end)
end)
