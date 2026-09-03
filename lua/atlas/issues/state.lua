---@class IssuesState
---@field active_view IssuesViewConfig|nil
---@field current_view IssuesViewConfig|nil
---@field is_loading boolean
---@field error string|nil
---@field current_user IssueUser|nil
---@field issues Issue[]
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
			by_key[issue.key] = { issue = issue, children = {} }
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

---@param issues Issue[]
function M.set_issues(issues)
	M.issues = issues
	M.issue_tree = build_issue_tree(M.issues)
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
		if group.issue.key ~= "" and #group.children > 0 then
			table.insert(keys, group.issue.key)
			expand = expand or M.collapsed_issue_keys[group.issue.key] == true
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
