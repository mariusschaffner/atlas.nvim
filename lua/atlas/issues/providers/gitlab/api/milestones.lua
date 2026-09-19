local M = {}

local json = require("atlas.core.json")
local service = require("atlas.providers.gitlab.client")
local list_helper = require("atlas.issues.providers.gitlab.api.list_helper")
local issues_mapper = require("atlas.issues.providers.gitlab.api.mapper")

---@class GitLabMilestone : IssueMilestone
---@field id integer

---@param raw table
---@return IssueMilestone|nil
local function to_milestone(raw)
	local id = tonumber(raw.id)
	local title = json.safe_str(raw.title)
	if not id or not title then
		return nil
	end
	return {
		id = id,
		title = title,
		due_date = json.safe_str(raw.due_date),
		start_date = json.safe_str(raw.start_date),
		web_url = json.safe_str(raw.web_url),
		description = json.safe_str(raw.description),
		state = json.safe_str(raw.state),
	}
end

---@param raw table
---@param prefix string
---@return MilestoneWorkItem|nil
local function to_work_item(raw, prefix)
	local iid = tonumber(raw.iid)
	local title = json.safe_str(raw.title)
	if not iid or not title then
		return nil
	end
	return { key = prefix .. tostring(iid), title = title }
end

---@param project_path string
---@param on_done fun(milestones: IssueMilestone[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.list(project_path, on_done)
	return list_helper.fetch_list(
		project_path,
		"/projects/%s/milestones?per_page=100&state=active",
		"List milestones",
		to_milestone,
		on_done
	)
end

---@param project_path string
---@param milestone_id integer
---@param on_done fun(milestone: IssueMilestone|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.get(project_path, milestone_id, on_done)
	if project_path == "" then
		on_done(nil, "Missing project path")
		return nil
	end
	local endpoint =
		string.format("/projects/%s/milestones/%d", service.url_encode(project_path), milestone_id)
	return service.request("GET", endpoint, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local milestone = to_milestone(json.safe_table(result))
		if milestone == nil then
			on_done(nil, "Milestone not found")
			return
		end
		on_done(milestone, nil)
	end, {
		action = "Fetch milestone",
		project = project_path,
		milestone_id = milestone_id,
	})
end

---@param project_path string
---@param milestone_id integer
---@param on_done fun(issues: Issue[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.list_issues(project_path, milestone_id, on_done)
	if project_path == "" then
		on_done(nil, "Missing project path")
		return nil
	end
	local endpoint = string.format(
		"/projects/%s/milestones/%d/issues?per_page=100",
		service.url_encode(project_path),
		milestone_id
	)
	return service.request("GET", endpoint, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		on_done(issues_mapper.to_issues_list(result), nil)
	end, {
		action = "Fetch milestone issues",
		project = project_path,
		milestone_id = milestone_id,
	})
end

---@param project_path string
---@param milestone_id integer
---@param on_done fun(items: MilestoneWorkItem[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
function M.list_merge_requests(project_path, milestone_id, on_done)
	if project_path == "" then
		on_done(nil, "Missing project path")
		return nil
	end
	local endpoint = string.format(
		"/projects/%s/milestones/%d/merge_requests?per_page=100",
		service.url_encode(project_path),
		milestone_id
	)
	return service.request("GET", endpoint, nil, function(result, err)
		if err then
			on_done(nil, err)
			return
		end
		local items = {}
		for _, raw in ipairs(json.safe_table(result)) do
			local item = to_work_item(json.safe_table(raw), "!")
			if item then
				table.insert(items, item)
			end
		end
		on_done(items, nil)
	end, {
		action = "Fetch milestone merge requests",
		project = project_path,
		milestone_id = milestone_id,
	})
end

---@param project_path string
---@param milestone_id integer
---@param description string
---@param on_done fun(ok: boolean, err: string|nil)
---@return { cancel: fun() }|nil
function M.update_description(project_path, milestone_id, description, on_done)
	if project_path == "" then
		on_done(false, "Missing project path")
		return nil
	end
	local endpoint = string.format("/projects/%s/milestones/%d", service.url_encode(project_path), milestone_id)
	return service.request("PUT", endpoint, { description = description }, function(_, err)
		on_done(err == nil, err)
	end, {
		action = "Update milestone description",
		project = project_path,
		milestone_id = milestone_id,
	})
end

return M
