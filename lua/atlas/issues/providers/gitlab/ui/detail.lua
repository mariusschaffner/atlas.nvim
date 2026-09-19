---@type IssuesProviderDetail
local M = {}

local icons = require("atlas.ui.shared.icons")
local helper = require("atlas.issues.ui.presentation")
local spinner = require("atlas.ui.components.spinner")
local highlights = require("atlas.ui.shared.highlights")

---@param status_id string|nil
---@return string
local function state_chip_hl(status_id)
	if status_id == "closed" then
		return "AtlasGLIssueClosedChip"
	end
	return "AtlasGLIssueOpenChip"
end

---@param issue Issue
---@param details IssueDetails|nil
---@param loading boolean
---@return IssuesDetailHeaderField[]
function M.header_fields(issue, details, _loading)
	local user_icon = icons.general("user")

	local assignee = details and details.assignees[1] or issue.assignee
	local assignee_name = assignee and tostring(assignee.display_name or "") or ""
	local reporter_name = issue.reporter and tostring(issue.reporter.display_name or "") or ""
	if assignee_name == "" then
		assignee_name = "Unassigned"
	end
	if reporter_name == "" then
		reporter_name = "Unknown"
	end

	local milestone_text = details and details.milestone and details.milestone.title or ""
	local assignee_text = string.format("%s %s", user_icon, assignee_name)
	local assignee_hl = helper.person_hl(assignee and assignee.display_name or nil)

	local fields = {
		{
			label = "Status",
			value = tostring(issue.status or "Open"),
			hl = state_chip_hl(issue.status_id),
		},
		{
			label = "Author",
			value = string.format("%s %s", user_icon, reporter_name),
			hl = helper.person_hl(reporter_name),
		},
		{ label = "Assignee", value = assignee_text, hl = assignee_hl },
	}
	if milestone_text ~= "" then
		table.insert(fields, { label = "Milestone", value = milestone_text, hl = "AtlasTextMuted" })
	end

	return fields
end

---@param hex string|nil
---@return string
local function label_hl(hex)
	return highlights.label_hl(hex, "AtlasGLIssueLabel_", "AtlasChipActive")
end

---@param _issue Issue
---@param details IssueDetails|nil
---@param loading boolean
---@return IssuesDetailChip[]
function M.chips(_issue, details, loading)
	local chips = {}
	if loading then
		table.insert(chips, { label = spinner.with_text("Loading..."), hl = "AtlasTextMuted" })
		return chips
	end

	for _, label in ipairs(details and details.labels or {}) do
		local name = tostring(label.name or "")
		if name ~= "" then
			table.insert(chips, { label = name, hl = label_hl(label.color) })
		end
	end
	return chips
end

---@return IssuesDetailTabDefinition[]
function M.tabs()
	local overview_icon, overview_hl = icons.general("overview")
	local conversation_icon, conversation_hl = icons.general("conversation")
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
	}
end

return M
