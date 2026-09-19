-- Async, server-filtered user completion for inline field editing
-- (assignee/reviewer). Wraps a GitLab `list_members(project_path, query,
-- on_done)` call (issues and pulls each have their own, identically shaped)
-- behind the `AtlasFieldCompletionProvider` contract consumed by
-- `atlas.ui.inline_field_edit`.
local M = {}

---@param list_members fun(project_path: string, query: string, on_done: fun(users: table[]|nil, err: string|nil)): { cancel: fun() }|nil
---@param project_path string
---@param normalize fun(user: table): AtlasFieldCompletionItem|nil Maps a raw user (issues' `IssueUser` or pulls' `PullsUser`) to a completion item; return nil to exclude it.
---@param on_page (fun(users: table[]))|nil Called with each raw page of users as it's fetched, so the caller can resolve a chosen name back to its full user object (id) at submit time.
---@return AtlasFieldCompletionProvider
function M.for_project(list_members, project_path, normalize, on_page)
	return {
		debounce_ms = 150,
		fetch = function(query, on_items)
			return list_members(project_path, query, function(users, err)
				if err or users == nil then
					on_items({})
					return
				end
				if on_page then
					on_page(users)
				end
				local items = {}
				for _, user in ipairs(users) do
					local item = normalize(user)
					if item then
						table.insert(items, item)
					end
				end
				on_items(items)
			end)
		end,
	}
end

return M
