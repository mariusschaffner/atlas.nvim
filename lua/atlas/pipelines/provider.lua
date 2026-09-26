---@class PipelinesFetchOpts
---@field force_load boolean|nil

---@class PipelinesCoreCapability
---@field fetch_pipelines fun(view: PipelinesViewConfig, opts: PipelinesFetchOpts, on_done: fun(pipelines: Pipeline[], next_page_token: string|nil, is_last: boolean, err: string|nil)): { cancel: fun() }|nil
---@field fetch_pipeline_details fun(pipeline: Pipeline, opts: PipelinesFetchOpts|nil, on_done: fun(pipeline: Pipeline|nil, err: string|nil)): { cancel: fun() }|nil
---@field fetch_job_log (fun(pipeline: Pipeline, job: PipelineJob, opts: PipelinesFetchOpts|nil, on_done: fun(log: string|nil, err: string|nil)): { cancel: fun() }|nil)|nil

---@class PipelinesUICapability
---@field setup fun()|nil

---@class PipelinesProviderCapabilities
---@field core PipelinesCoreCapability
---@field ui PipelinesUICapability|nil

---@class PipelinesProvider
---@field id string
---@field name string
---@field icon string
---@field hl_group string
---@field views fun(): PipelinesViewConfig[]
---@field current_repo_project (fun(): string|nil)|nil
---@field capabilities PipelinesProviderCapabilities
