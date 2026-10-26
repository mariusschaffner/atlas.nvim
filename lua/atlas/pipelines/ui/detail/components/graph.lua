-- The pipeline graph (DESIGN-pipeline-view.md §3), drawn on the shared strip
-- cell canvas. One column per stage with its header row, a 3-row pill per job,
-- and stage-to-stage connectors in the gaps:
--
--   Validate ✓ 53s                  Build ✓ 1:02
--   ╭──────────────────────────╮    ╭──────────────────────────╮
--   │ ✓ yamllint           12s │───┬──│ ✓ build-agent-pac…  1:02 │
--   ╰──────────────────────────╯   │  ╰──────────────────────────╯
--   ╭──────────────────────────╮   │
--   │ ✓ ansible-lint       41s │───┘
--   ╰──────────────────────────╯
--
-- Pure: returns lines + highlight spans; geometry lives in `graph_layout`.
local M = {}

local strip = require("atlas.ui.components.strip")
local layout = require("atlas.pipelines.ui.detail.graph_layout")
local status = require("atlas.pipelines.status")

local BORDERS = {
	solid = { tl = "╭", tr = "╮", bl = "╰", br = "╯", h = "─", v = "│" },
	dashed = { tl = "╭", tr = "╮", bl = "╰", br = "╯", h = "╌", v = "╎" },
	selected = { tl = "┏", tr = "┓", bl = "┗", br = "┛", h = "━", v = "┃" },
}

---@class AtlasPipelineGraphOpts
---@field width integer
---@field now integer Epoch seconds (running durations).
---@field selected_job_id string|nil
---@field focused boolean The graph (not the log) has the keys: selected pill in cyan.
---@field play_key string|nil Display key for "p play" on manual jobs.
---@field prev_first integer|nil Previous viewport start, for stable scrolling.

---@class AtlasPipelineGraphResult
---@field lines string[]
---@field highlights AtlasUIHighlight[]
---@field viewport AtlasPipelineViewport
---@field selected_row integer|nil 0-based middle row of the selected pill.

--- Index of the stage holding `job_id` (1 when not found).
---@param stages PipelineGraphStage[]
---@param job_id string|nil
---@return integer stage_index
---@return integer job_index
function M.locate(stages, job_id)
	for i, stage in ipairs(stages or {}) do
		for j, job in ipairs(stage.jobs or {}) do
			if job.id == job_id then
				return i, j
			end
		end
	end
	return 1, 0
end

--- A canvas of rows, each with its own highlight ranges (in columns).
---@param width integer
---@param height integer
local function canvas(width, height)
	local rows, ranges = {}, {}
	for r = 0, height - 1 do
		rows[r] = strip.cells(width)
		ranges[r] = {}
	end
	local c = {}
	function c.text(row, col, text, hl)
		if rows[row] == nil or text == "" then
			return
		end
		strip.set_text(rows[row], col, text)
		if hl then
			table.insert(ranges[row], { from = col, to = col + strip.width(text), hl = hl })
		end
	end
	function c.hl(row, from, to, hl)
		if rows[row] and to > from then
			table.insert(ranges[row], { from = from, to = to, hl = hl })
		end
	end
	function c.finish()
		local lines, spans = {}, {}
		for r = 0, height - 1 do
			local line, byte_range = strip.finalize(rows[r])
			lines[#lines + 1] = (line:gsub("%s+$", ""))
			for _, range in ipairs(ranges[r]) do
				local s, e = byte_range(range.from, range.to)
				e = math.min(e, #lines[#lines])
				if e > s then
					table.insert(spans, { line = r, start_col = s, end_col = e, hl_group = range.hl })
				end
			end
		end
		return lines, spans
	end
	return c
end

---@param c table canvas
---@param x integer
---@param stage PipelineGraphStage
---@param now integer
local function draw_stage_header(c, x, stage, now)
	local summary = status.stage_summary(stage, now)
	local chunks = { { stage.name, summary.name_hl } }
	if summary.icon then
		table.insert(chunks, { " " .. summary.icon, summary.icon_hl })
	end
	if summary.right_text ~= "" then
		table.insert(chunks, { " " .. summary.right_text, "AtlasTextMuted" })
	end
	local col = x
	for _, chunk in ipairs(strip.truncate_chunks(chunks, layout.COL_W)) do
		c.text(0, col, chunk[1], chunk[2])
		col = col + strip.width(chunk[1])
	end
end

---@param c table canvas
---@param x integer
---@param row integer Top border row.
---@param job PipelineGraphJob
---@param opts AtlasPipelineGraphOpts
local function draw_pill(c, x, row, job, opts)
	local badge = status.job_badge(job, opts.now)
	local selected = job.id == opts.selected_job_id
	local style = selected and BORDERS.selected or BORDERS[badge.border]
	local border_hl = badge.border_hl
	if selected then
		border_hl = opts.focused and "AtlasCyan" or "AtlasTextBright"
	end
	local inner = layout.COL_W - 2

	c.text(row, x, style.tl .. string.rep(style.h, inner) .. style.tr, border_hl)
	c.text(row + 2, x, style.bl .. string.rep(style.h, inner) .. style.br, border_hl)
	c.text(row + 1, x, style.v, border_hl)
	c.text(row + 1, x + layout.COL_W - 1, style.v, border_hl)
	if selected then
		c.hl(row + 1, x + 1, x + layout.COL_W - 1, "AtlasBgHighlight")
	end

	-- Right-hand text: duration / "blocked", or "<key> play" on manual jobs.
	local right = {}
	if badge.kind == "manual" and opts.play_key then
		right = { { opts.play_key, "AtlasKeyHint" }, { " play", "AtlasTextMuted" } }
	elseif badge.right_text ~= "" then
		right = { { badge.right_text, selected and badge.kind == "running" and "AtlasCyan" or badge.right_hl } }
	end
	local right_w = strip.chunks_width(right)

	-- "│ ✓ name…        12s │"
	local col = x + 2
	c.text(row + 1, col, badge.icon, badge.icon_hl)
	col = col + 2
	local name_room = inner - 4 - (right_w > 0 and right_w + 1 or 0)
	local name_hl = badge.name_hl or (selected and "AtlasTextBright" or nil)
	c.text(row + 1, col, strip.truncate(job.name, name_room), name_hl)
	col = x + layout.COL_W - 2 - right_w
	for _, chunk in ipairs(right) do
		c.text(row + 1, col, chunk[1], chunk[2])
		col = col + strip.width(chunk[1])
	end
end

--- Renders the graph for the visible stages.
---@param pipeline PipelineGraph
---@param opts AtlasPipelineGraphOpts
---@return AtlasPipelineGraphResult
function M.render(pipeline, opts)
	local stages = pipeline.stages or {}
	if #stages == 0 then
		local text = "No jobs in this pipeline yet."
		return {
			lines = { text },
			highlights = { { line = 0, start_col = 0, end_col = #text, hl_group = "AtlasTextMuted" } },
			viewport = layout.viewport(0, opts.width, 1, nil),
		}
	end

	local selected_stage, selected_job = M.locate(stages, opts.selected_job_id)
	local vp = layout.viewport(#stages, opts.width, selected_stage, opts.prev_first)
	local max_jobs = 0
	for i = vp.first, vp.last do
		max_jobs = math.max(max_jobs, #(stages[i].jobs or {}))
	end
	local c = canvas(opts.width, layout.height(max_jobs))

	for i = vp.first, vp.last do
		local stage = stages[i]
		local x = vp.offset + (i - vp.first) * (layout.COL_W + layout.GAP)
		draw_stage_header(c, x, stage, opts.now)
		for j, job in ipairs(stage.jobs or {}) do
			draw_pill(c, x, layout.pill_row(j), job, opts)
		end
		if i < vp.last then
			local gap_x = x + layout.COL_W
			for row, text in pairs(layout.connector(#(stage.jobs or {}), #(stages[i + 1].jobs or {}))) do
				c.text(row, gap_x, text, "AtlasBorder")
			end
		end
	end

	if vp.hidden_left > 0 then
		c.text(0, 0, string.format("‹ %d more", vp.hidden_left), "AtlasTextMuted")
	end
	if vp.hidden_right > 0 then
		local text = string.format("%d more ›", vp.hidden_right)
		c.text(0, opts.width - strip.width(text), text, "AtlasTextMuted")
	end

	local lines, spans = c.finish()
	return {
		lines = lines,
		highlights = spans,
		viewport = vp,
		selected_row = selected_job > 0 and layout.mid_row(selected_job) or nil,
	}
end

return M
