local M = {}

local icons = require("atlas.ui.shared.icons")
local navbar = require("atlas.ui.components.navbar")
local presentation = require("atlas.pulls.ui.presentation")
local providers = require("atlas.pulls.ui.dashboard.providers")
local state = require("atlas.pulls.state")
local statusline = require("atlas.ui.statusline")
local table_tree = require("atlas.ui.components.table_tree")
local ui_utils = require("atlas.ui.utils")
local utils = require("atlas.ui.shared.utils")

local PR_ICON, PR_ICON_HL = icons.pulls("pr")
local MERGED_PR_ICON, MERGED_PR_ICON_HL = icons.pulls("merged_pr")
local DECLINED_PR_ICON, DECLINED_PR_ICON_HL = icons.pulls("declined_pr")

local PR_STATE_ICON = {
	open = { PR_ICON, PR_ICON_HL },
	draft = { PR_ICON, "AtlasPRDraft" },
	merged = { MERGED_PR_ICON, MERGED_PR_ICON_HL },
	declined = { DECLINED_PR_ICON, DECLINED_PR_ICON_HL },
}

---@param pr PullRequest
---@return string, string
local function pr_icon(pr)
	local style = PR_STATE_ICON[tostring(pr.state or ""):lower()] or PR_STATE_ICON.open
	return style[1], style[2]
end

---@param pr PullRequest
---@return string
local function displayed_pr_icon(pr)
	if state.is_pr_reloading(pr.repo_full_name, pr.id) then
		return state.reload_spinner_frame
	end
	local icon = pr_icon(pr)
	return icon
end

---@param pulls PullRequest[]
---@return { repo: PullsRepo, pulls: PullRequest[] }[]
local function group_by_repo(pulls)
	local groups, by_repo = {}, {}
	for _, pr in ipairs(pulls) do
		local group = by_repo[pr.repo_full_name]
		if group == nil then
			group = { repo = presentation.repo(pr), pulls = {} }
			by_repo[pr.repo_full_name] = group
			table.insert(groups, group)
		end
		table.insert(group.pulls, pr)
	end
	return groups
end

---@param pulls PullRequest[]
---@return table[]
local function statusline_items(pulls)
	return {
		{
			text = string.format("%s %d PR%s", PR_ICON, #pulls, #pulls == 1 and "" or "s"),
			hl_group = "AtlasFooterInfo",
		},
	}
end

---@param row table
---@param col table
---@param ctx { text: string, padded: string, width: integer }
---@param display table
---@return table[]|nil
local function cell_hl(row, col, ctx, display)
	local provider_hl = display.highlight(row, col, ctx)
	if provider_hl ~= nil then
		return provider_hl
	end
	if col.key == "name" and row.kind == "repo" then
		return { { start_col = 0, end_col = #ctx.text, hl_group = "AtlasSectionHeader" } }
	end
	if col.key == "name" and row.kind == "pr" then
		local icon_hl = row._pr_reloading and "AtlasTextMuted" or (row._pr_icon_hl or "AtlasPROpen")
		local icon = row._pr_icon_str or PR_ICON
		local spans = {}
		local start = ctx.text:find(icon, 1, true)
		if start ~= nil then
			start = start - 1
			table.insert(spans, { start_col = start, end_col = start + #icon, hl_group = icon_hl })
			return spans
		end
		table.insert(spans, {
			start_col = 0,
			end_col = #state.reload_spinner_frame,
			hl_group = icon_hl,
		})
		return spans
	end
	if col.key == "pr_icon" then
		local hl = row.kind == "pr" and (row._pr_reloading and "AtlasTextMuted" or row._pr_icon_hl) or "AtlasTextMuted"
		return { { start_col = 0, end_col = #ctx.padded, hl_group = hl } }
	end
	if col.key == "created" or col.key == "updated" then
		return { { start_col = 0, end_col = #ctx.padded, hl_group = "AtlasTextMuted" } }
	end
	if col.key == "author" then
		return {
			{
				start_col = 0,
				end_col = #ctx.padded,
				hl_group = presentation.author_hl(row.author_hl or row.author),
			},
		}
	end
end

---@param row table
---@param values table
local function add_values(row, values)
	for key, value in pairs(values) do
		row[key] = value
	end
end

---@param pulls PullRequest[]
---@param display table
---@return table[]
local function compact_rows(pulls, display)
	local rows = {}
	for _, pr in ipairs(pulls) do
		local repo = presentation.repo(pr)
		local icon, icon_hl = pr_icon(pr)
		local author = presentation.user_handle(pr.author)
		local row = {
			kind = "pr",
			pr_icon = displayed_pr_icon(pr),
			_pr_reloading = state.is_pr_reloading(pr.repo_full_name, pr.id),
			_pr_icon_str = icon,
			_pr_icon_hl = icon_hl,
			repo_pr = display.reference .. tostring(pr.id or "") .. " " .. tostring(pr.title or ""),
			conversation = tostring(pr.comments_count or 0),
			author = string.format("%s %s", icons.general("user"), utils.shorten_name(author, 20)),
			author_hl = author,
			created = utils.relative_time(pr.created_on),
			updated = utils.relative_time(pr.updated_on),
			separator = true,
			_item = { kind = "pr", id = pr.id, repo = repo, pr = pr },
		}
		add_values(row, display.values(pr))
		table.insert(rows, row)
	end
	return rows
end

---@param pulls PullRequest[]
---@param layout "grouped"|"plain"
---@param display table
---@return table[]
local function list_rows(pulls, layout, display)
	local grouped = layout == "grouped"
	local groups = group_by_repo(pulls)
	if not grouped then
		groups = {}
		for _, pr in ipairs(pulls) do
			table.insert(groups, { repo = presentation.repo(pr), pulls = { pr } })
		end
	end

	local rows = {}
	for group_index, group in ipairs(groups) do
		if grouped then
			if group_index > 1 then
				table.insert(rows, { kind = "spacer" })
			end
			table.insert(rows, {
				kind = "repo",
				name = group.repo.name,
				_item = { kind = "repo", repo = group.repo },
			})
			table.insert(rows, { kind = "spacer" })
		end
		for pr_index, pr in ipairs(group.pulls) do
			if not grouped and #rows > 0 then
				table.insert(rows, { kind = "spacer" })
			end
			local repo = group.repo
			local icon = displayed_pr_icon(pr)
			local _, icon_hl = pr_icon(pr)
			local author = presentation.user_handle(pr.author)
			local row = {
				kind = "pr",
				_pr_reloading = state.is_pr_reloading(pr.repo_full_name, pr.id),
				_pr_icon_str = icon,
				_pr_icon_hl = icon_hl,
				name = icon .. " " .. display.reference .. tostring(pr.id or "") .. " " .. tostring(pr.title or ""),
				conversation = tostring(pr.comments_count or 0),
				author = string.format("%s %s", icons.general("user"), utils.shorten_name(author, 20)),
				author_hl = author,
				created = utils.relative_time(pr.created_on),
				updated = utils.relative_time(pr.updated_on),
				_item = { kind = "pr", id = pr.id, repo = repo, pr = pr },
			}
			add_values(row, display.values(pr))
			table.insert(rows, row)
			if grouped and pr_index < #group.pulls then
				table.insert(rows, { kind = "spacer" })
			end
		end
	end
	return rows
end

---@param pulls PullRequest[]
---@param layout "compact"|"grouped"|"plain"
---@param width integer
---@param display table
---@return string[], table[], table<integer, table>
local function render_table(pulls, layout, width, display)
	local compact = layout ~= "grouped" and layout ~= "plain"
	local lines, line_map, spans = table_tree.render({
		width = width,
		margin = 1,
		columns = compact and display.columns.compact or display.columns.list,
		rows = compact and compact_rows(pulls, display) or list_rows(pulls, layout, display),
		cell_hl = function(row, col, ctx)
			return cell_hl(row, col, ctx, display)
		end,
	})
	for lnum, item in pairs(line_map) do
		if item.kind == "pr" then
			local reference = display.reference .. tostring(item.pr.id)
			local start, finish = lines[lnum]:find(reference, 1, true)
			if start ~= nil then
				table.insert(spans, {
					line = lnum - 1,
					start_col = start - 1,
					end_col = finish,
					hl_group = "AtlasTextMuted",
				})
			end
		end
	end
	return lines, spans, line_map
end

---@param lines string[]
---@param text string
---@param width integer
---@param height integer
local function append_centered_loading(lines, text, width, height)
	local available_height = math.max(1, height - #lines)
	for _ = 1, math.max(0, math.floor((available_height - 1) / 2)) do
		table.insert(lines, "")
	end
	local centered = ui_utils.center_text(text, width)
	table.insert(lines, centered)
end

---@param lines string[]
---@param spans table[]
---@param width integer
local function append_separator(lines, spans, width)
	local line = string.rep("─", math.max(0, width))
	table.insert(lines, line)
	table.insert(spans, { line = #lines - 1, start_col = 0, end_col = #line, hl_group = "AtlasFilterSeparator" })
end

---@param lines string[]
---@param spans table[]
local function append_search_text(lines, spans)
	local view = state.active_view
	if view == nil or state.provider == nil then
		return
	end
	local states = {}
	for _, status in ipairs({ "OPEN", "MERGED", "DECLINED" }) do
		if state.status_filters[status] then
			table.insert(states, status:lower())
		end
	end
	local text = state.provider.capabilities.core.search_query(view, { states = states })
	if text == "" then
		return
	end
	local line = string.format(" %s %s", icons.general("search"), text)
	table.insert(lines, line)
	table.insert(spans, { line = #lines - 1, start_col = 0, end_col = #line, hl_group = "AtlasTextMuted" })
	table.insert(lines, "")
end

---@param lines string[]
---@param spans table[]
---@param width integer
local function render_navbar(lines, spans, width)
	local function view_id(view)
		return view and tostring(view.key or view.name or "") or ""
	end
	local hl = state.provider and state.provider.hl_group or "Title"

	local views = vim.list_extend({}, state.views)
	local active_id = view_id(state.active_view)
	local found = false
	for _, view in ipairs(views) do
		if view_id(view) == active_id then
			found = true
			break
		end
	end
	if state.active_view ~= nil and active_id ~= "" and not found then
		table.insert(views, state.active_view)
	end
	local nav_items = {}
	for _, view in ipairs(views) do
		table.insert(nav_items, {
			label = view.key and string.format("%s (%s)", view.name, view.key) or view.name,
			hl_group = (view_id(view) == active_id) and "AtlasFilterActive" or "AtlasTextMuted",
		})
	end
	table.insert(nav_items, { label = "|", hl_group = "AtlasTextMuted" })
	for _, status in ipairs({ "OPEN", "MERGED", "DECLINED" }) do
		local label = status:sub(1, 1):upper() .. status:sub(2):lower()
		table.insert(nav_items, {
			label = label,
			hl_group = state.status_filters[status] and "AtlasFilterActive" or "AtlasTextMuted",
		})
	end

	local actions = {}
	if state.provider and state.provider.capabilities.notifications then
		table.insert(actions, { label = "|", hl_group = "AtlasTextMuted" })
		local count = require("atlas.ui.notifications.state").unread_count or 0
		local bell, bell_hl = icons.general(count > 0 and "bell_unread" or "bell")
		table.insert(actions, {
			label = count > 0 and string.format("%s %d", bell, count) or bell,
			hl_group = bell_hl,
		})
	end
	utils.append_block(
		lines,
		spans,
		navbar.render({
			width = width,
			items = nav_items,
			actions = actions,
			active_hl = hl,
			plain_items = true,
		})
	)
end

---@param opts { width: integer, height: integer }
---@return string[], table[], table<integer, table>
function M.render(opts)
	local lines, spans, line_map = {}, {}, {}
	local pulls = state.pulls
	local display = providers.get(state.provider and state.provider.id)
	local loading = string.format("%s Loading...", state.reload_spinner_frame)
	statusline.set_items(statusline_items(pulls))

	table.insert(lines, "")
	render_navbar(lines, spans, opts.width)
	append_separator(lines, spans, opts.width)
	table.insert(lines, "")

	append_search_text(lines, spans)
	if state.error then
		local text = "Error: " .. tostring(state.error):gsub("[\r\n]+", " | ")
		utils.append_block(lines, spans, {
			lines = { text },
			highlights = { { line = 0, start_col = 0, end_col = #text, hl_group = "AtlasLogError" } },
		})
	elseif state.is_loading then
		append_centered_loading(lines, loading, opts.width, opts.height)
	else
		local layout = state.active_view and state.active_view.layout or "compact"
		local body_lines, body_spans, body_map = render_table(pulls, layout, opts.width, display)
		local base = #lines
		utils.append_block(lines, spans, { lines = body_lines, highlights = body_spans })
		for lnum, item in pairs(body_map) do
			line_map[base + lnum] = item
		end
	end
	return lines, spans, line_map
end

return M
