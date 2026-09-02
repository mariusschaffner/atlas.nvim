local M = {}

local helper = require("atlas.issues.ui.presentation")
local icons = require("atlas.ui.shared.icons")
local state = require("atlas.issues.state")
local utils = require("atlas.ui.shared.utils")

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
			key = "reporter",
			name = string.format("%s Reporter", icons.general("user")),
			max_width = 22,
			can_grow = false,
		},
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
---@param col table
---@param ctx { text: string, padded: string, width: integer }
---@return table[]|nil
local function person_highlight(issue, col, ctx)
	if col.key == "assignee" then
		local name = issue.assignee and issue.assignee.display_name or nil
		return { { start_col = 0, end_col = #ctx.padded, hl_group = helper.person_hl(name) } }
	end
	if col.key == "reporter" then
		local name = issue.reporter and issue.reporter.display_name or nil
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

	local function values(issue, is_child)
		---@cast issue GitLabIssue
		local label = key_label(issue)
		local row_icon = state_icon(issue.status_id)
		return {
			icon = is_child and "" or row_icon,
			name = is_child and ("  " .. row_icon .. "  " .. label .. " " .. (issue.title or ""))
				or (label .. " " .. (issue.title or "")),
			_key_label = label,
			assignee = person_value(issue.assignee, "Unassigned"),
			reporter = person_value(issue.reporter, "Unknown"),
			status = status_value(issue),
		}
	end

	local function highlights(table_row, col, ctx)
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
					table.insert(spans, {
						start_col = title_start - 1,
						end_col = #ctx.text,
						hl_group = "Normal",
					})
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

	return { columns = columns, values = values, highlights = highlights }
end

local function default()
	return {
		columns = columns,
		values = function(issue)
			return {
				icon = "",
				name = (issue.key or "") .. " " .. (issue.title or ""),
				assignee = (issue.assignee and issue.assignee.display_name) or "Unassigned",
				reporter = (issue.reporter and issue.reporter.display_name) or "Unknown",
				status = string.format(" %s ", issue.status or ""),
			}
		end,
	}
end

local displays = {
	gitlab = gitlab(),
}
local fallback = default()

---@param provider_id string|nil
---@return table
function M.get(provider_id)
	return displays[provider_id] or fallback
end

return M
