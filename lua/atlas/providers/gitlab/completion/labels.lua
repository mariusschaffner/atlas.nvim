-- Label completion for inline field editing. GitLab's labels endpoint has no
-- server-side query filter, so the full project label list is fetched once
-- (cached for the lifetime of the returned provider) and filtered
-- client-side per keystroke -- same substring-match style as
-- `atlas.providers.gitlab.completion.author`'s `@mention` matching.
local M = {}

---@param list fun(project_path: string, on_done: fun(labels: table[]|nil, err: string|nil)): { cancel: fun() }|nil
---@param project_path string
---@return AtlasFieldCompletionProvider
function M.for_project(list, project_path)
	---@type table[]|nil
	local cache = nil

	---@param query string
	---@param on_items fun(items: AtlasFieldCompletionItem[])
	local function filter_and_emit(query, on_items)
		local q = vim.trim(query):lower()
		local items = {}
		for _, label in ipairs(cache or {}) do
			local name = tostring(label.name or "")
			if name ~= "" and (q == "" or name:lower():find(q, 1, true) == 1) then
				table.insert(items, { name = name, menu = "label" })
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
			return list(project_path, function(labels, err)
				cache = (not err and labels) or {}
				filter_and_emit(query, on_items)
			end)
		end,
	}
end

return M
