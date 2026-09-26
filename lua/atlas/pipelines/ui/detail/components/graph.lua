-- Renders a pipeline's stages/jobs as a left-to-right graph of nested
-- bordered boxes (one box per stage, containing one stacked box per job),
-- connected by a dashed line -- e.g.:
--
--   ┌─ build ────────┐     ┌─ test ─────────┐
--   │┌───────────────┐│─────│┌───────────────┐│
--   ││ compile       ││     ││ unit          ││
--   │└───────────────┘│     │└───────────────┘│
--   └──────────────────┘     └──────────────────┘
--
-- Falls back to stacking stage boxes vertically when they don't fit
-- side-by-side in the available width.
local M = {}

local bordered_box = require("atlas.ui.components.bordered_box")
local utils = require("atlas.ui.shared.utils")

local CONNECTOR_WIDTH = 5
local CONNECTOR_ROW = 1 -- 0-indexed row (within a stage box's own output lines) the dashed connector aligns with.
local MIN_JOB_CONTENT_WIDTH = 8
local MAX_JOB_CONTENT_WIDTH = 24

local STATE_HL = {
	SUCCESSFUL = "AtlasTextPositive",
	FAILED = "AtlasLogError",
	INPROGRESS = "AtlasTextWarning",
	STOPPED = "AtlasTextMuted",
	UNKNOWN = "AtlasTextMuted",
}

---@param state PipelineState|nil
---@return string
function M.state_hl(state)
	return STATE_HL[tostring(state or "UNKNOWN"):upper()] or STATE_HL.UNKNOWN
end

---@param stage PipelineStage
---@return integer
local function stage_content_width(stage)
	local width = MIN_JOB_CONTENT_WIDTH
	for _, job in ipairs(stage.jobs or {}) do
		width = math.max(width, vim.fn.strdisplaywidth(tostring(job.name or "")))
	end
	return math.min(width, MAX_JOB_CONTENT_WIDTH)
end

---@param job PipelineJob
---@param content_width integer
---@return string[] lines
---@return table[] highlights
local function render_job_box(job, content_width)
	local box_width = content_width + 2
	return bordered_box.render({
		width = box_width,
		box_width = box_width,
		content_lines = { tostring(job.name or "") },
		border_hl = M.state_hl(job.state),
	})
end

---@param stage PipelineStage
---@return string[] lines
---@return table[] highlights
---@return integer width
local function render_stage_block(stage)
	local content_width = stage_content_width(stage)

	local content_lines, content_highlights = {}, {}
	if #(stage.jobs or {}) == 0 then
		content_lines = { "" }
	end
	for _, job in ipairs(stage.jobs or {}) do
		local job_lines, job_highlights = render_job_box(job, content_width)
		utils.append_block(content_lines, content_highlights, { lines = job_lines, highlights = job_highlights })
	end

	local job_box_width = content_width + 2
	local stage_box_width = job_box_width + 2
	local lines, highlights = bordered_box.render({
		width = stage_box_width,
		box_width = stage_box_width,
		title = tostring(stage.name or "Stage"),
		border_hl = "AtlasTextMuted",
		content_lines = content_lines,
		content_highlights = content_highlights,
	})

	return lines, highlights, stage_box_width
end

---@param blocks { lines: string[], highlights: table[], width: integer }[]
---@return string[] lines
---@return table[] highlights
local function join_horizontal(blocks)
	local max_height = 0
	for _, block in ipairs(blocks) do
		max_height = math.max(max_height, #block.lines)
	end

	local lines = {}
	for row = 1, max_height do
		lines[row] = ""
	end

	local highlights = {}
	local col_offset = 0

	for index, block in ipairs(blocks) do
		for row = 1, max_height do
			lines[row] = lines[row] .. (block.lines[row] or string.rep(" ", block.width))
		end
		for _, span in ipairs(block.highlights) do
			table.insert(
				highlights,
				{ line = span.line, start_col = col_offset + span.start_col, end_col = col_offset + span.end_col, hl_group = span.hl_group }
			)
		end
		col_offset = col_offset + block.width

		if index < #blocks then
			local connector = string.rep("─", CONNECTOR_WIDTH)
			local blank = string.rep(" ", CONNECTOR_WIDTH)
			for row = 1, max_height do
				lines[row] = lines[row] .. ((row - 1 == CONNECTOR_ROW) and connector or blank)
			end
			if CONNECTOR_ROW + 1 <= max_height then
				table.insert(
					highlights,
					{ line = CONNECTOR_ROW, start_col = col_offset, end_col = col_offset + CONNECTOR_WIDTH, hl_group = "AtlasTextMuted" }
				)
			end
			col_offset = col_offset + CONNECTOR_WIDTH
		end
	end

	return lines, highlights
end

---@param pipeline Pipeline
---@param width integer
---@return string[] lines
---@return table[] highlights
function M.render(pipeline, width)
	local stages = pipeline.stages or {}
	if #stages == 0 then
		return { "", "  No stages available." }, {}
	end

	local blocks = {}
	local total_width = 0
	for index, stage in ipairs(stages) do
		local lines, highlights, block_width = render_stage_block(stage)
		table.insert(blocks, { lines = lines, highlights = highlights, width = block_width })
		total_width = total_width + block_width + (index < #stages and CONNECTOR_WIDTH or 0)
	end

	if total_width <= width then
		return join_horizontal(blocks)
	end

	local lines, highlights = {}, {}
	for _, block in ipairs(blocks) do
		utils.append_block(lines, highlights, { lines = block.lines, highlights = block.highlights })
		table.insert(lines, "")
	end
	return lines, highlights
end

return M
