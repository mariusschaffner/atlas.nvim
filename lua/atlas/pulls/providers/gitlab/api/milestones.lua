local M = {}

local json = require("atlas.core.json")
local service = require("atlas.providers.gitlab.client")

--- The project's active milestones, for the MR sidebar's milestone picker
--- (same endpoint the issue view's picker uses).
---@param project_path string
---@param on_done fun(milestones: PullsMilestone[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.list(project_path, on_done)
	if project_path == "" then
		on_done(nil, "Missing project path")
		return nil
	end

	local endpoint =
		string.format("/projects/%s/milestones?per_page=100&state=active", service.url_encode(project_path))
	return service.request("GET", endpoint, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local out = {}
		for _, raw in ipairs(json.safe_table(result)) do
			local id = tonumber(raw.id)
			local title = json.safe_str(raw.title)
			if id and title and title ~= "" then
				table.insert(out, { id = id, title = title })
			end
		end
		on_done(out, nil)
	end, {
		action = "List milestones",
		project = project_path,
	})
end

return M
