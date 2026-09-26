-- Completion for the dashboard filter bar's whitespace-separated `key:value`
-- tokens (e.g. `assignee:me label:bug`). Paired with `inline_field_edit`'s
-- `word_segment` mode, which feeds this only the token currently under the
-- cursor: with no `:` yet, candidates are the known filter keys (see
-- `atlas.ui.filter_query`'s `KEY_ALIASES`); once a `key:` prefix is present,
-- candidates switch to that key's values. Dashboards aren't scoped to a
-- single project (a view can span projects/groups), so only well-known
-- static enums are offered here -- no server-backed label/assignee/milestone
-- lookups, unlike the per-issue/per-PR detail fields which do have a fixed
-- project_path.
local M = {}

local FILTER_KEYS = { "view", "scope", "state", "label", "assignee", "author", "milestone", "mr" }

local STATIC_VALUES = {
	view = { "issues", "pulls", "pipelines" },
	scope = { "all", "assigned_to_me", "created_by_me" },
}

local STATE_VALUES = {
	issues = { "open", "closed" },
	pulls = { "open", "merged", "declined" },
}

local ME_KEYS = { assignee = true, author = true }

---@param domain AtlasDomain
---@return AtlasFieldCompletionProvider
function M.for_domain(domain)
	return {
		debounce_ms = 0,
		fetch = function(query, on_items)
			local key, value = query:match("^([%a_]+):(.*)$")
			if key == nil then
				local q = query:lower()
				local items = {}
				for _, k in ipairs(FILTER_KEYS) do
					if q == "" or k:find(q, 1, true) == 1 then
						table.insert(items, { name = k .. ":", menu = "key" })
					end
				end
				on_items(items)
				return
			end

			local lower_key = key:lower()
			local q = vim.trim(value):lower()
			local values = lower_key == "state" and STATE_VALUES[domain] or STATIC_VALUES[lower_key]

			local items = {}
			if ME_KEYS[lower_key] and (q == "" or ("me"):find(q, 1, true) == 1) then
				table.insert(items, { name = "me", menu = lower_key })
			end
			for _, v in ipairs(values or {}) do
				if q == "" or tostring(v):find(q, 1, true) == 1 then
					table.insert(items, { name = v, menu = lower_key })
				end
			end
			on_items(items)
		end,
	}
end

return M
