---@class GitLabIssue : Issue
---@field project_path string
---@field iid integer
---@field confidential boolean|nil

local GITLAB_REACTION_OPTIONS = require("atlas.ui.shared.emojis").gitlab()
local actions = require("atlas.issues.providers.gitlab.actions")
local author_completion = require("atlas.providers.gitlab.completion.author")
local config = require("atlas.config")
local detail_ui = require("atlas.issues.providers.gitlab.ui.detail")
local highlights = require("atlas.issues.providers.gitlab.highlights")
local issues_api = require("atlas.issues.providers.gitlab.api.issues")
local milestones_api = require("atlas.issues.providers.gitlab.api.milestones")
local notes_api = require("atlas.issues.providers.gitlab.api.notes")
local users_api = require("atlas.issues.providers.gitlab.api.users")
local notifications_api = require("atlas.providers.gitlab.notifications")
local views_helper = require("atlas.providers.gitlab.views_helper")

---@param view IssuesViewConfig
---@return string
local function search_query(view)
	---@cast view AtlasGitLabIssuesViewConfig
	local parts = { "is:" .. tostring(view.state or "opened") }
	for _, field in ipairs({ "project", "scope", "labels", "milestone", "assignee_username", "author_username" }) do
		local value = view[field]
		if value ~= nil and value ~= "" then
			table.insert(parts, string.format("%s:%s", field:gsub("_username$", ""), tostring(value)))
		end
	end
	if view.search and view.search ~= "" then
		table.insert(parts, tostring(view.search))
	end

	local extra_keys = vim.tbl_keys(view.extra_params or {})
	table.sort(extra_keys)
	for _, key in ipairs(extra_keys) do
		local value = view.extra_params[key]
		if value ~= nil and value ~= "" then
			table.insert(parts, string.format("%s:%s", key, tostring(value)))
		end
	end
	return table.concat(parts, " ")
end

---@param view IssuesViewConfig
---@param opts IssuesFetchOpts
---@param on_done fun(issues: Issue[], next_page_token: string|nil, is_last: boolean, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_issues(view, opts, on_done)
	---@cast view AtlasGitLabIssuesViewConfig
	return issues_api.list_issues(view, {
		force_load = opts and opts.force_load == true or false,
		max_results = opts and opts.max_results or 50,
	}, function(issues, err)
		if err then
			on_done({}, nil, true, err)
			return
		end
		on_done(issues or {}, nil, true, nil)
	end)
end

---@param issue Issue
---@param opts { force_refresh: boolean|nil }|nil
---@param on_done fun(items: IssueConversationItem[]|nil, err: string|nil)
---@return { cancel: fun() }|nil
local function fetch_conversation(issue, opts, on_done)
	opts = opts or {}
	local force = opts.force_refresh == true
	if tostring(issue.key or "") == "" then
		on_done(nil, "Invalid issue key")
		return nil
	end

	return notes_api.list_conversation(issue, { force_load = force }, function(result, err)
		if err or result == nil then
			on_done(nil, err)
			return
		end
		local items = {}
		for _, comment in ipairs(result.comments) do
			table.insert(items, {
				id = "comment:" .. tostring(comment.id),
				kind = "comment",
				created_at = comment.created or "",
				entity = comment,
			})
		end
		for index, entry in ipairs(result.events) do
			table.insert(items, {
				id = table.concat({ "activity", entry.date or "", index }, ":"),
				kind = "activity",
				created_at = entry.date or "",
				entity = entry,
			})
		end
		on_done(items, nil)
	end)
end

---@return AtlasGitLabIssuesViewConfig[]
local function views()
	local cfg = config.domain_options("gitlab", "issues") or {}
	local configured = cfg.views
	if not configured or #configured == 0 then
		configured = {
			{ name = "Assigned", key = "1", scope = "assigned_to_me", state = "opened" },
			{ name = "Created", key = "2", scope = "created_by_me", state = "opened" },
		}
	end
	return views_helper.resolve(configured)
end

---@param target AtlasTarget
---@return AtlasIssuesViewConfig
local function search_view(target)
	return {
		name = "Search",
		layout = "compact",
		project = target.project_path,
		scope = "all",
		state = "all",
	}
end

---@param target AtlasTarget
---@return IssueRef|nil
local function issue_ref(target)
	if target.project_path and target.number then
		return { key = string.format("%s#%d", target.project_path, target.number) }
	end
end

local M = {
	views = views,
	search_view = search_view,
	issue_ref = issue_ref,
	current_repo_project = views_helper.current_repo_project,
	capabilities = {
		core = {
			fetch_user = users_api.get_user,
			search_query = search_query,
			fetch_issues = fetch_issues,
			fetch_by_refs = issues_api.fetch_by_refs,
			fetch_issue = issues_api.fetch_issue,
			update_description = issues_api.update_description,
			fetch_linked_merge_requests = issues_api.fetch_related_merge_requests,
			fetch_linked_branches = issues_api.fetch_related_branches,
			fetch_project_branches = issues_api.fetch_project_branches,
			create_branch = issues_api.create_branch,
			fetch_milestones = milestones_api.list,
			fetch_milestone = milestones_api.get,
			fetch_milestone_issues = milestones_api.list_issues,
			fetch_milestone_merge_requests = milestones_api.list_merge_requests,
			update_milestone_description = milestones_api.update_description,
		},
		comments = {
			reaction_options = GITLAB_REACTION_OPTIONS,
			comment_completion = author_completion.for_issues,
			fetch_conversation = fetch_conversation,
			add_comment = notes_api.add_comment,
			reply_comment = notes_api.reply_comment,
			edit_comment = notes_api.edit_comment,
			delete_comment = notes_api.delete_comment,
			add_reaction = notes_api.add_reaction,
		},
		notifications = notifications_api,
		actions = actions,
		ui = {
			setup = highlights.setup,
			detail = detail_ui,
		},
	},
}

return M
