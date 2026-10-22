-- Maps an issue to one of the milestone detail view's three work-item
-- buckets (DESIGN-milestone-view.md §5): "Doing"/"To do"/"Done" map to the
-- `WF:<state>` label convention, with closed issues always counting as Done
-- regardless of label. Pure function, no vim/GitLab-client dependency --
-- just `Issue.status_id` + `Issue.labels`.
local M = {}

---@param name string
---@return string|nil -- the WF label's state text (lowercased, trimmed), or nil if `name` isn't a WF label
local function wf_label_state(name)
	local state = tostring(name or ""):match("^%s*[Ww][Ff]%s*:%s*(.-)%s*$")
	if state == nil or state == "" then
		return nil
	end
	return state:lower()
end

---@param issue Issue
---@return "todo"|"doing"|"done"
function M.state_for(issue)
	if issue.status_id == "closed" then
		return "done"
	end

	for _, label in ipairs(issue.labels or {}) do
		local state = wf_label_state(label.name)
		if state == "doing" then
			return "doing"
		elseif state == "done" then
			return "done"
		elseif state == "todo" or state == "to do" then
			return "todo"
		end
	end

	return "todo"
end

return M
