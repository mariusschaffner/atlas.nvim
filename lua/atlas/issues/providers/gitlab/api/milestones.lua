local M = {}

local json = require("atlas.core.json")
local list_helper = require("atlas.issues.providers.gitlab.api.list_helper")

---@class GitLabMilestone : IssueMilestone
---@field id integer

---@param project_path string
---@param on_done fun(milestones: IssueMilestone[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.list(project_path, on_done)
	return list_helper.fetch_list(
		project_path,
		"/projects/%s/milestones?per_page=100&state=active",
		"List milestones",
		function(raw)
			local id = tonumber(raw.id)
			local title = json.safe_str(raw.title)
			if id and title then
				return { id = id, title = title }
			end
			return nil
		end,
		on_done
	)
end

return M
