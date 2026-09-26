local M = {}

local json = require("atlas.core.json")
local service = require("atlas.providers.gitlab.client")

local PIPELINE_STATES = {
	SUCCESS = "SUCCESSFUL",
	FAILED = "FAILED",
	CANCELED = "STOPPED",
	SKIPPED = "STOPPED",
	MANUAL = "STOPPED",
	CREATED = "INPROGRESS",
	WAITING_FOR_RESOURCE = "INPROGRESS",
	PREPARING = "INPROGRESS",
	PENDING = "INPROGRESS",
	RUNNING = "INPROGRESS",
	SCHEDULED = "INPROGRESS",
	CANCELING = "INPROGRESS",
}

local PIPELINE_FIELDS = [[
          id
          status
          ref
          sha
          createdAt
          startedAt
          finishedAt
          duration
          path
          user {
            name
            username
            avatarUrl
          }
          stages(first:20){
            nodes{
              name
              status
            }
          }
]]

local PROJECT_PIPELINES_QUERY = string.format(
	[[
query($path:ID!){
  project(fullPath:$path){
    pipelines(first:50){
      nodes{
%s
      }
    }
  }
}
]],
	PIPELINE_FIELDS
)

local MR_PIPELINES_QUERY = string.format(
	[[
query($path:ID!,$iid:String!){
  project(fullPath:$path){
    mergeRequest(iid:$iid){
      pipelines(first:50){
        nodes{
%s
        }
      }
    }
  }
}
]],
	PIPELINE_FIELDS
)

---@param status string|nil
---@return PipelineState
function M.to_pipeline_state(status)
	return PIPELINE_STATES[tostring(status or ""):upper()] or "UNKNOWN"
end

---@param path any
---@return string|nil
local function web_url(path)
	local value = json.safe_str(path)
	if value == nil or value == "" then
		return nil
	end
	if value:match("^https?://") then
		return value
	end
	local origin = service.base_url():match("^(https?://[^/]+)") or service.base_url()
	return origin .. (value:sub(1, 1) == "/" and value or ("/" .. value))
end

---@param raw_item any
---@param project_path string
---@return Pipeline
local function map_pipeline(raw_item, project_path)
	local item = json.safe_table(raw_item)
	local id = (json.safe_str(item.id) or ""):match("/(%d+)$") or ""
	local sha = json.safe_str(item.sha) or ""

	---@type PipelineUser|nil
	local user = nil
	local raw_user = json.nilify(item.user)
	if raw_user ~= nil then
		local u = json.safe_table(raw_user)
		user = {
			name = json.safe_str(u.name) or "",
			username = json.safe_str(u.username),
			avatar_url = json.safe_str(u.avatarUrl),
		}
	end

	local stages = {}
	for _, raw_stage in ipairs(json.safe_table(json.safe_table(item.stages).nodes)) do
		local stage = json.safe_table(raw_stage)
		table.insert(stages, {
			name = json.safe_str(stage.name) or "Stage",
			state = M.to_pipeline_state(stage.status),
			jobs = {},
		})
	end

	return {
		id = id,
		key = project_path .. "!" .. id,
		project_path = project_path,
		status = json.safe_str(item.status) or "",
		state = M.to_pipeline_state(item.status),
		ref = json.safe_str(item.ref) or "",
		sha = sha,
		short_sha = sha ~= "" and sha:sub(1, 8) or nil,
		user = user,
		created_at = json.safe_str(item.createdAt),
		started_at = json.safe_str(item.startedAt),
		finished_at = json.safe_str(item.finishedAt),
		duration = tonumber(json.nilify(item.duration)),
		web_url = web_url(item.path),
		stages = stages,
	}
end

---@param view PipelinesViewConfig
---@param opts PipelinesFetchOpts
---@param on_done fun(pipelines: Pipeline[], next_page_token: string|nil, is_last: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_pipelines(view, opts, on_done)
	opts = opts or {}
	local path = tostring(view.project or "")
	if path == "" then
		vim.schedule(function()
			on_done({}, nil, true, "No project scoped for pipelines")
		end)
		return nil
	end

	local mr_iid = tonumber(view.merge_request_iid)
	local cache_key = mr_iid and string.format("gitlab_pipelines:list:%s:mr%d", path, mr_iid)
		or string.format("gitlab_pipelines:list:%s", path)

	if not opts.force_load then
		local cached, ok = service.get_memory_cache(cache_key)
		if ok then
			on_done(cached, nil, true, nil)
			return nil
		end
	end

	local query = mr_iid and MR_PIPELINES_QUERY or PROJECT_PIPELINES_QUERY
	local variables = mr_iid and { path = path, iid = tostring(mr_iid) } or { path = path }

	return service.graphql(query, variables, function(result, err)
		if err then
			on_done({}, nil, true, err)
			return
		end

		local project = json.safe_table(result).project
		local pipelines_conn
		if mr_iid then
			local merge_request = json.nilify(json.safe_table(project).mergeRequest)
			if merge_request == nil then
				on_done({}, nil, true, "Merge request not found")
				return
			end
			pipelines_conn = merge_request.pipelines
		else
			pipelines_conn = json.safe_table(project).pipelines
		end
		local nodes = json.safe_table(json.safe_table(pipelines_conn).nodes)

		local pipelines = {}
		for _, raw_item in ipairs(nodes) do
			local mapped = map_pipeline(raw_item, path)
			if mr_iid then
				mapped.merge_request_iid = mr_iid
			end
			table.insert(pipelines, mapped)
		end

		table.sort(pipelines, function(a, b)
			return (tonumber(a.id) or 0) > (tonumber(b.id) or 0)
		end)

		service.set_memory_cache(cache_key, pipelines)
		on_done(pipelines, nil, true, nil)
	end, { action = "Fetch pipelines", project_path = path, merge_request_iid = mr_iid })
end

---@param pipeline Pipeline
---@param _opts PipelinesFetchOpts|nil
---@param on_done fun(pipeline: Pipeline|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_pipeline_details(pipeline, _opts, on_done)
	local path = tostring(pipeline.project_path or "")
	local pipeline_id = tonumber(pipeline.id)
	if path == "" or pipeline_id == nil then
		on_done(nil, path == "" and "Missing project" or "Missing pipeline ID")
		return nil
	end

	local endpoint = string.format("/projects/%s/pipelines/%d/jobs?per_page=100", service.url_encode(path), pipeline_id)
	return service.fetch_all_pages(endpoint, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local stages = {}
		local stages_by_name = {}
		for _, stage in ipairs(pipeline.stages or {}) do
			local copied = { name = stage.name or "Stage", state = stage.state, jobs = {} }
			table.insert(stages, copied)
			stages_by_name[copied.name] = copied
		end

		for _, raw_job_value in ipairs(json.safe_table(result)) do
			local raw_job = json.safe_table(raw_job_value)
			local stage_name = json.safe_str(raw_job.stage) or "Unknown stage"
			local stage = stages_by_name[stage_name]
			if stage == nil then
				stage = { name = stage_name, state = "UNKNOWN", jobs = {} }
				stages_by_name[stage_name] = stage
				table.insert(stages, stage)
			end
			table.insert(stage.jobs, {
				id = json.safe_str(raw_job.id) or "",
				name = json.safe_str(raw_job.name) or "Job",
				state = M.to_pipeline_state(raw_job.status),
				provider_state = json.safe_str(raw_job.status) or "",
				url = web_url(raw_job.web_url),
				duration = tonumber(json.nilify(raw_job.duration)),
			})
		end

		on_done(vim.tbl_extend("force", {}, pipeline, { stages = stages }), nil)
	end, { action = "Fetch pipeline details", project = path, pipeline_id = pipeline_id })
end

---@param pipeline Pipeline
---@param job PipelineJob
---@param _opts PipelinesFetchOpts|nil
---@param on_done fun(log: string|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_job_log(pipeline, job, _opts, on_done)
	local path = tostring(pipeline.project_path or "")
	local job_id = tonumber(job.id)
	if path == "" or job_id == nil then
		vim.schedule(function()
			on_done(nil, path == "" and "Missing project" or "Missing job ID")
		end)
		return nil
	end

	local endpoint = string.format("/projects/%s/jobs/%d/trace", service.url_encode(path), job_id)
	return service.request_text("GET", endpoint, on_done, {
		action = "Fetch pipeline job log",
		project = path,
		job_id = job_id,
	})
end

return M
