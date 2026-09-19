local M = {}

local helper = require("atlas.issues.ui.presentation")
local icons = require("atlas.ui.shared.icons")
local state = require("atlas.issues.state")
local utils = require("atlas.ui.shared.utils")
local highlights = require("atlas.ui.shared.highlights")

local LABELS_ICON = icons.pulls("tag")
local MILESTONE_ICON, MILESTONE_ICON_HL = icons.general("milestone")

---@param hex string|nil
---@return string
local function label_hl(hex)
	return highlights.label_fg_hl(hex, "AtlasGLIssueLabelFg_", "AtlasChipActive")
end

---@param depth integer
---@param is_last boolean|nil
---@return string
local function tree_prefix(depth, is_last)
	if depth <= 0 then
		return ""
	end
	local indent = string.rep("  ", depth - 1)
	return indent .. (is_last and "└─ " or "├─ ")
end

local function columns()
	return {
		{ key = "icon", name = "", can_grow = false, align = "center" },
		{ key = "name", name = "Issue" },
		{
			key = "assignee",
			name = string.format("%s Assignee", icons.general("user")),
			max_width = 22,
			can_grow = false,
		},
		{
			key = "labels",
			name = string.format("%s Labels", LABELS_ICON),
			max_width = 22,
			can_grow = false,
		},
		{ key = "children_count", name = "Child Items", can_grow = false, align = "center" },
		{ key = "status", name = " Status", can_grow = false },
	}
end

---@param issue Issue
---@return string
local function status_value(issue)
	local issue_key = tostring(issue.key or "")
	if issue_key ~= "" and state.reloading_issue_keys[issue_key] then
		return string.format(" %s ", state.reload_spinner_frame)
	end
	return string.format(" %s ", issue.status or "")
end

---@param user IssueUser|nil
---@param fallback string
---@return string
local function person_value(user, fallback)
	local name = user and user.display_name or fallback
	return string.format("%s %s", icons.general("user"), utils.shorten_name(name, 20))
end

---@param issue Issue
---@return string
local function labels_value(issue)
	local names = {}
	for _, label in ipairs(issue.labels or {}) do
		local name = tostring(label.name or "")
		if name ~= "" then
			table.insert(names, name)
		end
	end
	if #names == 0 then
		return ""
	end
	return string.format("%s %s", LABELS_ICON, utils.truncate(table.concat(names, ", "), 20))
end

---@param issue Issue
---@param col table
---@param ctx { text: string, padded: string, width: integer }
---@return table[]|nil
local function person_highlight(issue, col, ctx)
	if col.key == "assignee" then
		local name = issue.assignee and issue.assignee.display_name or nil
		return { { start_col = 0, end_col = #ctx.padded, hl_group = helper.person_hl(name) } }
	end
end

local function gitlab()
	local function state_icon(status_id)
		if status_id == "closed" then
			return icons.pulls_status("successful"), "AtlasGLIssueClosed"
		end
		return icons.issues("issue"), "AtlasGLIssueOpen"
	end

	local function state_chip_hl(status_id)
		return status_id == "closed" and "AtlasGLIssueClosedChip" or "AtlasGLIssueOpenChip"
	end

	---@param issue GitLabIssue
	local function key_label(issue)
		return string.format("#%d", issue.iid)
	end

	---@param label string
	---@param width integer|nil
	---@return string
	local function pad_label(label, width)
		if width == nil or width <= #label then
			return label
		end
		return label .. string.rep(" ", width - #label)
	end

	---@param issue GitLabIssue
	---@param opts { depth: integer, is_last: boolean|nil }|nil
	local function values(issue, opts, _layout, label_width)
		---@cast issue GitLabIssue
		opts = opts or {}
		local depth = opts.depth or 0
		local label = key_label(issue)
		local padded_label = pad_label(label, label_width)
		local row_icon = state_icon(issue.status_id)
		local prefix = tree_prefix(depth, opts.is_last)
		return {
			icon = depth > 0 and "" or row_icon,
			name = depth > 0 and (prefix .. row_icon .. "  " .. padded_label .. " " .. (issue.title or ""))
				or (padded_label .. " " .. (issue.title or "")),
			_key_label = label,
			assignee = person_value(issue.assignee, "Unassigned"),
			labels = labels_value(issue),
			children_count = "",
			status = status_value(issue),
		}
	end

	---@param milestone IssueMilestone
	---@param child_count integer
	local function milestone_values(milestone, child_count)
		return {
			icon = MILESTONE_ICON,
			name = string.format("Milestone: %s", tostring(milestone.title or "")),
			assignee = "",
			labels = "",
			children_count = tostring(child_count),
			status = "",
		}
	end

	local function highlights(table_row, col, ctx)
		local milestone = table_row._milestone
		if milestone ~= nil then
			if col.key == "icon" then
				local start_col, end_col = ctx.text:find(MILESTONE_ICON, 1, true)
				if start_col then
					return { { start_col = start_col - 1, end_col = end_col, hl_group = MILESTONE_ICON_HL } }
				end
				return nil
			end
			if col.key == "name" then
				return { { start_col = 0, end_col = #ctx.padded, hl_group = "AtlasGLMilestone" } }
			end
			if col.key == "children_count" then
				return { { start_col = 0, end_col = #ctx.padded, hl_group = "AtlasTextMuted" } }
			end
			return nil
		end

		local issue = table_row._issue
		if issue == nil then
			return nil
		end
		---@cast issue GitLabIssue

		if col.key == "icon" then
			local icon, icon_hl = state_icon(issue.status_id)
			local start_col, end_col = ctx.text:find(icon, 1, true)
			if start_col then
				return { { start_col = start_col - 1, end_col = end_col, hl_group = icon_hl } }
			end
		end

		if col.key == "name" then
			local spans = {}
			if (tonumber(table_row._tv2_depth) or 0) > 0 then
				local icon, icon_hl = state_icon(issue.status_id)
				local start_col, end_col = ctx.text:find(icon, 1, true)
				if start_col then
					table.insert(spans, { start_col = start_col - 1, end_col = end_col, hl_group = icon_hl })
				end
			end

			local label = table_row._key_label or key_label(issue)
			local start_col, end_col = ctx.text:find(label, 1, true)
			if start_col then
				table.insert(spans, { start_col = start_col - 1, end_col = end_col, hl_group = "AtlasTextMuted" })
				local title_start = end_col + 2
				if title_start <= #ctx.text then
					local title_hl = issue.assignee == nil and "AtlasTextMuted" or "Normal"
					table.insert(spans, {
						start_col = title_start - 1,
						end_col = #ctx.text,
						hl_group = title_hl,
					})
				end
			end
			return #spans > 0 and spans or nil
		end

		if col.key == "labels" then
			local spans = {}
			local cursor = 1
			local icon_start, icon_end = ctx.text:find(LABELS_ICON, cursor, true)
			if icon_start then
				table.insert(spans, { start_col = icon_start - 1, end_col = icon_end, hl_group = "AtlasTextWarning" })
				cursor = icon_end + 1
			end
			for _, label in ipairs(issue.labels or {}) do
				local name = tostring(label.name or "")
				if name ~= "" then
					local start_col, end_col = ctx.text:find(name, cursor, true)
					if start_col then
						table.insert(spans, { start_col = start_col - 1, end_col = end_col, hl_group = label_hl(label.color) })
						cursor = end_col + 1
					end
				end
			end
			return #spans > 0 and spans or nil
		end

		if col.key == "status" then
			local issue_key = tostring(issue.key or "")
			local hl = issue_key ~= "" and state.reloading_issue_keys[issue_key] and "AtlasTextMuted"
				or state_chip_hl(issue.status_id)
			return { { start_col = 0, end_col = #ctx.padded, hl_group = hl } }
		end
		return person_highlight(issue, col, ctx)
	end

	return {
		columns = columns,
		values = values,
		milestone_values = milestone_values,
		highlights = highlights,
		label = key_label,
	}
end

local displays = {
	gitlab = gitlab(),
}

---@param provider_id string|nil
---@return table
function M.get(provider_id)
	-- GitLab is the only provider atlas.providers ever registers, so this
	-- falls back to it rather than a separate (and previously unreachable)
	-- generic display.
	return displays[provider_id] or displays.gitlab
end

return M
