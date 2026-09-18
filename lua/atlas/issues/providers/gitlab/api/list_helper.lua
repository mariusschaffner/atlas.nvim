local M = {}

local json = require("atlas.core.json")
local service = require("atlas.providers.gitlab.client")

--- Fetches a simple GitLab project list endpoint (labels, milestones, ...)
--- and maps each raw entry through map_item, dropping entries it rejects
--- (returns nil for).
---@generic T
---@param project_path string
---@param endpoint string a "/projects/%s/..." format string; %s is filled with the url-encoded project path
---@param action string log-meta action label, e.g. "List labels"
---@param map_item fun(raw: table): T|nil
---@param on_done fun(items: T[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_list(project_path, endpoint, action, map_item, on_done)
	if project_path == "" then
		on_done(nil, "Missing project path")
		return nil
	end

	return service.request(
		"GET",
		string.format(endpoint, service.url_encode(project_path)),
		nil,
		function(result, err)
			if err then
				on_done(nil, err)
				return
			end
			local out = {}
			for _, raw_value in ipairs(json.safe_table(result)) do
				local item = map_item(json.safe_table(raw_value))
				if item ~= nil then
					table.insert(out, item)
				end
			end
			on_done(out, nil)
		end,
		{
			action = action,
			project = project_path,
		}
	)
end

return M
