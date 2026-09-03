local M = {}

local utils = require("atlas.ui.shared.utils")
local icons = require("atlas.ui.shared.icons")
local spinner = require("atlas.ui.components.spinner")
local table_tree = require("atlas.ui.components.table_tree")
local pipeline_logs = require("atlas.pulls.ui.pipelines.logs")
local state = require("atlas.pulls.ui.detail.tabs.pipelines.state")
local detail = require("atlas.pulls.ui.detail.state")

local PADDING_X = 1
local MAX_LOG_LINES = 400

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

---@param pr PullRequest
---@param pipeline PullsPipeline
local function ensure_pipeline_details(pr, pipeline)
	local id = tostring(pipeline.id)
	if state.details_by_id[id] ~= nil then
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

---@param pr PullRequest
---@param pipeline PullsPipeline
---@param job PullsPipelineJob
---@param stage PullsPipelineStage|nil
---@return table
local function build_job_row(pr, pipeline, job, stage)
	local job_id = tostring(job.id)
	local job_state = tostring(job.state or "UNKNOWN"):upper()
	local job_icon = icons.pulls_status(job_state:lower())
	local expanded = state.is_job_expanded(job_id)

	local job_row = {
		label = string.format("%s %s", job_icon, job.name),
		status = duration_text(job.duration),
		status_icon = job_icon,
		status_hl = PIPELINE_HL[job_state] or "AtlasPipelineLinkMuted",
		kind = "job",
		job_id = job_id,
		_item = { kind = "job", job = job, stage = stage, pipeline = pipeline },
		children = { { label = "", kind = "placeholder" } },
	}

	if expanded then
		ensure_job_log(pr, pipeline, job)
		local log_entry = state.log_by_job_id[job_id]
		local children = {}
		if log_entry == nil or log_entry.status == "loading" then
			table.insert(children, { label = spinner.with_text("Loading log..."), kind = "log_status" })
		elseif log_entry.status == "error" then
			table.insert(children, { label = log_entry.text, kind = "log_error" })
		else
			local log_lines = pipeline_logs.split_log_lines(log_entry.text)
			local shown = log_lines
			if #log_lines > MAX_LOG_LINES then
				local truncated = #log_lines - MAX_LOG_LINES
				shown = vim.list_slice(log_lines, truncated + 1, #log_lines)
				table.insert(children, {
					label = string.format("... %d earlier line%s truncated ...", truncated, truncated == 1 and "" or "s"),
					kind = "log_status",
				})
			end
			if #shown == 0 then
				table.insert(children, { label = "(empty log)", kind = "log_status" })
			end
			for _, line in ipairs(shown) do
				table.insert(children, {
					label = line ~= "" and line or " ",
					kind = "log_line",
					log_hl = pipeline_logs.classify_log_line(line),
				})
			end
		end
		job_row.children = children
	end

	return job_row
end

---@param pr PullRequest
---@param pipeline PullsPipeline
---@param detailed PullsPipeline
---@return table[]
local function build_stage_rows(pr, pipeline, detailed)
	local rows = {}
	for _, stage in ipairs(sort_by_status(detailed.stages)) do
		if #stage.jobs > 0 then
			local stage_state = tostring(stage.state or "UNKNOWN"):upper()
			local stage_icon = icons.pulls_status(stage_state:lower())
			local stage_row = {
				label = string.format("%s %s", stage_icon, stage.name or "Stage"),
				status = "",
				status_icon = stage_icon,
				status_hl = PIPELINE_HL[stage_state] or "AtlasPipelineLinkMuted",
				kind = "stage",
				children = {},
			}
			for _, job in ipairs(sort_by_status(stage.jobs)) do
				table.insert(stage_row.children, build_job_row(pr, pipeline, job, stage))
			end
			table.insert(rows, stage_row)
		end
	end
	return rows
end

---@param pr PullRequest
---@param pipeline PullsPipeline
---@return table
local function build_pipeline_row(pr, pipeline)
	local id = tostring(pipeline.id)
	local state_value = tostring(pipeline.state or "UNKNOWN"):upper()
	local icon = icons.pulls_status(state_value:lower())
	local job_count = tonumber(pipeline.job_count)
	local expanded = state.is_pipeline_expanded(id)

	local pipeline_row = {
		label = string.format("%s %s", icon, pipeline.name),
		status = string.format("%s %s", icon, status_label(state_value)),
		status_icon = icon,
		status_hl = PIPELINE_HL[state_value] or "AtlasPipelineLinkMuted",
		jobs = job_count and string.format("%d %s", job_count, job_count == 1 and "job" or "jobs") or "",
		kind = "pipeline",
		pipeline_id = id,
		_item = { kind = "pipeline", pipeline = pipeline },
		children = { { label = "", kind = "placeholder" } },
		separator = true,
	}

	if expanded then
		ensure_pipeline_details(pr, pipeline)
		local detailed = state.details_by_id[id]
		local children = {}
		if detailed == nil or detailed == "loading" then
			table.insert(children, { label = spinner.with_text("Loading jobs..."), kind = "log_status" })
		elseif type(detailed) == "string" then
			table.insert(children, { label = detailed, kind = "log_error" })
		else
			children = build_stage_rows(pr, pipeline, detailed)
			if #children == 0 then
				table.insert(children, { label = "No jobs found.", kind = "log_status" })
			end
		end
		pipeline_row.children = children
	end

	return pipeline_row
end

---@param row table
---@param column table
---@param ctx { text: string, padded: string, width: integer }
---@return table[]|nil
local function cell_hl(row, column, ctx)
	if column.key == "label" then
		if row.kind == "pipeline" or row.kind == "job" or row.kind == "stage" then
			if row.status_icon then
				local start_col = ctx.text:find(row.status_icon, 1, true)
				if start_col then
					return {
						{ start_col = start_col - 1, end_col = start_col - 1 + #row.status_icon, hl_group = row.status_hl },
					}
				end
			end
			return nil
		end
		if row.kind == "log_line" then
			return row.log_hl and { { start_col = 0, end_col = #ctx.padded, hl_group = row.log_hl } } or nil
		end
		if row.kind == "log_error" then
			return { { start_col = 0, end_col = #ctx.padded, hl_group = "AtlasLogError" } }
		end
		if row.kind == "log_status" or row.kind == "placeholder" then
			return { { start_col = 0, end_col = #ctx.padded, hl_group = "AtlasTextMuted" } }
		end
		return nil
	end
	if column.key == "status" then
		if row.kind == "pipeline" then
			return { { start_col = 0, end_col = #ctx.padded, hl_group = row.status_hl } }
		end
		if row.kind == "job" then
			return { { start_col = 0, end_col = #ctx.padded, hl_group = "AtlasTextMuted" } }
		end
		return nil
	end
	if column.key == "jobs" then
		return { { start_col = 0, end_col = #ctx.padded, hl_group = "AtlasTextMuted" } }
	end
end

---@param pr PullRequest
---@param _details PullRequestDetails|nil
---@param width integer
---@return string[], table[], table<integer, table>|nil
function M.render(pr, _details, width)
	local lines, spans, line_map = {}, {}, {}

	if detail.pipelines == nil or detail.pipelines == "loading" then
		utils.push(lines, spans, spinner.with_text("Loading pipelines..."), "AtlasTextMuted", PADDING_X)
		return lines, spans, line_map
	end
	if type(detail.pipelines) == "string" then
		utils.push(lines, spans, detail.pipelines, "AtlasLogError", PADDING_X)
		return lines, spans, line_map
	end

	local entries = sort_by_status(detail.pipelines)
	if #entries == 0 then
		utils.push(lines, spans, "No pipelines found.", "AtlasTextMuted", PADDING_X)
		return lines, spans, line_map
	end

	local rows = {}
	for _, pipeline in ipairs(entries) do
		table.insert(rows, build_pipeline_row(pr, pipeline))
	end

	local tbl_lines, tbl_map, tbl_spans = table_tree.render({
		width = width,
		margin = PADDING_X,
		columns = {
			{ key = "label", name = "Pipeline", can_grow = true, header_hl = "AtlasColumnHeader" },
			{ key = "status", name = "Status", can_grow = false, header_hl = "AtlasColumnHeader" },
			{ key = "jobs", name = "Jobs", can_grow = false, header_hl = "AtlasColumnHeader" },
		},
		rows = rows,
		tree = {
			column_key = "label",
			children_key = "children",
			is_expanded = function(row)
				if row.kind == "pipeline" then
					return state.is_pipeline_expanded(row.pipeline_id)
				end
				if row.kind == "job" then
					return state.is_job_expanded(row.job_id)
				end
				return true
			end,
		},
		cell_hl = cell_hl,
	})

	local offset = #lines
	utils.append_block(lines, spans, { lines = tbl_lines, highlights = tbl_spans })
	for lnum, entry in pairs(tbl_map) do
		line_map[offset + lnum] = entry
	end

	return lines, spans, line_map
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
	-- Rows still marked expanded will lazily re-fetch on the next render.
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
		local id = tostring(entry.pipeline.id)
		state.toggle_pipeline(id)
		if state.is_pipeline_expanded(id) then
			ensure_pipeline_details(pr, entry.pipeline)
		end
		if current_refresh then
			current_refresh()
		end
		return true
	end
	if entry.kind == "job" and entry.job then
		local id = tostring(entry.job.id)
		state.toggle_job(id)
		if state.is_job_expanded(id) then
			ensure_job_log(pr, entry.pipeline, entry.job)
		end
		if current_refresh then
			current_refresh()
		end
		return true
	end
end

---@return boolean
function M.is_loading()
	if detail.pipelines == "loading" then
		return true
	end
	for id in pairs(state.expanded_pipelines) do
		if state.details_by_id[id] == "loading" then
			return true
		end
	end
	for id in pairs(state.expanded_jobs) do
		local log_entry = state.log_by_job_id[id]
		if log_entry == nil or log_entry.status == "loading" then
			return true
		end
	end
	return false
end

---@param _buf integer
---@param refresh fun()
function M.activate(_buf, refresh)
	current_refresh = refresh
end

---@param _buf integer
function M.deactivate(_buf)
	current_refresh = nil
	state.requests.cancel()
end

return M
