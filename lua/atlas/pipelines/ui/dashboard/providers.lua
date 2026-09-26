local M = {}

local icons = require("atlas.ui.shared.icons")
local highlights = require("atlas.ui.shared.highlights")

local STAGE_GLYPH = "■"

---@return table[]
function M.columns()
	return {
		{ key = "id", name = "Pipeline", can_grow = false },
		{ key = "branch", name = string.format("%s Branch", icons.pulls("branch")), max_width = 24, can_grow = false },
		{ key = "commit", name = "Commit", can_grow = false },
		{ key = "creator", name = string.format("%s Creator", icons.general("user")), max_width = 20, can_grow = false },
		{ key = "stages", name = "Stages" },
		{ key = "status", name = " Status", can_grow = false },
	}
end

---@param pipeline Pipeline
---@return string
local function stages_value(pipeline)
	local parts = {}
	for _ in ipairs(pipeline.stages or {}) do
		table.insert(parts, STAGE_GLYPH)
	end
	return table.concat(parts, " ")
end

---@param pipeline Pipeline
---@return string
local function status_value(pipeline)
	local icon = icons.pulls_status(tostring(pipeline.state or "unknown"):lower())
	return string.format(" %s %s", icon, tostring(pipeline.status or ""))
end

---@param pipeline Pipeline
---@return table
function M.values(pipeline)
	return {
		id = "#" .. tostring(pipeline.id or ""),
		branch = tostring(pipeline.ref or ""),
		commit = tostring(pipeline.short_sha or pipeline.sha or ""),
		creator = (pipeline.user and pipeline.user.name and pipeline.user.name ~= "") and pipeline.user.name or "Unknown",
		stages = stages_value(pipeline),
		status = status_value(pipeline),
	}
end

---@param table_row table
---@param col table
---@param ctx { text: string, padded: string, width: integer }
---@return table[]|nil
function M.highlights(table_row, col, ctx)
	---@type Pipeline|nil
	local pipeline = table_row._pipeline
	if pipeline == nil then
		return nil
	end

	if col.key == "branch" then
		local hl = highlights.dynamic_for(pipeline.ref) or "AtlasTextMuted"
		return { { start_col = 0, end_col = #ctx.padded, hl_group = hl } }
	end

	if col.key == "commit" then
		return { { start_col = 0, end_col = #ctx.padded, hl_group = "AtlasTextMuted" } }
	end

	if col.key == "creator" then
		local identifier = pipeline.user and (pipeline.user.username or pipeline.user.name) or nil
		local hl = highlights.dynamic_for(identifier) or "AtlasTextMuted"
		return { { start_col = 0, end_col = #ctx.padded, hl_group = hl } }
	end

	if col.key == "stages" then
		local spans, cursor = {}, 0
		for _, stage in ipairs(pipeline.stages or {}) do
			local _, hl = icons.pulls_status(tostring(stage.state or "unknown"):lower())
			local start_col, end_col = ctx.text:find(STAGE_GLYPH, cursor + 1, true)
			if start_col then
				table.insert(spans, { start_col = start_col - 1, end_col = end_col, hl_group = hl })
				cursor = end_col
			end
		end
		return #spans > 0 and spans or nil
	end

	if col.key == "status" then
		local _, hl = icons.pulls_status(tostring(pipeline.state or "unknown"):lower())
		return { { start_col = 0, end_col = #ctx.padded, hl_group = hl } }
	end

	return nil
end

return M
