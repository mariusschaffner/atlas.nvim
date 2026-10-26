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

-- Pipeline detail view (DESIGN-pipeline-view.md §6): one pipeline with its
-- ordered stages and every job, including the manual/playable flags the REST
-- jobs endpoint doesn't expose.

local GRAPH_JOB_FIELDS = [[
                      id
                      name
                      status
                      allowFailure
                      manualJob
                      playable
                      retryable
                      cancelable
                      duration
                      startedAt
                      finishedAt
                      webPath
]]

local function graph_query(with_merge_request)
	return string.format(
		[[
query($path:ID!,$iid:ID!){
  project(fullPath:$path){
    pipeline(iid:$iid){
      id
      iid
      status
      ref
      sha
      createdAt
      startedAt
      finishedAt
      duration
      path
      user { name username avatarUrl }
      commit { title }
%s
      stages{
        nodes{
          name
          status
          groups{
            nodes{
              jobs{
                nodes{
%s
                }
              }
            }
          }
        }
      }
    }
  }
}
]],
		with_merge_request and "      mergeRequest { iid title }" or "",
		GRAPH_JOB_FIELDS
	)
end

-- Flipped off the first time the instance rejects `Pipeline.mergeRequest`, so
-- older GitLab versions fall back to the query without it.
local merge_request_field = true

---@param value any GraphQL global id ("gid://gitlab/Ci::Build/12") or a plain id.
---@return string
local function numeric_id(value)
	local s = json.safe_str(value) or ""
	return s:match("(%d+)$") or s
end

---@param value any
---@return boolean
local function bool(value)
	return value == true
end

--- Maps a GraphQL `project.pipeline` node into the detail view's snapshot.
---@param raw any
---@param project_path string
---@return PipelineGraph
function M.map_pipeline_graph(raw, project_path)
	local item = json.safe_table(raw)
	local sha = json.safe_str(item.sha) or ""
	local raw_user = json.nilify(item.user)
	local user = nil
	if raw_user ~= nil then
		local u = json.safe_table(raw_user)
		user = {
			name = json.safe_str(u.name) or "",
			username = json.safe_str(u.username),
			avatar_url = json.safe_str(u.avatarUrl),
		}
	end
	local merge_request = nil
	local raw_mr = json.nilify(item.mergeRequest)
	if raw_mr ~= nil then
		local mr = json.safe_table(raw_mr)
		merge_request = { iid = tonumber(json.safe_str(mr.iid)), title = json.safe_str(mr.title) }
	end

	local stages = {}
	for _, raw_stage in ipairs(json.safe_table(json.safe_table(item.stages).nodes)) do
		local stage = json.safe_table(raw_stage)
		local jobs = {}
		for _, raw_group in ipairs(json.safe_table(json.safe_table(stage.groups).nodes)) do
			local group = json.safe_table(raw_group)
			for _, raw_job in ipairs(json.safe_table(json.safe_table(group.jobs).nodes)) do
				local job = json.safe_table(raw_job)
				table.insert(jobs, {
					id = numeric_id(job.id),
					name = json.safe_str(job.name) or "Job",
					status = (json.safe_str(job.status) or ""):lower(),
					allow_failure = bool(job.allowFailure),
					manual = bool(job.manualJob),
					playable = bool(job.playable),
					retryable = bool(job.retryable),
					cancelable = bool(job.cancelable),
					duration = tonumber(json.nilify(job.duration)),
					started_at = json.safe_str(job.startedAt),
					finished_at = json.safe_str(job.finishedAt),
					web_url = web_url(job.webPath),
				})
			end
		end
		table.insert(stages, {
			name = json.safe_str(stage.name) or "Stage",
			status = (json.safe_str(stage.status) or ""):lower(),
			jobs = jobs,
		})
	end

	local commit = json.safe_table(json.nilify(item.commit))
	return {
		id = numeric_id(item.id),
		iid = json.safe_str(item.iid),
		project_path = project_path,
		status = (json.safe_str(item.status) or ""):lower(),
		ref = json.safe_str(item.ref) or "",
		sha = sha,
		short_sha = sha ~= "" and sha:sub(1, 8) or nil,
		user = user,
		created_at = json.safe_str(item.createdAt),
		started_at = json.safe_str(item.startedAt),
		finished_at = json.safe_str(item.finishedAt),
		duration = tonumber(json.nilify(item.duration)),
		web_url = web_url(item.path),
		commit_title = json.safe_str(commit.title),
		merge_request = merge_request,
		stages = stages,
	}
end

--- REST lookup of a single pipeline; used once to resolve its iid (the
--- GraphQL `project.pipeline` field is keyed by iid).
---@param project_path string
---@param pipeline_id string|integer
---@param on_done fun(pipeline: { id: string, iid: string|nil, status: string }|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_pipeline(project_path, pipeline_id, on_done)
	local id = tonumber(pipeline_id)
	if (project_path or "") == "" or id == nil then
		vim.schedule(function()
			on_done(nil, (project_path or "") == "" and "Missing project" or "Missing pipeline ID")
		end)
		return nil
	end
	local endpoint = string.format("/projects/%s/pipelines/%d", service.url_encode(project_path), id)
	return service.request("GET", endpoint, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local item = json.safe_table(result)
		on_done({
			id = tostring(id),
			iid = json.safe_str(item.iid),
			status = (json.safe_str(item.status) or ""):lower(),
		}, nil)
	end, { action = "Fetch pipeline", project = project_path, pipeline_id = id })
end

---@param project_path string
---@param iid string|integer
---@param on_done fun(pipeline: PipelineGraph|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_pipeline_graph(project_path, iid, on_done)
	if (project_path or "") == "" or iid == nil or tostring(iid) == "" then
		vim.schedule(function()
			on_done(nil, (project_path or "") == "" and "Missing project" or "Missing pipeline iid")
		end)
		return nil
	end
	local current
	local cancelled = false
	local function run(with_mr)
		current = service.graphql(graph_query(with_mr), { path = project_path, iid = tostring(iid) }, function(result, err)
			if cancelled then
				return
			end
			if err then
				if with_mr and tostring(err):find("mergeRequest", 1, true) then
					merge_request_field = false
					run(false)
					return
				end
				on_done(nil, err)
				return
			end
			local raw = json.nilify(json.safe_table(json.safe_table(result).project).pipeline)
			if raw == nil then
				on_done(nil, "Pipeline not found")
				return
			end
			on_done(M.map_pipeline_graph(raw, project_path), nil)
		end, { action = "Fetch pipeline graph", project = project_path, pipeline_iid = iid })
	end
	run(merge_request_field)
	return {
		cancel = function()
			cancelled = true
			if current then
				current.cancel()
			end
		end,
	}
end

--- Fetches a job's trace from byte `offset` on (`Range: bytes=<offset>-`).
--- The callback gets the raw body and HTTP status: 206 = only the new bytes,
--- 200 = the whole trace (server ignored the range), 416 = nothing new.
---@param project_path string
---@param job_id string|integer
---@param offset integer
---@param on_done fun(body: string|nil, err: string|nil, status: integer|nil)
---@return { cancel: fun() }|nil
function M.fetch_job_trace(project_path, job_id, offset, on_done)
	local id = tonumber(job_id)
	if (project_path or "") == "" or id == nil then
		vim.schedule(function()
			on_done(nil, (project_path or "") == "" and "Missing project" or "Missing job ID", nil)
		end)
		return nil
	end
	local endpoint = string.format("/projects/%s/jobs/%d/trace", service.url_encode(project_path), id)
	local opts = nil
	if (offset or 0) > 0 then
		opts = { headers = { Range = string.format("bytes=%d-", offset) } }
	end
	return service.request_text("GET", endpoint, on_done, {
		action = "Fetch pipeline job log",
		project = project_path,
		job_id = id,
	}, opts)
end

---@param project_path string
---@param endpoint string Relative to the project, e.g. "pipelines/12/retry".
---@param action string Log label.
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
local function post_action(project_path, endpoint, action, on_done)
	local path = tostring(project_path or "")
	if path == "" then
		on_done(false, "Missing project")
		return nil
	end
	return service.request(
		"POST",
		string.format("/projects/%s/%s", service.url_encode(path), endpoint),
		nil,
		function(_, err)
			on_done(err == nil, err)
		end,
		{ action = action, project = path }
	)
end

---@param project_path string
---@param pipeline_id string|integer|nil
---@param verb "retry"|"cancel"
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
local function pipeline_action(project_path, pipeline_id, verb, on_done)
	local id = tonumber(pipeline_id)
	if not id then
		on_done(false, "Missing pipeline ID")
		return nil
	end
	local label = verb == "retry" and "Retry pipeline" or "Cancel pipeline"
	return post_action(project_path, string.format("pipelines/%d/%s", id, verb), label, on_done)
end

---@param project_path string
---@param job_id string|integer|nil
---@param verb "retry"|"cancel"|"play"
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
local function job_action(project_path, job_id, verb, on_done)
	local id = tonumber(job_id)
	if not id then
		on_done(false, "Missing pipeline job ID")
		return nil
	end
	local labels = { retry = "Retry pipeline job", cancel = "Cancel pipeline job", play = "Play pipeline job" }
	return post_action(project_path, string.format("jobs/%d/%s", id, verb), labels[verb], on_done)
end

--- Retries the pipeline's failed jobs.
---@param project_path string
---@param pipeline_id string|integer|nil
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.retry_pipeline(project_path, pipeline_id, on_done)
	return pipeline_action(project_path, pipeline_id, "retry", on_done)
end

---@param project_path string
---@param pipeline_id string|integer|nil
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.cancel_pipeline(project_path, pipeline_id, on_done)
	return pipeline_action(project_path, pipeline_id, "cancel", on_done)
end

---@param project_path string
---@param job_id string|integer|nil
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.retry_job(project_path, job_id, on_done)
	return job_action(project_path, job_id, "retry", on_done)
end

---@param project_path string
---@param job_id string|integer|nil
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.cancel_job(project_path, job_id, on_done)
	return job_action(project_path, job_id, "cancel", on_done)
end

---@param project_path string
---@param job_id string|integer|nil
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.play_job(project_path, job_id, on_done)
	return job_action(project_path, job_id, "play", on_done)
end

return M
