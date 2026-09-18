local M = {}

local git = require("atlas.core.git")

--- Resolves a configured view list, substituting the local repository's
--- full_name (via git.local_repository()) into any view marked
--- `current_repo = true`. Shared by the pulls/issues GitLab providers,
--- whose `views()` differ only in their default view list.
---@generic V : { current_repo: boolean|nil, scope: string|nil, project: string|nil }
---@param configured V[]
---@return V[]
function M.resolve(configured)
	local repo
	for _, view in ipairs(configured) do
		if view.current_repo then
			local target = git.local_repository()
			if target and target.provider == "gitlab" then
				repo = target.repo_full_name
			end
			break
		end
	end

	local resolved = {}
	for i, view in ipairs(configured) do
		resolved[i] = vim.tbl_extend("force", {}, view)
		if view.current_repo and repo then
			resolved[i].project = repo
			resolved[i].scope = view.scope or "all"
		end
	end
	return resolved
end

return M
