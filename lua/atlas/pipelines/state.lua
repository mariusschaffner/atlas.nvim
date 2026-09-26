---@class PipelinesState
---@field active_view PipelinesViewConfig|nil
---@field current_view PipelinesViewConfig|nil
---@field is_loading boolean
---@field error string|nil
---@field pipelines Pipeline[]
---@field provider PipelinesProvider|nil
---@field provider_views PipelinesViewConfig[]
---@field views PipelinesViewConfig[]
---@field filter_text string Filter bar text mirroring `active_view` (e.g. "mr:123").
local M = {
	active_view = nil,
	current_view = nil,
	is_loading = false,
	error = nil,
	pipelines = {},
	provider = nil,
	provider_views = {},
	views = {},
	filter_text = "",
}

---@param pipelines Pipeline[]
function M.set_pipelines(pipelines)
	M.pipelines = pipelines
end

return M
