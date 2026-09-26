local M = {}

local state = require("atlas.pipelines.state")
local table_tree = require("atlas.ui.components.table_tree")
local utils = require("atlas.ui.shared.utils")
local providers = require("atlas.pipelines.ui.dashboard.providers")

---@param pipeline Pipeline
---@return table
local function pipeline_to_row(pipeline)
	local row = providers.values(pipeline)
	row._item = { kind = "pipeline", key = pipeline.key, _pipeline = pipeline }
	row._pipeline = pipeline
	return row
end

---@param row table
---@param col table
---@param ctx { text: string, padded: string, width: integer }
---@return table[]|nil
local function cell_hl(row, col, ctx)
	return providers.highlights(row, col, ctx)
end

---@param opts { width: integer, height: integer|nil }
---@return string[], table[], table<integer, table>, table|nil
function M.render(opts)
	local lines, spans = {}, {}
	local line_map = {}

	if state.error then
		local err_text = "Error: " .. state.error
		utils.append_block(lines, spans, {
			lines = { err_text },
			highlights = { { line = 0, start_col = 0, end_col = #err_text, hl_group = "AtlasLogError" } },
		})
		state.total_pages = 1
		return lines, spans, line_map
	end

	local pipelines = state.pipelines
	if state.is_loading ~= true and #pipelines == 0 then
		table.insert(lines, "No pipelines found.")
		state.total_pages = 1
		return lines, spans, line_map
	end

	local rows = {}
	for _, pipeline in ipairs(pipelines) do
		table.insert(rows, pipeline_to_row(pipeline))
	end
	if state.is_loading then
		table.insert(rows, { id = "", branch = "", commit = "", creator = "", stages = "", status = "Loading..." })
	end

	local tbl_lines, tbl_map, tbl_spans, page_info = table_tree.render({
		width = opts.width,
		margin = 1,
		columns = providers.columns(),
		rows = rows,
		header_separator = true,
		max_rows = opts.height,
		page = state.page,
		cell_hl = cell_hl,
	})

	local table_base = #lines
	utils.append_block(lines, spans, { lines = tbl_lines, highlights = tbl_spans })
	for lnum, node in pairs(tbl_map) do
		line_map[table_base + lnum] = node
	end

	state.page = page_info and page_info.page or 1
	state.total_pages = page_info and page_info.total_pages or 1

	return lines, spans, line_map, page_info
end

return M
