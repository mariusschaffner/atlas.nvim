local config = require("atlas.config")
local highlights = require("atlas.pipelines.providers.gitlab.highlights")
local pipelines_api = require("atlas.pipelines.providers.gitlab.api.pipelines")
local views_helper = require("atlas.providers.gitlab.views_helper")

---@return AtlasGitLabPipelinesViewConfig[]
local function views()
	local cfg = config.domain_options("gitlab", "pipelines") or {}
	local configured = cfg.views
	if not configured or #configured == 0 then
		configured = {
			{ name = "All", key = "1", current_repo = true },
		}
	end
	return views_helper.resolve(configured)
end

local M = {
	views = views,
	current_repo_project = views_helper.current_repo_project,
	capabilities = {
		core = {
			fetch_pipelines = pipelines_api.fetch_pipelines,
			fetch_pipeline_details = pipelines_api.fetch_pipeline_details,
			fetch_job_log = pipelines_api.fetch_job_log,
		},
		ui = {
			setup = highlights.setup,
		},
	},
}

return M
