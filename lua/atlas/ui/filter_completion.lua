-- Completion for the dashboard filter bar's whitespace-separated `key:value`
-- tokens (e.g. `assignee:me label:bug`). Paired with `inline_field_edit`'s
-- `word_segment` mode, which feeds this only the token currently under the
-- cursor: with no `:` yet, candidates are the known filter keys (see
-- `atlas.ui.filter_query`'s `KEY_ALIASES`); once a `key:` prefix is present,
-- candidates switch to that key's values. `view`/`scope`/`state`/`mr` stay
-- well-known static enums, but `assignee:`/`author:` are real, project-scoped
-- lookups for `issues`/`pulls` (`pipelines` has no such filter and keeps the
-- static "me"-only offer): `apply_filter_text` in both domains' controllers
-- always forces the dashboard's `project` to the current repo regardless of
-- any `project:` token typed, so a real member lookup is always valid here --
-- the same one the Assignee field in the issue/PR detail view already uses.
local M = {}

local STATE_MODULES = {
	issues = "atlas.issues.state",
	pulls = "atlas.pulls.state",
	pipelines = "atlas.pipelines.state",
}

local USERS_API_MODULES = {
	issues = "atlas.issues.providers.gitlab.api.users",
	pulls = "atlas.pulls.providers.gitlab.api.users",
}

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
---@return string|nil
local function current_project_path(domain)
	local mod = STATE_MODULES[domain]
	local state = mod and require(mod)
	local provider = state and state.provider
	local path = provider and provider.current_repo_project and provider.current_repo_project()
	return (type(path) == "string" and path ~= "") and path or nil
end

---@param domain AtlasDomain
---@param lower_key string
---@param value string
---@param on_items fun(items: AtlasFieldCompletionItem[])
---@return { cancel: fun() }|nil
local function fetch_me_key(domain, lower_key, value, on_items)
	local q = vim.trim(value):lower()
	local items = {}
	if q == "" or ("me"):find(q, 1, true) == 1 then
		table.insert(items, { name = "me", menu = lower_key })
	end

	local users_api_module = USERS_API_MODULES[domain]
	local project_path = users_api_module and current_project_path(domain)
	if project_path == nil then
		on_items(items)
		return nil
	end

	local users_api = require(users_api_module)
	return users_api.list_members(project_path, value, function(users, err)
		if not err then
			for _, user in ipairs(users or {}) do
				local username = tostring(user.account_id or "")
				if username ~= "" then
					table.insert(items, {
						name = username,
						display = string.format("%s (@%s)", user.display_name or username, username),
						menu = lower_key,
					})
				end
			end
		end
		on_items(items)
	end)
end

---@param domain AtlasDomain
---@return AtlasFieldCompletionProvider
function M.for_domain(domain)
	return {
		debounce_ms = 150,
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
			if ME_KEYS[lower_key] then
				return fetch_me_key(domain, lower_key, value, on_items)
			end

			local q = vim.trim(value):lower()
			local values = lower_key == "state" and STATE_VALUES[domain] or STATIC_VALUES[lower_key]

			local items = {}
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
