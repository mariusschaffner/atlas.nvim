-- Milestone completion for inline field editing. GitLab's milestones
-- endpoint has no server-side title filter here, so the full active
-- milestone list is fetched once (cached for the lifetime of the returned
-- provider) and filtered client-side per keystroke -- same pattern as
-- `atlas.providers.gitlab.completion.labels`.
local M = {}

---@param list fun(project_path: string, on_done: fun(milestones: IssueMilestone[]|nil, err: string|nil)): { cancel: fun() }|nil
---@param project_path string
---@param on_page (fun(milestones: IssueMilestone[]))|nil Called once, with the full list, as soon as it's fetched, so the caller can resolve a chosen title back to its id at submit time.
---@return AtlasFieldCompletionProvider
function M.for_project(list, project_path, on_page)
	---@type IssueMilestone[]|nil
	local cache = nil

	---@param query string
	---@param on_items fun(items: AtlasFieldCompletionItem[])
	local function filter_and_emit(query, on_items)
		local q = vim.trim(query):lower()
		local items = {}
		for _, milestone in ipairs(cache or {}) do
			local title = tostring(milestone.title or "")
			if title ~= "" and (q == "" or title:lower():find(q, 1, true) == 1) then
				table.insert(items, { name = title, menu = "milestone" })
			end
		end
		on_items(items)
	end

	return {
		fetch = function(query, on_items)
			if cache ~= nil then
				filter_and_emit(query, on_items)
				return nil
			end
			return list(project_path, function(milestones, err)
				cache = (not err and milestones) or {}
				if on_page then
					on_page(cache)
				end
				filter_and_emit(query, on_items)
			end)
		end,
	}
end

return M
