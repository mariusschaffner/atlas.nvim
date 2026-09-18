local M = {}

local json = require("atlas.core.json")
local list_helper = require("atlas.issues.providers.gitlab.api.list_helper")

---@param project_path string
---@param on_done fun(labels: IssueLabel[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.list(project_path, on_done)
	return list_helper.fetch_list(project_path, "/projects/%s/labels?per_page=100", "List labels", function(raw)
		local name = json.safe_str(raw.name)
		if not name or name == "" then
			return nil
		end
		local color = json.safe_str(raw.color)
		if color and color:sub(1, 1) == "#" then
			color = color:sub(2)
		end
		return { name = name, color = color }
	end, on_done)
end

return M
