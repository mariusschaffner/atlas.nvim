---@alias PipelineState "UNKNOWN"|"STOPPED"|"SUCCESSFUL"|"INPROGRESS"|"FAILED"

---@class PipelineUser
---@field name string
---@field username string|nil
---@field avatar_url string|nil

---@class PipelineJob
---@field id string
---@field name string
---@field state PipelineState
---@field provider_state string|nil
---@field url string|nil
---@field duration number|nil Seconds

---@class PipelineStage
---@field name string
---@field state PipelineState
---@field jobs PipelineJob[] Empty until `fetch_pipeline_details` has loaded this pipeline.

---@class PipelineRef
---@field id string Provider-native pipeline id.
---@field key string Unique across projects, e.g. "group/project!123".

---@class Pipeline : PipelineRef
---@field project_path string
---@field status string Raw provider status string.
---@field state PipelineState
---@field ref string Branch (or tag) the pipeline ran on.
---@field sha string
---@field short_sha string|nil
---@field user PipelineUser|nil
---@field merge_request_iid integer|nil Set when fetched via a merge-request-scoped view.
---@field created_at string|nil
---@field started_at string|nil
---@field finished_at string|nil
---@field duration number|nil Seconds
---@field web_url string|nil
---@field stages PipelineStage[]|nil Stage name/state only until `fetch_pipeline_details` fills in jobs.

---@class PipelinesViewConfig
---@field name string
---@field key string|nil
---@field project string|number|nil
---@field merge_request_iid integer|nil
