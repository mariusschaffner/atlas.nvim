---@type PullsProviderDetail
local M = {}

local header = require("atlas.pulls.ui.components.header")
local icons = require("atlas.ui.shared.icons")
local highlights = require("atlas.ui.shared.highlights")
local spinner = require("atlas.ui.components.spinner")
local actions = require("atlas.pulls.providers.gitlab.actions")

---@param action_id string
---@return boolean
local function supports(action_id)
	for _, action in ipairs(actions.items or {}) do
		if action.id == action_id then
			return true
		end
	end
	return false
end

---@param pr PullRequest
---@return PullsDetailHeaderField
local function remove_source_branch_field(pr)
	---@cast pr GitLabPullRequest
	return {
		label = "Delete source branch",
		kind = "toggle",
		enabled = pr.remove_source_branch == true,
	}
end

---@param hex string|nil
---@return string
local function label_fg_hl(hex)
	return highlights.label_fg_hl(hex, "AtlasGLPRLabelFg_", "AtlasChipActive")
end

---@param details PullRequestDetails|nil
---@param loading boolean
---@return PullsDetailHeaderField
local function labels_field(details, loading)
	if loading then
		return { label = "Labels", value = spinner.with_text("Loading..."), hl = "AtlasTextMuted" }
	end

	---@cast details GitLabPullRequestDetails
	local names, spans, cursor = {}, {}, 0
	for _, label in ipairs(details and details.labels or {}) do
		local name = tostring(label.name or "")
		if name ~= "" then
			table.insert(spans, { start_col = cursor, end_col = cursor + #name, hl_group = label_fg_hl(label.color) })
			table.insert(names, name)
			cursor = cursor + #name + 2
		end
	end

	if #names == 0 then
		return { label = "Labels", value = "None", hl = "AtlasTextMuted" }
	end

	return { label = "Labels", value = table.concat(names, ", "), hl = spans }
end

---@param pr PullRequest
---@param details PullRequestDetails|nil
---@param loading boolean
---@return PullsProviderHeaderFields
function M.header_fields(pr, details, loading)
	local delete_source_branch = remove_source_branch_field(pr)
	if details == nil then
		local assignee = loading and header.loading_field("Assignees") or nil
		return { assignee = assignee, delete_source_branch = delete_source_branch }
	end
	---@cast details GitLabPullRequestDetails

	local logins = {}
	for _, assignee in ipairs(details.assignees) do
		local login = tostring(assignee.username or assignee.name or "")
		if login ~= "" then
			table.insert(logins, login)
		end
	end

	local assignee_field = header.assignee_field(logins)
	assignee_field.editable = supports("edit_assignees")

	return {
		assignee = assignee_field,
		labels = labels_field(details, loading),
		delete_source_branch = delete_source_branch,
	}
end

---@return PullsDetailTab[]
function M.tabs()
	local overview_icon, overview_hl = icons.general("overview")
	local pipeline_icon, pipeline_hl = icons.pulls("pipeline")
	local conversation_icon, conversation_hl = icons.general("conversation")
	local review_icon, review_hl = icons.pulls("review")
	local commit_icon, commit_hl = icons.pulls("commit")
	return {
		{
			key = "overview",
			label = "Description",
			icon = { icon = overview_icon, hl_group = overview_hl },
			mod = require("atlas.pulls.ui.detail.tabs.overview"),
		},
		{
			key = "conversation",
			label = "Activity",
			icon = { icon = conversation_icon, hl_group = conversation_hl },
			mod = require("atlas.pulls.ui.detail.tabs.conversation"),
		},
		{
			key = "review",
			label = "Review",
			icon = { icon = review_icon, hl_group = review_hl },
			mod = require("atlas.pulls.ui.detail.tabs.review"),
		},
		{
			key = "commits",
			label = "Commits",
			icon = { icon = commit_icon, hl_group = commit_hl },
			mod = require("atlas.pulls.ui.detail.tabs.commits"),
		},
		{
			key = "pipelines",
			label = "Pipelines",
			icon = { icon = pipeline_icon, hl_group = pipeline_hl },
			mod = require("atlas.pulls.ui.detail.tabs.pipelines"),
		},
	}
end

return M
