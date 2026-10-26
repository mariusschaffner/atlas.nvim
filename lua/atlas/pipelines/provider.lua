---@class PipelinesFetchOpts
---@field force_load boolean|nil

---@class PipelinesCoreCapability
---@field fetch_pipelines fun(view: PipelinesViewConfig, opts: PipelinesFetchOpts, on_done: fun(pipelines: Pipeline[], next_page_token: string|nil, is_last: boolean, err: string|nil)): { cancel: fun() }|nil
---@field fetch_pipeline_details fun(pipeline: Pipeline, opts: PipelinesFetchOpts|nil, on_done: fun(pipeline: Pipeline|nil, err: string|nil)): { cancel: fun() }|nil
---@field fetch_job_log (fun(pipeline: Pipeline, job: PipelineJob, opts: PipelinesFetchOpts|nil, on_done: fun(log: string|nil, err: string|nil)): { cancel: fun() }|nil)|nil

--- Pipeline detail view (DESIGN-pipeline-view.md §5, §6).
---@class PipelinesDetailCapability
---@field fetch_pipeline fun(project_path: string, pipeline_id: string|integer, on_done: fun(pipeline: { id: string, iid: string|nil, status: string }|nil, err: string|nil)): { cancel: fun() }|nil
---@field fetch_pipeline_graph fun(project_path: string, iid: string|integer, on_done: fun(pipeline: PipelineGraph|nil, err: string|nil)): { cancel: fun() }|nil
---@field fetch_job_trace fun(project_path: string, job_id: string|integer, offset: integer, on_done: fun(body: string|nil, err: string|nil, status: integer|nil)): { cancel: fun() }|nil
---@field retry_pipeline fun(project_path: string, pipeline_id: string|integer, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil
---@field cancel_pipeline fun(project_path: string, pipeline_id: string|integer, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil
---@field retry_job fun(project_path: string, job_id: string|integer, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil
---@field cancel_job fun(project_path: string, job_id: string|integer, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil
---@field play_job fun(project_path: string, job_id: string|integer, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil

---@class PipelinesUICapability
---@field setup fun()|nil

---@class PipelinesProviderCapabilities
---@field core PipelinesCoreCapability
---@field detail PipelinesDetailCapability|nil
---@field ui PipelinesUICapability|nil

---@class PipelinesProvider
---@field id string
---@field name string
---@field icon string
---@field hl_group string
---@field views fun(): PipelinesViewConfig[]
---@field current_repo_project (fun(): string|nil)|nil
---@field capabilities PipelinesProviderCapabilities
