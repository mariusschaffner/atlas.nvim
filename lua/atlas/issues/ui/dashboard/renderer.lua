local M = {}

local state = require("atlas.issues.state")
local navbar = require("atlas.ui.components.navbar")
local table_tree = require("atlas.ui.components.table_tree")
local utils = require("atlas.ui.shared.utils")
local icons = require("atlas.ui.shared.icons")
local providers = require("atlas.issues.ui.dashboard.providers")

---@param lines string[]
---@param spans table[]
---@param width integer
local function render_filter_row(lines, spans, width)
	local active_index = nil
	for i, v in ipairs(state.views) do
		if v == state.active_view then
			active_index = i
			break
		end
	end
	local badge = active_index and string.format("[%d]", active_index) or "[*]"
	local search_icon = icons.general("search")

	local nav_items = {
		{ label = badge, hl_group = "AtlasFilterActive" },
		{ label = string.format("%s %s", search_icon, state.filter_text or ""), hl_group = "AtlasTextMuted" },
	}

	local status_items = {}
	for _, status in ipairs({ "OPEN", "CLOSED" }) do
		table.insert(status_items, {
			label = status:sub(1, 1):upper() .. status:sub(2):lower(),
			hl_group = state.status_filters[status] and "AtlasFilterActive" or "AtlasTextMuted",
		})
	end

	local filter_line = #lines
	utils.append_block(
		lines,
		spans,
		navbar.render({
			width = width,
			items = nav_items,
			actions = status_items,
			plain_items = true,
		})
	)
	table.insert(spans, { line = filter_line, line_hl_group = "AtlasFilterBarBackground" })
end

---@param issue Issue
---@param is_child boolean|nil
---@param layout "plain"|"compact"
---@return table
local function issue_to_row(issue, is_child, layout)
	local display = providers.get(state.provider and state.provider.id)
	local row_data = display.values(issue, is_child == true, layout)

	row_data._item = { kind = "issue", key = issue.key, _issue = issue }
	row_data._issue = issue
	row_data.children = row_data.children or {}
	return row_data
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
	if col.key == "icon" and row._fold_icon_hl then
		return { { start_col = 0, end_col = #ctx.padded, hl_group = row._fold_icon_hl } }
	end
	local display = providers.get(state.provider and state.provider.id)
	return display.highlights and display.highlights(row, col, ctx) or nil
end

---@param issue_groups IssuesGroup[]
---@return table[]
local function issues_to_rows(issue_groups)
	local rows = {}
	for i, group in ipairs(issue_groups) do
		local children = group.children
		local root_row = issue_to_row(group.issue, false, "plain")

		for _, child in ipairs(children) do
			table.insert(root_row.children, issue_to_row(child, true, "plain"))
		end
		if #children > 0 then
			local issue_key = tostring(group.issue.key or "")
			local collapsed = state.collapsed_issue_keys[issue_key] == true
			root_row.icon, root_row._fold_icon_hl = icons.general(collapsed and "fold_closed" or "fold_open")
		end

		if i < #issue_groups then
			root_row.separator = true
		end
		table.insert(rows, root_row)
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
		tree = {
			column_key = "icon",
			children_key = "children",
			default_expanded = true,
			indent = "",
			show_indicator = should_show_indicator(issue_groups),
			leaf_prefix = "",
			is_expanded = function(row)
				local issue = row._issue
				local issue_key = issue and tostring(issue.key or "") or ""
				if issue_key == "" then
					return true
				end
				return state.collapsed_issue_keys[issue_key] ~= true
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
	local rows = {}
	for _, issue in ipairs(issues) do
		local row = issue_to_row(issue, false, "compact")
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
			meta.separator = true
			meta._item = { kind = "issue_meta", key = issue.key, _issue = issue }
			table.insert(rows, meta)
		else
			row.separator = true
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
		cell_hl = cell_hl,
	})
end

---@param opts { width: integer }
---@return string[], table[], table<integer, table>
function M.render(opts)
	local active = state.active_view

	local lines, spans = {}, {}
	local line_map = {}

	table.insert(lines, "")
	render_filter_row(lines, spans, opts.width)

	table.insert(lines, "")

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
