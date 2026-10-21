---@type IssuesProviderDetail
local M = {}

local icons = require("atlas.ui.shared.icons")
local helper = require("atlas.issues.ui.presentation")
local highlights = require("atlas.ui.shared.highlights")
local actions = require("atlas.issues.providers.gitlab.actions")
local utils = require("atlas.ui.shared.utils")

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

---@param issue Issue
---@return IssuesTitleStatus
function M.title_status(issue)
	---@cast issue GitLabIssue
	local closed = issue.status_id == "closed"
	return {
		text = tostring(issue.status or (closed and "Closed" or "Open")),
		hl = closed and "AtlasGLIssueClosedPillChip" or "AtlasGLIssueOpenChip",
	}
end

---@param hex string|nil
---@return string
local function label_chip_hl(hex)
	return highlights.label_hl(hex, "AtlasGLIssueLabelChip_", "AtlasChipActive")
end

---@class IssuesGitLabHeaderData
---@field labels { name: string, color: string|nil }[]
---@field labels_editable boolean
---@field milestone { title: string, id: integer|nil }|nil
---@field milestone_editable boolean
---@field assignees IssueUser[]
---@field assignee_editable boolean
---@field author_name string

---@param issue Issue
---@param details IssueDetails|nil
---@param loading boolean
---@return IssuesGitLabHeaderData
function M.header_fields(issue, details, loading)
	local assignees = {}
	if details and details.assignees and #details.assignees > 0 then
		assignees = details.assignees
	elseif issue.assignee then
		assignees = { issue.assignee }
	end

	local milestone = details and details.milestone or nil
	local reporter_name = issue.reporter and tostring(issue.reporter.display_name or "") or ""

	return {
		labels = (not loading) and (details and details.labels or {}) or {},
		labels_editable = supports("labels"),
		milestone = milestone and { title = milestone.title, id = milestone.id } or nil,
		milestone_editable = supports("milestone") and helper.is_open(issue),
		assignees = assignees,
		assignee_editable = supports("assign") and helper.is_open(issue),
		author_name = reporter_name ~= "" and reporter_name or "Unknown",
	}
end

---@param hex string|nil
---@return string
function M.label_chip_hl(hex)
	return label_chip_hl(hex)
end

---@return IssuesDetailTabDefinition[]
function M.tabs()
	local overview_icon, overview_hl = icons.general("overview")
	local conversation_icon, conversation_hl = icons.general("conversation")
	local pr_icon, pr_hl = icons.pulls("pr")
	return {
		{
			key = "overview",
			label = "Description",
			icon = { icon = overview_icon, hl_group = overview_hl },
			mod = require("atlas.issues.ui.detail.tabs.overview"),
		},
		{
			key = "conversation",
			label = "Activity",
			icon = { icon = conversation_icon, hl_group = conversation_hl },
			mod = require("atlas.issues.ui.detail.tabs.conversation"),
		},
		{
			key = "merge_requests",
			label = "Merge requests",
			icon = { icon = pr_icon, hl_group = pr_hl },
			mod = require("atlas.issues.ui.detail.tabs.merge_requests"),
		},
	}
end

return M
