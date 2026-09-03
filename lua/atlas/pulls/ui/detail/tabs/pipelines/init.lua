local M = {}

local utils = require("atlas.ui.shared.utils")
local icons = require("atlas.ui.shared.icons")
local spinner = require("atlas.ui.components.spinner")
local table_tree = require("atlas.ui.components.table_tree")
local pipeline_logs = require("atlas.pulls.ui.pipelines.logs")
local state = require("atlas.pulls.ui.detail.tabs.pipelines.state")
local detail = require("atlas.pulls.ui.detail.state")
local keymaps = require("atlas.pulls.ui.detail.tabs.pipelines.keymaps")

local PADDING_X = 1
local PADDING = string.rep(" ", PADDING_X)

---@type fun()|nil
local current_refresh = nil

local PIPELINE_HL = {
	SUCCESSFUL = "AtlasPipelineLinkSuccess",
	FAILED = "AtlasPipelineLinkFailed",
	INPROGRESS = "AtlasPipelineLinkInProgress",
	STOPPED = "AtlasPipelineLinkMuted",
}

local PIPELINE_STATUS_LABEL = {
	SUCCESSFUL = "Passed",
	FAILED = "Failed",
	INPROGRESS = "Running",
	STOPPED = "Stopped",
}

local PIPELINE_STATUS_PRIORITY = {
	FAILED = 1,
	INPROGRESS = 2,
	STOPPED = 3,
	UNKNOWN = 4,
	SUCCESSFUL = 5,
}

---@param status string
---@return string
local function status_label(status)
	return PIPELINE_STATUS_LABEL[tostring(status or ""):upper()] or "Unknown"
end

---@generic T: { state: string }
---@param items T[]
---@return T[]
local function sort_by_status(items)
	local indexed = {}
	for index, item in ipairs(items) do
		table.insert(indexed, { item = item, index = index })
	end
	table.sort(indexed, function(a, b)
		local a_state = tostring(a.item.state or "UNKNOWN"):upper()
		local b_state = tostring(b.item.state or "UNKNOWN"):upper()
		local a_priority = PIPELINE_STATUS_PRIORITY[a_state] or PIPELINE_STATUS_PRIORITY.UNKNOWN
		local b_priority = PIPELINE_STATUS_PRIORITY[b_state] or PIPELINE_STATUS_PRIORITY.UNKNOWN
		if a_priority == b_priority then
			return a.index < b.index
		end
		return a_priority < b_priority
	end)

	local sorted = {}
	for _, entry in ipairs(indexed) do
		table.insert(sorted, entry.item)
	end
	return sorted
end

---@param seconds number|nil
---@return string
local function duration_text(seconds)
	local value = tonumber(seconds)
	if value == nil then
		return ""
	end
	if value < 60 then
		return string.format("%ds", math.floor(value))
	end
	return utils.human_duration(value)
end

---@param id string
---@return PullsPipeline|nil
local function find_pipeline(id)
	if type(detail.pipelines) ~= "table" then
		return nil
	end
	for _, pipeline in ipairs(detail.pipelines) do
		if tostring(pipeline.id) == id then
			return pipeline
		end
	end
	return nil
end

---@param pipeline PullsPipeline
---@return string
local function stages_preview(pipeline)
	local parts = {}
	for _, stage in ipairs(pipeline.stages) do
		local stage_state = tostring(stage.state or "UNKNOWN"):upper()
		local stage_icon = icons.pulls_status(stage_state:lower())
		table.insert(parts, stage_icon)
	end
	return table.concat(parts, " ")
end

---@param pr PullRequest
---@param pipeline PullsPipeline
local function ensure_pipeline_details(pr, pipeline)
	local id = tostring(pipeline.id)
	local cached = state.details_by_id[id]
	if cached ~= nil then
		return
	end

	local pipelines_api = detail.provider and detail.provider.capabilities.pipelines
	if not pipelines_api or not pipelines_api.fetch_details then
		state.details_by_id[id] = "Pipeline job details are not supported by this provider"
		return
	end

	state.details_by_id[id] = "loading"
	state.requests.run(function(done)
		return pipelines_api.fetch_details(pr, pipeline, {}, done)
	end, function(result, err)
		if state.selected_pipeline_id ~= id then
			return
		end
		state.details_by_id[id] = err and ("Failed to load jobs: " .. tostring(err)) or (result or pipeline)
		if current_refresh then
			current_refresh()
		end
	end)
end

---@param pr PullRequest
---@param pipeline PullsPipeline|nil
---@param job PullsPipelineJob
local function ensure_job_log(pr, pipeline, job)
	local id = tostring(job.id)
	if state.log_by_job_id[id] ~= nil then
		return
	end

	local pipelines_api = detail.provider and detail.provider.capabilities.pipelines
	if not pipelines_api or not pipelines_api.fetch_job_log then
		state.log_by_job_id[id] = { status = "error", text = "Job logs are not supported by this provider" }
		return
	end

	state.log_by_job_id[id] = { status = "loading" }
	state.requests.run(function(done)
		return pipelines_api.fetch_job_log(pr, pipeline, job, done)
	end, function(log, err)
		if state.selected_job == nil or tostring(state.selected_job.id) ~= id then
			return
		end
		if err then
			state.log_by_job_id[id] = { status = "error", text = "Failed to load job logs: " .. tostring(err) }
		else
			state.log_by_job_id[id] = { status = "loaded", text = tostring(log or "") }
		end
		if current_refresh then
			current_refresh()
		end
	end)
end

---@param width integer
---@param lines string[]
---@param spans table[]
---@param line_map table<integer, table>
local function render_pipeline_list(width, lines, spans, line_map)
	if detail.pipelines == nil or detail.pipelines == "loading" then
		utils.push(lines, spans, spinner.with_text("Loading pipelines..."), "AtlasTextMuted", PADDING_X)
		return
	end

	if type(detail.pipelines) == "string" then
		utils.push(lines, spans, detail.pipelines, "AtlasLogError", PADDING_X)
		return
	end

	local entries = sort_by_status(detail.pipelines)
	if #entries == 0 then
		utils.push(lines, spans, "No pipelines found.", "AtlasTextMuted", PADDING_X)
		return
	end

	local rows = {}
	for _, pipeline in ipairs(entries) do
		local state_value = tostring(pipeline.state or "UNKNOWN"):upper()
		local icon = icons.pulls_status(state_value:lower())
		local job_count = tonumber(pipeline.job_count)
		table.insert(rows, {
			label = pipeline.name,
			status = string.format("%s %s", icon, status_label(state_value)),
			status_hl = PIPELINE_HL[state_value] or "AtlasPipelineLinkMuted",
			stages = stages_preview(pipeline),
			jobs = job_count and string.format("%d %s", job_count, job_count == 1 and "job" or "jobs") or "",
			kind = "pipeline",
			pipeline = pipeline,
			separator = true,
		})
	end

	local box_lines, box_lmap, box_spans = table_tree.render({
		width = width,
		margin = PADDING_X,
		columns = {
			{ key = "label", name = "Pipeline", can_grow = true, header_hl = "AtlasColumnHeader" },
			{ key = "status", name = "Status", can_grow = false, header_hl = "AtlasColumnHeader" },
			{ key = "stages", name = "Stages", can_grow = false, header_hl = "AtlasColumnHeader" },
			{ key = "jobs", name = "Jobs", can_grow = false, header_hl = "AtlasColumnHeader" },
		},
		rows = rows,
		cell_hl = function(row, column, ctx)
			if column.key == "status" then
				return { { start_col = 0, end_col = #ctx.padded, hl_group = row.status_hl } }
			end
			if column.key == "stages" or column.key == "jobs" then
				return { { start_col = 0, end_col = #ctx.padded, hl_group = "AtlasTextMuted" } }
			end
		end,
	})

	local offset = #lines
	utils.append_block(lines, spans, { lines = box_lines, highlights = box_spans })
	for lnum, entry in pairs(box_lmap) do
		line_map[offset + lnum] = entry
	end
end

---@param pr PullRequest
---@param width integer
---@param lines string[]
---@param spans table[]
---@param line_map table<integer, table>
local function render_job_list(pr, width, lines, spans, line_map)
	local id = state.selected_pipeline_id
	local pipeline = id and find_pipeline(id) or nil
	if pipeline == nil then
		utils.push(lines, spans, "Pipeline not found.", "AtlasTextMuted", PADDING_X)
		return
	end

	ensure_pipeline_details(pr, pipeline)

	local state_value = tostring(pipeline.state or "UNKNOWN"):upper()
	local icon = icons.pulls_status(state_value:lower())
	local header = string.format("%s%s %s  %s", PADDING, icon, pipeline.name, status_label(state_value))
	table.insert(lines, header)
	table.insert(spans, {
		line = #lines - 1,
		start_col = PADDING_X,
		end_col = PADDING_X + #icon,
		hl_group = PIPELINE_HL[state_value] or "AtlasPipelineLinkMuted",
	})
	table.insert(lines, "")

	local detailed = state.details_by_id[id]
	if detailed == nil or detailed == "loading" then
		utils.push(lines, spans, spinner.with_text("Loading jobs..."), "AtlasTextMuted", PADDING_X)
		return
	end
	if type(detailed) == "string" then
		utils.push(lines, spans, detailed, "AtlasLogError", PADDING_X)
		return
	end

	local rows = {}
	for _, stage in ipairs(sort_by_status(detailed.stages)) do
		if #stage.jobs > 0 then
			local stage_state = tostring(stage.state or "UNKNOWN"):upper()
			local stage_icon = icons.pulls_status(stage_state:lower())
			local stage_row = {
				label = stage.name or "Stage",
				status = "",
				status_icon = stage_icon,
				status_hl = PIPELINE_HL[stage_state] or "AtlasPipelineLinkMuted",
				kind = "stage",
				children = {},
			}
			for _, job in ipairs(sort_by_status(stage.jobs)) do
				local job_state = tostring(job.state or "UNKNOWN"):upper()
				local job_icon = icons.pulls_status(job_state:lower())
				table.insert(stage_row.children, {
					label = string.format("%s %s", job_icon, job.name),
					status = duration_text(job.duration),
					status_icon = job_icon,
					status_hl = PIPELINE_HL[job_state] or "AtlasPipelineLinkMuted",
					kind = "job",
					job = job,
					stage = stage,
					pipeline = pipeline,
				})
			end
			table.insert(rows, stage_row)
		end
	end

	if #rows == 0 then
		utils.push(lines, spans, "No jobs found.", "AtlasTextMuted", PADDING_X)
		return
	end

	local box_lines, box_lmap, box_spans = table_tree.render({
		width = width,
		margin = PADDING_X,
		show_header = false,
		column_gap = 1,
		columns = {
			{ key = "label", name = "", can_grow = true },
			{ key = "status", name = "", can_grow = false },
		},
		rows = rows,
		tree = {
			column_key = "label",
			children_key = "children",
			default_expanded = true,
			show_indicator = false,
			leaf_prefix = "",
			is_expanded = function()
				return true
			end,
		},
		cell_hl = function(row, column, ctx)
			if column.key == "label" and row.status_icon then
				local start_col = ctx.text:find(row.status_icon, 1, true)
				if start_col then
					return {
						{ start_col = start_col - 1, end_col = start_col - 1 + #row.status_icon, hl_group = row.status_hl },
					}
				end
				return nil
			end
			if column.key == "status" then
				return { { start_col = 0, end_col = #ctx.padded, hl_group = "AtlasTextMuted" } }
			end
		end,
	})

	local offset = #lines
	utils.append_block(lines, spans, { lines = box_lines, highlights = box_spans })
	for lnum, entry in pairs(box_lmap) do
		line_map[offset + lnum] = entry
	end
end

---@param pr PullRequest
---@param width integer
---@param lines string[]
---@param spans table[]
local function render_job_log(pr, width, lines, spans)
	local job = state.selected_job
	if job == nil then
		return
	end
	local stage = state.selected_job_stage
	local pipeline = state.selected_pipeline_id and find_pipeline(state.selected_pipeline_id) or nil

	ensure_job_log(pr, pipeline, job)

	local job_state = tostring(job.state or "UNKNOWN"):upper()
	local status_icon = icons.pulls_status(job_state:lower())
	local status_hl = PIPELINE_HL[job_state] or "AtlasPipelineLinkMuted"
	local status = status_label(job_state)

	local title = string.format("%s%s %s  %s", PADDING, status_icon, job.name, status)
	table.insert(lines, title)
	table.insert(spans, { line = #lines - 1, start_col = PADDING_X, end_col = PADDING_X + #status_icon, hl_group = status_hl })
	table.insert(spans, { line = #lines - 1, start_col = #title - #status, end_col = #title, hl_group = status_hl })

	local metadata = {}
	if stage and stage.name then
		table.insert(metadata, stage.name)
	end
	local duration = duration_text(job.duration)
	if duration ~= "" then
		table.insert(metadata, duration)
	end
	local started = utils.relative_time(job.started_at)
	if started ~= "-" then
		table.insert(metadata, "started " .. started .. " ago")
	end
	if #metadata > 0 then
		local meta_line = PADDING .. table.concat(metadata, "  ")
		table.insert(lines, meta_line)
		table.insert(spans, { line = #lines - 1, start_col = 0, end_col = #meta_line, hl_group = "AtlasTextMuted" })
	end

	table.insert(lines, "")
	local divider = PADDING .. string.rep("─", math.max(width - (PADDING_X * 2), 1))
	table.insert(lines, divider)
	table.insert(spans, { line = #lines - 1, start_col = 0, end_col = #divider, hl_group = "AtlasTextMuted" })
	table.insert(lines, "")

	local log_entry = state.log_by_job_id[tostring(job.id)]
	if log_entry == nil or log_entry.status == "loading" then
		utils.push(lines, spans, spinner.with_text("Loading job log..."), "AtlasTextMuted", PADDING_X)
		return
	end
	if log_entry.status == "error" then
		utils.push(lines, spans, log_entry.text, "AtlasLogError", PADDING_X)
		return
	end

	local log_lines, log_spans = pipeline_logs.render_log(log_entry.text)
	local offset = #lines
	for _, line in ipairs(log_lines) do
		table.insert(lines, line)
	end
	for _, span in ipairs(log_spans) do
		table.insert(spans, {
			line = offset + span.line,
			start_col = span.start_col,
			end_col = span.end_col,
			hl_group = span.hl_group,
		})
	end
end

function M.reset()
	state.reset()
end

---@param pr PullRequest
---@param refresh fun()
---@param opts { force_refresh: boolean|nil }|nil
function M.on_select(pr, refresh, opts)
	opts = opts or {}
	current_refresh = refresh
	if not opts.force_refresh then
		return
	end

	state.requests.cancel()
	state.requests = require("atlas.core.requests").new()
	state.details_by_id = {}
	state.log_by_job_id = {}

	if state.selected_pipeline_id ~= nil then
		local pipeline = find_pipeline(state.selected_pipeline_id)
		if pipeline then
			ensure_pipeline_details(pr, pipeline)
		end
	end
	if state.selected_job ~= nil then
		local pipeline = state.selected_pipeline_id and find_pipeline(state.selected_pipeline_id) or nil
		ensure_job_log(pr, pipeline, state.selected_job)
	end
end

---@param pr PullRequest
---@param _details PullRequestDetails|nil
---@param width integer
---@return string[], table[], table<integer, table>|nil
function M.render(pr, _details, width)
	local lines = {}
	local spans = {}
	local line_map = {}

	if state.at_job_log() then
		render_job_log(pr, width, lines, spans)
	elseif state.at_job_list() then
		render_job_list(pr, width, lines, spans, line_map)
	else
		render_pipeline_list(width, lines, spans, line_map)
	end

	return lines, spans, line_map
end

---@param _lnum integer
---@param entry table
---@return boolean
function M.is_selectable_line(_lnum, entry)
	return entry.kind == "pipeline" or entry.kind == "job"
end

---@param pr PullRequest
---@param entry table
---@return boolean|nil
function M.on_enter(pr, entry)
	if entry.kind == "pipeline" and entry.pipeline then
		state.selected_pipeline_id = tostring(entry.pipeline.id)
		ensure_pipeline_details(pr, entry.pipeline)
		return true
	end
	if entry.kind == "job" and entry.job then
		state.selected_job = entry.job
		state.selected_job_stage = entry.stage
		ensure_job_log(pr, entry.pipeline, entry.job)
		return true
	end
end

---@return boolean
function M.is_loading()
	if detail.pipelines == "loading" then
		return true
	end
	if state.selected_pipeline_id ~= nil and state.details_by_id[state.selected_pipeline_id] == "loading" then
		return true
	end
	if state.selected_job ~= nil then
		local log_entry = state.log_by_job_id[tostring(state.selected_job.id)]
		if log_entry == nil or log_entry.status == "loading" then
			return true
		end
	end
	return false
end

---@param buf integer
---@param refresh fun()
function M.activate(buf, refresh)
	if not (buf and vim.api.nvim_buf_is_valid(buf)) then
		return
	end
	current_refresh = refresh
	if refresh ~= nil then
		keymaps.setup(buf, refresh)
	end
end

---@param buf integer
function M.deactivate(buf)
	current_refresh = nil
	if not (buf and vim.api.nvim_buf_is_valid(buf)) then
		return
	end
	keymaps.teardown(buf)
	state.requests.cancel()
end

return M
