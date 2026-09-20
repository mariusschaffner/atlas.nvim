---@class IssuesState
---@field active_view IssuesViewConfig|nil
---@field current_view IssuesViewConfig|nil
---@field is_loading boolean
---@field error string|nil
---@field current_user IssueUser|nil
---@field issues Issue[]
---@field milestones IssueMilestone[]
---@field issue_tree IssuesGroup[]
---@field collapsed_issue_keys table<string, boolean>
---@field provider IssuesProvider|nil
---@field provider_views IssuesViewConfig[]
---@field views IssuesViewConfig[]
---@field reloading_issue_keys table<string, boolean>
---@field reload_spinner_frame string
---@field filter_text string Filter bar text mirroring `active_view` (e.g. "assignee:me").
local M = {
	active_view = nil,
	current_view = nil,
	is_loading = false,
	error = nil,
	current_user = nil,
	issues = {},
	milestones = {},
	issue_tree = {},
	collapsed_issue_keys = {},
	provider = nil,
	provider_views = {},
	views = {},
	reloading_issue_keys = {},
	reload_spinner_frame = "⠋",
	filter_text = "",
}

---@param issues Issue[]
---@return IssuesGroup[]
local function build_issue_tree(issues)
	local by_key = {}
	for _, issue in ipairs(issues) do
		if issue.key ~= "" then
			by_key[issue.key] = { kind = "issue", key = issue.key, issue = issue, children = {} }
		end
	end

	for _, issue in ipairs(issues) do
		local parent = issue.parent and by_key[issue.parent.key]
		if parent ~= nil then
			table.insert(parent.children, issue)
		end
	end

	local roots = {}
	for _, issue in ipairs(issues) do
		local parent_key = issue.parent and issue.parent.key or ""
		if by_key[parent_key] == nil then
			local group = by_key[issue.key]
			if group ~= nil then
				table.insert(roots, group)
			end
		end
	end
	return roots
end

--- Wraps the epic root groups (from build_issue_tree) that carry a milestone
--- under a synthetic milestone group, in front-loaded order: groups without a
--- milestone first (their original relative order preserved), then milestone
--- groups sorted by due date (soonest first, undated last) then title.
--- Milestones with zero matching issues in the current view still appear
--- (as an empty group), since `milestones` is the full project list, not
--- derived from `root_groups`.
---@param root_groups IssuesGroup[]
---@param milestones IssueMilestone[]
---@return IssuesGroup[]
local function group_by_milestone(root_groups, milestones)
	local has_milestone_data = #(milestones or {}) > 0
	if not has_milestone_data then
		for _, group in ipairs(root_groups) do
			if group.issue and group.issue.milestone ~= nil then
				has_milestone_data = true
				break
			end
		end
	end
	if not has_milestone_data then
		return root_groups
	end

	---@type table<string, { milestone: IssueMilestone, children: IssuesGroup[] }>
	local buckets = {}
	local order = {}

	for _, ms in ipairs(milestones or {}) do
		local id = ms.id and tostring(ms.id) or nil
		if id and buckets[id] == nil then
			buckets[id] = { milestone = ms, children = {} }
			table.insert(order, id)
		end
	end

	local standalone = {}
	for _, group in ipairs(root_groups) do
		local ms = group.issue and group.issue.milestone or nil
		local id = ms and ms.id and tostring(ms.id) or nil
		if id == nil then
			table.insert(standalone, group)
		else
			if buckets[id] == nil then
				buckets[id] = { milestone = ms, children = {} }
				table.insert(order, id)
			end
			table.insert(buckets[id].children, group)
		end
	end

	table.sort(order, function(a, b)
		local ma, mb = buckets[a].milestone, buckets[b].milestone
		local da = ma.due_date and ma.due_date ~= "" and ma.due_date or nil
		local db = mb.due_date and mb.due_date ~= "" and mb.due_date or nil
		if da ~= db then
			if da == nil then
				return false
			end
			if db == nil then
				return true
			end
			return da < db
		end
		return tostring(ma.title or "") < tostring(mb.title or "")
	end)

	local result = {}
	for _, group in ipairs(standalone) do
		table.insert(result, group)
	end
	for _, id in ipairs(order) do
		local bucket = buckets[id]
		local key = "milestone:" .. id
		-- Milestones start expanded by default; seed once so a later
		-- refetch/refresh doesn't clobber a user's manual toggle.
		if M.collapsed_issue_keys[key] == nil then
			M.collapsed_issue_keys[key] = false
		end
		table.insert(result, { kind = "milestone", key = key, milestone = bucket.milestone, children = bucket.children })
	end
	return result
end

---@param issues Issue[]
function M.set_issues(issues)
	M.issues = issues
	M.issue_tree = group_by_milestone(build_issue_tree(M.issues), M.milestones)
end

---@param milestones IssueMilestone[]
function M.set_milestones(milestones)
	M.milestones = milestones
	M.issue_tree = group_by_milestone(build_issue_tree(M.issues), M.milestones)
end

---@param issue_key string
---@return boolean changed
function M.toggle_issue_collapsed(issue_key)
	if issue_key == "" then
		return false
	end
	M.collapsed_issue_keys[issue_key] = M.collapsed_issue_keys[issue_key] ~= true
	return true
end

---@return boolean changed
function M.toggle_all_issues_collapsed()
	local keys = {}
	local expand = false
	for _, group in ipairs(M.issue_tree) do
		if group.key ~= "" and #group.children > 0 then
			table.insert(keys, group.key)
			expand = expand or M.collapsed_issue_keys[group.key] == true
		end
	end
	if #keys == 0 then
		return false
	end

	M.collapsed_issue_keys = {}
	if not expand then
		for _, key in ipairs(keys) do
			M.collapsed_issue_keys[key] = true
		end
	end
	return true
end

return M
