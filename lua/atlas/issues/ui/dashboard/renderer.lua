local M = {}

local state = require("atlas.issues.state")
local table_tree = require("atlas.ui.components.table_tree")
local utils = require("atlas.ui.shared.utils")
local icons = require("atlas.ui.shared.icons")
local providers = require("atlas.issues.ui.dashboard.providers")

---@param issue Issue
---@param opts { depth: integer, is_last: boolean|nil }|nil
---@param layout "plain"|"compact"
---@param label_width integer|nil
---@return table
local function issue_to_row(issue, opts, layout, label_width)
	local display = providers.get(state.provider and state.provider.id)
	local row_data = display.values(issue, opts, layout, label_width)

	row_data._item = { kind = "issue", key = issue.key, _issue = issue }
	row_data._issue = issue
	row_data.children = row_data.children or {}
	return row_data
end

---@param milestone IssueMilestone
---@param child_count integer
---@return table
local function milestone_to_row(milestone, child_count)
	local display = providers.get(state.provider and state.provider.id)
	local key = "milestone:" .. tostring(milestone.id)
	local row_data = display.milestone_values and display.milestone_values(milestone, child_count) or {}

	row_data._item = { kind = "milestone", key = key, _milestone = milestone }
	row_data._milestone = milestone
	row_data.children = row_data.children or {}
	return row_data
end

---@param issues Issue[]
---@return integer
local function max_label_width(issues)
	local display = providers.get(state.provider and state.provider.id)
	if not display.label then
		return 0
	end
	local width = 0
	for _, issue in ipairs(issues) do
		width = math.max(width, #tostring(display.label(issue) or ""))
	end
	return width
end

---@param columns table[]
---@return table
local function blank_row(columns)
	local row = {}
	for _, column in ipairs(columns) do
		row[column.key] = ""
	end
	return row
end

---@param row table
---@param col table
---@param ctx { text: string, padded: string, width: integer }
---@return table[]|nil
local function cell_hl(row, col, ctx)
	if row.kind == "meta" then
		return { { start_col = 0, end_col = #ctx.padded, hl_group = "AtlasTextMuted" } }
	end
	local display = providers.get(state.provider and state.provider.id)
	return display.highlights and display.highlights(row, col, ctx) or nil
end

---@param issue_groups IssuesGroup[]
---@param out Issue[]
local function collect_issues(issue_groups, out)
	for _, group in ipairs(issue_groups) do
		if group.kind == "milestone" then
			collect_issues(group.children, out)
		else
			table.insert(out, group.issue)
			for _, child in ipairs(group.children) do
				table.insert(out, child)
			end
		end
	end
end

---@param issue_groups IssuesGroup[]
---@return Issue[]
local function flatten_issues(issue_groups)
	local issues = {}
	collect_issues(issue_groups, issues)
	return issues
end

---@param group IssuesGroup
---@param depth integer
---@param is_last boolean
---@param label_width integer|nil
---@return table
local function group_to_row(group, depth, is_last, label_width)
	if group.kind == "milestone" then
		local row = milestone_to_row(group.milestone, #group.children)
		local count = #group.children
		for index, child_group in ipairs(group.children) do
			table.insert(row.children, group_to_row(child_group, depth + 1, index == count, label_width))
		end
		return row
	end

	local row = issue_to_row(group.issue, { depth = depth, is_last = is_last }, "plain", label_width)
	local count = #group.children
	for index, child_issue in ipairs(group.children) do
		table.insert(
			row.children,
			issue_to_row(child_issue, { depth = depth + 1, is_last = index == count }, "plain", label_width)
		)
	end
	return row
end

---@param issue_groups IssuesGroup[]
---@return table[]
local function issues_to_rows(issue_groups)
	local label_width = max_label_width(flatten_issues(issue_groups))
	local rows = {}
	local count = #issue_groups
	for index, group in ipairs(issue_groups) do
		table.insert(rows, group_to_row(group, 0, index == count, label_width))
	end
	return rows
end

---@param issue_groups IssuesGroup[]
---@return boolean
local function should_show_indicator(issue_groups)
	for _, group in ipairs(issue_groups) do
		if #group.children > 0 then
			return true
		end
	end
	return false
end

---@param opts { width: integer }
---@param issue_groups IssuesGroup[]
---@return string[], table<integer, table>, table[]
local function render_issue_table(opts, issue_groups)
	local display = providers.get(state.provider and state.provider.id)
	local columns = display.columns("plain")
	local rows = issues_to_rows(issue_groups)
	if state.is_loading then
		table.insert(rows, blank_row(columns))
		local loading = blank_row(columns)
		loading.icon = state.reload_spinner_frame
		loading.name = "Loading..."
		table.insert(rows, loading)
	end

	return table_tree.render({
		width = opts.width,
		margin = 1,
		columns = columns,
		rows = rows,
		header_separator = true,
		tree = {
			column_key = "icon",
			children_key = "children",
			default_expanded = true,
			indent = "",
			show_indicator = should_show_indicator(issue_groups),
			leaf_prefix = "",
			is_expanded = function(row)
				local key = row._item and tostring(row._item.key or "") or ""
				if key == "" then
					return true
				end
				return state.collapsed_issue_keys[key] ~= true
			end,
		},
		cell_hl = cell_hl,
	})
end

---@param issue Issue
---@return string
local function issue_meta_text(issue)
	local parts = {}
	---@cast issue GitLabIssue
	local repository = issue.project_path
	if repository and repository ~= "" then
		table.insert(parts, repository)
	end
	local type_name = issue.type and tostring(issue.type.name or "") or ""
	if type_name ~= "" then
		table.insert(parts, type_name)
	end
	local due = utils.format_date(issue.duedate)
	if due ~= "" then
		table.insert(parts, string.format("%s %s", icons.general("created"), due))
	end
	if issue.story_points ~= nil then
		table.insert(parts, string.format("%s pts", tostring(issue.story_points)))
	end
	return table.concat(parts, "  ")
end

---@param issues Issue[]
---@return table[], table[]
local function compact_rows(issues)
	local display = providers.get(state.provider and state.provider.id)
	local columns = display.columns("compact")
	local label_width = max_label_width(issues)
	local rows = {}
	for _, issue in ipairs(issues) do
		local row = issue_to_row(issue, nil, "compact", label_width)
		row.children = nil
		table.insert(rows, row)

		local meta_text = row._meta
		if meta_text == nil then
			meta_text = issue_meta_text(issue)
		end
		if meta_text ~= "" then
			local meta = blank_row(columns)
			meta.kind = "meta"
			meta.name = meta_text
			meta._item = { kind = "issue_meta", key = issue.key, _issue = issue }
			table.insert(rows, meta)
		end
	end

	return rows, columns
end

---@param opts { width: integer }
---@param issues Issue[]
---@return string[], table<integer, table>, table[]
local function render_compact_table(opts, issues)
	local rows, columns = compact_rows(issues)
	if state.is_loading then
		table.insert(rows, blank_row(columns))
		local loading = blank_row(columns)
		loading.icon = state.reload_spinner_frame
		loading.name = "Loading..."
		table.insert(rows, loading)
	end

	return table_tree.render({
		width = opts.width,
		margin = 1,
		columns = columns,
		rows = rows,
		header_separator = true,
		cell_hl = cell_hl,
	})
end

---@param opts { width: integer }
---@return string[], table[], table<integer, table>
function M.render(opts)
	local active = state.active_view

	local lines, spans = {}, {}
	local line_map = {}

	if state.error then
		local err_text = "Error: " .. state.error
		utils.append_block(lines, spans, {
			lines = { err_text },
			highlights = {
				{ line = 0, start_col = 0, end_col = #err_text, hl_group = "AtlasLogError" },
			},
		})
	else
		local issue_groups = state.issue_tree
		local layout = active and tostring(active.layout or "plain") or "plain"
		if layout ~= "compact" then
			layout = "plain"
		end
		local issues = state.issues

		local has_rows = #issue_groups > 0
		if layout == "compact" then
			has_rows = #issues > 0
		end
		if state.is_loading ~= true and not has_rows then
			table.insert(lines, "No issues found.")
		else
			local tbl_lines, tbl_spans, tbl_map
			if layout == "compact" then
				tbl_lines, tbl_map, tbl_spans = render_compact_table(opts, issues)
			else
				tbl_lines, tbl_map, tbl_spans = render_issue_table(opts, issue_groups)
			end

			local table_base = #lines
			utils.append_block(lines, spans, { lines = tbl_lines, highlights = tbl_spans })

			for lnum, node in pairs(tbl_map) do
				line_map[table_base + lnum] = node
			end
		end
	end

	return lines, spans, line_map
end

return M
