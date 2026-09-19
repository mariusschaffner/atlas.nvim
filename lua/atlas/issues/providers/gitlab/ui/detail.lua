---@type IssuesProviderDetail
local M = {}

local icons = require("atlas.ui.shared.icons")
local helper = require("atlas.issues.ui.presentation")
local spinner = require("atlas.ui.components.spinner")
local highlights = require("atlas.ui.shared.highlights")
local actions = require("atlas.issues.providers.gitlab.actions")

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

---@param status_id string|nil
---@return string
local function state_fg_hl(status_id)
	if status_id == "closed" then
		return "AtlasGLIssueClosed"
	end
	return "AtlasGLIssueOpen"
end

---@param issue Issue
---@return IssuesTitleStatus
function M.title_status(issue)
	---@cast issue GitLabIssue
	return {
		text = tostring(issue.status or "Open"),
		hl = state_fg_hl(issue.status_id),
		label = string.format("Title - %s", tostring(issue.iid)),
	}
end

---@param hex string|nil
---@return string
local function label_fg_hl(hex)
	return highlights.label_fg_hl(hex, "AtlasGLIssueLabelFg_", "AtlasChipActive")
end

---@param details IssueDetails|nil
---@param loading boolean
---@return IssuesDetailHeaderField
local function labels_field(details, loading)
	if loading then
		return {
			id = "labels",
			label = "Labels",
			value = spinner.with_text("Loading..."),
			hl = "AtlasTextMuted",
			editable = supports("labels"),
		}
	end

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
		return { id = "labels", label = "Labels", value = "None", hl = "AtlasTextMuted", editable = supports("labels") }
	end

	return {
		id = "labels",
		label = "Labels",
		value = table.concat(names, ", "),
		hl = spans,
		editable = supports("labels"),
	}
end

---@param issue Issue
---@param details IssueDetails|nil
---@param loading boolean
---@return IssuesProviderHeaderFields
function M.header_fields(issue, details, loading)
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

	return {
		-- No icon here: Author now renders as plain informational text
		-- (Author/MR/Branch info line below the field boxes), not a box.
		author = {
			label = "Author",
			value = reporter_name,
			hl = helper.person_hl(reporter_name),
		},
		assignee = {
			id = "assignee",
			label = "Assignee",
			value = assignee_text,
			hl = assignee_hl,
			editable = supports("assign"),
		},
		labels = labels_field(details, loading),
		milestone = milestone_text ~= "" and { label = "Milestone", value = milestone_text, hl = "AtlasTextMuted" } or nil,
	}
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
