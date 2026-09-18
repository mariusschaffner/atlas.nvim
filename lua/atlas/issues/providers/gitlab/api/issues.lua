local M = {}

local service = require("atlas.providers.gitlab.client")
local normalizer = require("atlas.issues.providers.gitlab.api.mapper")
local request_scope = require("atlas.core.requests")
local json = require("atlas.core.json")
local LIST_CACHE_PREFIX = "gitlab:issues:list:v3:"

local ISSUE_LABELS_GQL = [[
query($path: ID!, $iid: String!) {
  project(fullPath: $path) {
    issue(iid: $iid) {
      labels(first: 100) { nodes { title color } }
    }
  }
}
]]

local ISSUE_ASSIGNEES_GQL = [[
query($path: ID!, $iid: String!) {
  project(fullPath: $path) {
    issue(iid: $iid) {
      assignees(first: 100) { nodes { id username name } }
    }
  }
}
]]

local ISSUE_DETAILS_GQL = [[
query($path: ID!, $iid: String!) {
  project(fullPath: $path) {
    issue(iid: $iid) {
      description
      assignees(first: 100) { nodes { id username name } }
      labels(first: 100) { nodes { title color } }
      milestone { title }
    }
  }
}
]]

---@param path string
---@param iid integer
local function invalidate_issue(path, iid)
	service.delete_memory_cache(string.format("gitlab:issue-details:%s#%d", path, iid))
	service.clear_cache(LIST_CACHE_PREFIX)
end

---@param params table<string, any>
---@return string
local function build_query(params)
	local keys = {}
	for k, v in pairs(params) do
		if (type(v) == "table" and #v > 0) or (type(v) ~= "table" and v ~= nil and v ~= "") then
			table.insert(keys, k)
		end
	end
	if #keys == 0 then
		return ""
	end
	table.sort(keys)

	local parts = {}
	for _, key in ipairs(keys) do
		local value = params[key]
		if type(value) == "table" then
			for _, item in ipairs(value) do
				if item ~= nil and item ~= "" then
					table.insert(parts, key .. "=" .. service.url_encode(tostring(item)))
				end
			end
		else
			table.insert(parts, key .. "=" .. service.url_encode(tostring(value)))
		end
	end
	return "?" .. table.concat(parts, "&")
end

---@param view AtlasGitLabIssuesViewConfig
---@param opts { force_load?: boolean, max_results?: number }|nil
---@param on_done fun(issues: Issue[], err: string|nil)
---@return { cancel: fun() }|nil
function M.list_issues(view, opts, on_done)
	opts = opts or {}
	local scoped_project = view.project ~= nil and tostring(view.project) ~= ""
	local params = {
		scope = view.scope or "assigned_to_me",
		state = view.state or "opened",
		per_page = tostring(opts.max_results or 50),
		order_by = view.order_by or "updated_at",
		sort = view.sort or "desc",
	}
	if view.labels then
		params.labels = view.labels
	end
	if view.milestone then
		params.milestone = view.milestone
	end
	if view.assignee_username then
		params.assignee_username = view.assignee_username
	end
	if view.author_username then
		params.author_username = view.author_username
	end
	if view.search and view.search ~= "" then
		params.search = view.search
	end
	for k, v in pairs(view.extra_params or {}) do
		params[k] = v
	end

	local endpoint = (
		scoped_project and string.format("/projects/%s/issues", service.url_encode(tostring(view.project))) or "/issues"
	) .. build_query(params)
	local cache_key = LIST_CACHE_PREFIX .. endpoint

	if not opts.force_load then
		local cached, ok = service.get_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return service.request("GET", endpoint, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		-- TODO: GitLab's /issues REST API does not include parent refs. We either need to switch this
		-- to GraphQL and map the view config, or make another request here to fetch those refs.
		local issues = normalizer.to_issues_list(result)
		service.set_cache(cache_key, issues)
		on_done(issues, nil)
	end, {
		action = "List issues",
		endpoint = endpoint,
	})
end

---@param refs IssueRef[]
---@param opts { force_load?: boolean }|nil
---@param on_done fun(issues: Issue[], err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_by_refs(refs, opts, on_done)
	opts = opts or {}
	if #refs == 0 then
		on_done({}, nil)
		return nil
	end

	local iids_by_project = {}
	for _, ref in ipairs(refs) do
		local path, iid = normalizer.parse_key(ref.key)
		if path == "" or iid == nil then
			on_done({}, "Invalid issue key: " .. tostring(ref.key))
			return nil
		end
		iids_by_project[path] = iids_by_project[path] or {}
		table.insert(iids_by_project[path], iid)
	end

	local starts = {}
	for path, iids in pairs(iids_by_project) do
		starts[path] = function(done)
			return M.list_issues({
				project = path,
				scope = "all",
				state = "all",
				extra_params = { ["iids[]"] = iids },
			}, {
				force_load = opts.force_load == true,
				max_results = #iids,
			}, done)
		end
	end

	local requests = request_scope.new()
	requests.all(starts, function(values, errors)
		local issues = {}
		for path in pairs(iids_by_project) do
			if errors[path] then
				on_done({}, errors[path])
				return
			end
			vim.list_extend(issues, values[path] or {})
		end
		on_done(issues, nil)
	end)
	return requests
end

---@param ref IssueRef
---@param opts { force_load?: boolean }|nil
---@param on_done fun(details: IssueDetails|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_issue(ref, opts, on_done)
	opts = opts or {}
	local key = ref.key
	local path, iid = normalizer.parse_key(key)
	if path == "" or iid == nil then
		on_done(nil, "Invalid issue key: " .. tostring(key))
		return nil
	end

	local cache_key = string.format("gitlab:issue-details:%s#%d", path, iid)
	if not opts.force_load then
		local cached, ok = service.get_memory_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	return service.graphql(ISSUE_DETAILS_GQL, { path = path, iid = tostring(iid) }, function(data, err)
		if err then
			on_done(nil, err)
			return
		end
		local project = json.safe_table(data).project
		local raw = json.safe_table(project).issue
		local details = normalizer.to_issue_details(raw)
		if details then
			service.set_memory_cache(cache_key, details)
			on_done(details, nil)
			return
		end
		on_done(nil, "Issue not found")
	end, {
		action = "Fetch issue",
		path = path,
		iid = iid,
		transport = "graphql",
	})
end

---@param key string
---@param on_done fun(assignees: IssueUser[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.get_assignees(key, on_done)
	local path, iid = normalizer.parse_key(key)
	if path == "" or iid == nil then
		on_done(nil, "Invalid issue key: " .. tostring(key))
		return nil
	end

	return service.graphql(ISSUE_ASSIGNEES_GQL, { path = path, iid = tostring(iid) }, function(data, err)
		if err then
			on_done(nil, err)
			return
		end

		local project = json.safe_table(data).project
		local issue = json.nilify(json.safe_table(project).issue)
		if issue == nil then
			on_done(nil, "Issue not found")
			return
		end

		local assignees = {}
		for _, raw in ipairs(json.safe_table(json.safe_table(issue.assignees).nodes)) do
			local user = normalizer.to_user(raw)
			local id = tonumber((json.safe_str(raw.id) or ""):match("(%d+)$"))
			if user and id then
				user.id = id
				table.insert(assignees, user)
			end
		end
		on_done(assignees, nil)
	end, {
		action = "Fetch issue assignees",
		path = path,
		iid = iid,
	})
end

---@param key string
---@param payload table
---@param action string
---@param extra_meta table|nil
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
local function update_issue(key, payload, action, extra_meta, on_done)
	local path, iid = normalizer.parse_key(key)
	if path == "" or iid == nil then
		on_done(false, "Invalid issue key")
		return nil
	end

	local endpoint = string.format("/projects/%s/issues/%d", service.url_encode(path), iid)
	local meta = vim.tbl_extend("force", { action = action, path = path, iid = iid }, extra_meta or {})
	return service.request("PUT", endpoint, payload, function(_, err)
		if err then
			on_done(false, err)
			return
		end
		invalidate_issue(path, iid)
		on_done(true, nil)
	end, meta)
end

---@param issue Issue
---@param description string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.update_description(issue, description, on_done)
	return update_issue(
		tostring(issue.key or ""),
		{ description = description },
		"Update issue description",
		nil,
		on_done
	)
end

---@param key string
---@param state_event "close"|"reopen"
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.set_state(key, state_event, on_done)
	return update_issue(key, { state_event = state_event }, "Issue state change", { state = state_event }, on_done)
end

---@param key string
---@param diff { add?: string[], remove?: string[] }
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.update_labels(key, diff, on_done)
	local payload = {}
	if diff.add and #diff.add > 0 then
		payload.add_labels = table.concat(diff.add, ",")
	end
	if diff.remove and #diff.remove > 0 then
		payload.remove_labels = table.concat(diff.remove, ",")
	end
	if next(payload) == nil then
		on_done(true, nil)
		return nil
	end

	return update_issue(key, payload, "Update labels", { add = diff.add, remove = diff.remove }, on_done)
end

---@param key string
---@param on_done fun(labels: IssueLabel[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_issue_labels(key, on_done)
	local path, iid = normalizer.parse_key(key)
	if path == "" or iid == nil then
		on_done(nil, "Invalid issue key: " .. tostring(key))
		return nil
	end

	return service.graphql(ISSUE_LABELS_GQL, { path = path, iid = tostring(iid) }, function(data, err)
		if err then
			on_done(nil, err)
			return
		end

		local project = json.safe_table(data).project
		local issue = json.nilify(json.safe_table(project).issue)
		if issue == nil then
			on_done(nil, "Issue not found")
			return
		end

		local labels = {}
		for _, raw in ipairs(json.safe_table(json.safe_table(issue.labels).nodes)) do
			local name = json.safe_str(raw.title)
			if name then
				table.insert(labels, { name = name, color = json.safe_str(raw.color) })
			end
		end
		on_done(labels, nil)
	end, {
		action = "Fetch issue labels",
		path = path,
		iid = iid,
	})
end

---@param key string
---@param ids integer[]
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.set_assignee_ids(key, ids, on_done)
	local payload = { assignee_ids = ids }
	if #ids == 0 then
		-- Empty array unassigns; GitLab requires assignee_ids = [0] for clearing
		payload = { assignee_ids = { 0 } }
	end

	return update_issue(key, payload, "Set assignees", { ids = ids }, on_done)
end

---@param opts { project_path: string, title: string, description: string|nil, assignee_ids: integer[]|nil, labels: string[]|nil, milestone_id: integer|nil, due_date: string|nil, confidential: boolean|nil }
---@param on_done fun(result: { key: string|nil, iid: integer|nil, url: string|nil }|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.create_issue(opts, on_done)
	local path = tostring(opts.project_path or "")
	if path == "" then
		on_done(nil, "Missing project_path")
		return nil
	end
	local title = tostring(opts.title or "")
	if vim.trim(title) == "" then
		on_done(nil, "Title is required")
		return nil
	end

	local payload = { title = title }
	if opts.description and opts.description ~= "" then
		payload.description = opts.description
	end
	if opts.assignee_ids and #opts.assignee_ids > 0 then
		payload.assignee_ids = opts.assignee_ids
	end
	if opts.labels and #opts.labels > 0 then
		payload.labels = table.concat(opts.labels, ",")
	end
	if opts.milestone_id then
		payload.milestone_id = opts.milestone_id
	end
	if opts.due_date and opts.due_date ~= "" then
		payload.due_date = opts.due_date
	end
	if opts.confidential == true then
		payload.confidential = true
	end

	local endpoint = string.format("/projects/%s/issues", service.url_encode(path))

	return service.request("POST", endpoint, payload, function(result, err)
		if err then
			on_done(nil, err)
			return
		end

		local issue = normalizer.to_issue(result)
		if issue == nil then
			on_done(nil, "GitLab returned an invalid issue")
			return
		end
		service.clear_cache(LIST_CACHE_PREFIX)
		on_done({
			key = issue.key,
			iid = issue.iid,
			url = issue.url,
		}, nil)
	end, {
		action = "Create issue",
		path = path,
		title = title,
	})
end

---@param raw table
---@param fallback_path string
---@return string
local function mr_project_path(raw, fallback_path)
	local refs = json.safe_table(raw.references)
	local full_ref = json.safe_str(refs.full)
	local project_path = full_ref and full_ref:match("^(.-)!%d+$") or nil
	if project_path and project_path ~= "" then
		return project_path
	end
	local web = json.safe_str(raw.web_url) or ""
	project_path = web:match("^https?://[^/]+/(.+)/%-/merge_requests/")
	if project_path and project_path ~= "" then
		return project_path
	end
	return fallback_path
end

---@param issue Issue
---@param opts { force_load?: boolean }|nil
---@param on_done fun(items: IssueLinkedMergeRequest[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_related_merge_requests(issue, opts, on_done)
	opts = opts or {}
	local path, iid = normalizer.parse_key(tostring(issue.key or ""))
	if path == "" or iid == nil then
		on_done(nil, "Invalid issue key")
		return nil
	end

	local cache_key = string.format("gitlab:issue-linked-mrs:%s#%d", path, iid)
	if not opts.force_load then
		local cached, ok = service.get_memory_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local endpoint = string.format("/projects/%s/issues/%d/related_merge_requests", service.url_encode(path), iid)
	return service.request("GET", endpoint, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local items = {}
		for _, raw_value in ipairs(json.safe_table(result)) do
			local raw = json.safe_table(raw_value)
			local mr_iid = tonumber(raw.iid)
			if mr_iid then
				table.insert(items, {
					id = mr_iid,
					title = json.safe_str(raw.title) or "",
					state = (json.safe_str(raw.state) or ""):lower(),
					web_url = json.safe_str(raw.web_url),
					repo_full_name = mr_project_path(raw, path),
				})
			end
		end
		service.set_memory_cache(cache_key, items)
		on_done(items, nil)
	end, {
		action = "Fetch related merge requests",
		path = path,
		iid = iid,
	})
end

---@param cache_key string
---@param opts { force_load?: boolean }
---@param path string
---@param action string
---@param extra_meta table|nil
---@param map_item fun(raw: table): table|nil
---@param on_done fun(items: table[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_cached_branches(cache_key, opts, path, action, extra_meta, map_item, on_done)
	if not opts.force_load then
		local cached, ok = service.get_memory_cache(cache_key)
		if ok then
			on_done(cached, nil)
			return nil
		end
	end

	local endpoint = string.format("/projects/%s/repository/branches?per_page=100", service.url_encode(path))
	return service.request("GET", endpoint, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local items = {}
		for _, raw_value in ipairs(json.safe_table(result)) do
			local item = map_item(json.safe_table(raw_value))
			if item ~= nil then
				table.insert(items, item)
			end
		end
		service.set_memory_cache(cache_key, items)
		on_done(items, nil)
	end, vim.tbl_extend("force", { action = action, path = path }, extra_meta or {}))
end

---@param issue Issue
---@param opts { force_load?: boolean }|nil
---@param on_done fun(items: IssueLinkedBranch[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_related_branches(issue, opts, on_done)
	opts = opts or {}
	local path, iid = normalizer.parse_key(tostring(issue.key or ""))
	if path == "" or iid == nil then
		on_done(nil, "Invalid issue key")
		return nil
	end

	-- GitLab does not expose a stable public REST endpoint for "related
	-- branches" -- the issue page widget is backed by an internal web route
	-- (/-/issues/:iid/related_branches), which 404s against the versioned
	-- API. Branches created from an issue always follow the "<iid>-slug"
	-- naming convention GitLab itself generates, so derive the list from the
	-- standard repository branches endpoint instead.
	local prefix = tostring(iid) .. "-"
	return fetch_cached_branches(
		string.format("gitlab:issue-linked-branches:%s#%d", path, iid),
		opts,
		path,
		"Fetch related branches",
		{ iid = iid },
		function(raw)
			local name = json.safe_str(raw.name)
			if name and (name == tostring(iid) or name:sub(1, #prefix) == prefix) then
				return { name = name }
			end
			return nil
		end,
		on_done
	)
end

---@param issue Issue
---@param opts { force_load?: boolean }|nil
---@param on_done fun(items: IssueProjectBranch[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.fetch_project_branches(issue, opts, on_done)
	opts = opts or {}
	local path = normalizer.parse_key(tostring(issue.key or ""))
	if path == "" then
		on_done(nil, "Invalid issue key")
		return nil
	end

	return fetch_cached_branches(
		string.format("gitlab:issue-project-branches:%s", path),
		opts,
		path,
		"Fetch project branches",
		nil,
		function(raw)
			local name = json.safe_str(raw.name)
			if name and name ~= "" then
				return { name = name, default = raw.default == true }
			end
			return nil
		end,
		on_done
	)
end

---@param issue Issue
---@param branch_name string
---@param source_ref string
---@param on_done fun(branch: IssueLinkedBranch|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.create_branch(issue, branch_name, source_ref, on_done)
	local path, iid = normalizer.parse_key(tostring(issue.key or ""))
	if path == "" or iid == nil then
		on_done(nil, "Invalid issue key")
		return nil
	end
	local name = vim.trim(tostring(branch_name or ""))
	if name == "" then
		on_done(nil, "Branch name is required")
		return nil
	end
	local ref = vim.trim(tostring(source_ref or ""))
	if ref == "" then
		on_done(nil, "Source branch is required")
		return nil
	end

	local endpoint = string.format(
		"/projects/%s/repository/branches?branch=%s&ref=%s",
		service.url_encode(path),
		service.url_encode(name),
		service.url_encode(ref)
	)
	return service.request("POST", endpoint, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		service.delete_memory_cache(string.format("gitlab:issue-linked-branches:%s#%d", path, iid))
		on_done({ name = json.safe_str(json.safe_table(result).name) or name }, nil)
	end, {
		action = "Create branch",
		path = path,
		branch = name,
		ref = ref,
	})
end

---@param query string
---@param opts { force_load?: boolean, max_results?: number }|nil
---@param on_done fun(items: { id: any, key: string, title: string, url: string|nil, description: string }[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.search_issues_picker(query, opts, on_done)
	opts = opts or {}
	local params = {
		scope = "all",
		state = "all",
		search = query,
		per_page = tostring(opts.max_results or 30),
		order_by = "updated_at",
		sort = "desc",
	}
	local endpoint = "/issues" .. build_query(params)

	return service.request("GET", endpoint, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local items = {}
		for _, raw in ipairs(json.safe_table(result)) do
			local issue = normalizer.to_issue(raw)
			if issue then
				table.insert(items, {
					id = issue.key,
					key = issue.key,
					title = issue.title,
					url = issue.url,
					description = json.safe_str(raw.description) or "",
				})
			end
		end
		on_done(items, nil)
	end, {
		action = "Issue search picker",
		query = query,
	})
end

return M
