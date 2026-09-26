local M = {}

local utils = require("atlas.ui.shared.utils")
local icons = require("atlas.ui.shared.icons")
local spinner = require("atlas.ui.components.spinner")
local field_box = require("atlas.ui.components.field_box")
local tabs = require("atlas.ui.components.tabs")
local table_tree = require("atlas.ui.components.table_tree")
local dashboard_providers = require("atlas.issues.ui.dashboard.providers")
local pulls_dashboard_renderer = require("atlas.pulls.ui.dashboard.renderer")
local pulls_dashboard_providers = require("atlas.pulls.ui.dashboard.providers")
local detail_ui = require("atlas.ui.detail")
local inline_edit = require("atlas.ui.inline_edit")
local state = require("atlas.issues.ui.detail.milestone.state")

local ns = vim.api.nvim_create_namespace("atlas.issues.milestone_detail")
local header_ns = vim.api.nvim_create_namespace("atlas.issues.milestone_detail.header")
local PADDING_X = 1
local PROGRESS_BAR_WIDTH = 16

local TABS = {
	{ key = "description", label = "Description", icon = { icon = icons.general("overview") } },
	{ key = "work_items", label = "Work Items", icon = { icon = icons.general("conversation") } },
	{ key = "merge_requests", label = "Merge Requests", icon = { icon = icons.pulls("pr") } },
}
M.tabs = TABS

---@param buf integer
---@param lines string[]
local function set_lines(buf, lines)
	if buf == nil or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
end

---@param work_items Issue[]
---@return integer completed, integer total, integer percent
local function work_item_stats(work_items)
	local total = #work_items
	local completed = 0
	for _, issue in ipairs(work_items) do
		if issue.status_id == "closed" then
			completed = completed + 1
		end
	end
	local percent = total > 0 and math.floor((completed / total) * 100 + 0.5) or 0
	return completed, total, percent
end

---@param completed integer
---@param total integer
---@param percent integer
---@return string value
---@return table[] spans
local function progress_gauge(completed, total, percent)
	local filled = math.max(0, math.min(PROGRESS_BAR_WIDTH, math.floor((percent / 100) * PROGRESS_BAR_WIDTH + 0.5)))
	local filled_str = string.rep("█", filled)
	local empty_str = string.rep("░", PROGRESS_BAR_WIDTH - filled)

	local spans = {}
	local cursor = 0
	local value = "["
	cursor = cursor + 1

	local filled_start = cursor
	value = value .. filled_str
	cursor = cursor + #filled_str
	if #filled_str > 0 then
		table.insert(spans, { start_col = filled_start, end_col = cursor, hl_group = "AtlasTextPositive" })
	end

	local empty_start = cursor
	value = value .. empty_str
	cursor = cursor + #empty_str
	if #empty_str > 0 then
		table.insert(spans, { start_col = empty_start, end_col = cursor, hl_group = "AtlasTextMuted" })
	end

	value = value .. "] "
	cursor = cursor + 2

	local pct_text = string.format("%d%%", percent)
	local pct_start = cursor
	value = value .. pct_text
	cursor = cursor + #pct_text
	table.insert(spans, {
		start_col = pct_start,
		end_col = cursor,
		hl_group = percent >= 100 and "AtlasTextPositive" or "AtlasTextMuted",
	})

	value = value .. string.format(" (%d/%d)", completed, total)

	return value, spans
end

--- Work item count + a compact bracketed gauge (e.g. "[██████░░░░] 67%
--- (2/3)"), merged into one "Progress" field box rather than two separate
--- ones.
---@return IssuesDetailHeaderField|nil
local function progress_field()
	if state.work_items_loading then
		return { label = "Progress", value = spinner.with_text("Loading..."), hl = "AtlasTextMuted" }
	end
	if state.work_items == nil then
		return nil
	end

	local completed, total, percent = work_item_stats(state.work_items)
	if total == 0 then
		return { label = "Progress", value = "No work items", hl = "AtlasTextMuted" }
	end

	local value, spans = progress_gauge(completed, total, percent)
	return { label = "Progress", value = value, hl = spans }
end

---@param milestone IssueMilestone
---@param width integer
---@return string[], table[], table<string, AtlasFieldBoxRegion>
local function render_header(milestone, width)
	local core = state.provider and state.provider.capabilities.core
	local can_edit_title = core and core.update_milestone_title ~= nil
	local can_edit_start = core and core.update_milestone_start_date ~= nil
	local can_edit_due = core and core.update_milestone_due_date ~= nil

	local title_field = {
		id = "title",
		label = utils.field_hint_label(
			"issues.change_milestone_title",
			string.format("Title - #%s", tostring(milestone.id)),
			can_edit_title
		),
		value = tostring(milestone.title or ""),
		border_hl = milestone.state == "closed" and "AtlasGLIssueClosed" or "AtlasGLIssueOpen",
		editable = can_edit_title,
	}
	local lines, spans, title_regions = field_box.render_columns({}, { width = width, top_field = title_field })
	local regions = {}
	for id, region in pairs(title_regions or {}) do
		regions[id] = region
	end

	-- One row, three columns: Start date, Due date, Progress side by side.
	local start_date_col = {
		{
			id = "start_date",
			label = utils.field_hint_label("issues.change_milestone_start_date", "Start date", can_edit_start),
			value = (milestone.start_date and milestone.start_date ~= "") and milestone.start_date or "None",
			hl = "AtlasTextMuted",
			editable = can_edit_start,
		},
	}
	local due_date_col = {
		{
			id = "due_date",
			label = utils.field_hint_label("issues.change_milestone_due_date", "Due date", can_edit_due),
			value = (milestone.due_date and milestone.due_date ~= "") and milestone.due_date or "None",
			hl = "AtlasTextMuted",
			editable = can_edit_due,
		},
	}
	local progress_col = {}
	utils.insert_if(progress_col, progress_field())

	local field_lines, field_spans, field_regions =
		field_box.render_columns({ start_date_col, due_date_col, progress_col }, { width = width })
	local base = #lines
	utils.append_block(lines, spans, { lines = field_lines, highlights = field_spans })

	for id, region in pairs(field_regions or {}) do
		regions[id] = { row = base + region.row, col = region.col, width = region.width, height = region.height }
	end

	return lines, spans, regions
end

--- Whether the description field (the "description" tab's content) can be
--- edited right now -- drives the content box's editable border color, same
--- signal `M.edit_description`'s guard uses to decide whether "i" does
--- anything.
---@return boolean
local function description_editable()
	local core = state.provider and state.provider.capabilities.core
	return state.current_tab == "description" and core ~= nil and core.update_milestone_description ~= nil
end

--- The content box's current border color -- reused for both the actual
--- border (`detail_ui.set_content_border`) and the title's non-label
--- characters, so the "-" separators/leading dash match the border instead
--- of sitting at the default `FloatTitle` color.
---@return string
local function content_border_hl()
	return description_editable() and "AtlasFieldBoxBorderEditable" or "AtlasBorder"
end

---@param active_tab string
---@return { [1]: string, [2]: string }[]
function M.title_chunks(active_tab)
	return tabs.title_chunks(TABS, active_tab, {
		active_hl = "AtlasDetailTabActive",
		inactive_hl = "AtlasTextMuted",
		gap = " - ",
		border_hl = content_border_hl(),
	})
end

---@return string[], table[]
local function render_description()
	local lines, spans = {}, {}
	if state.description_loading then
		utils.push(lines, spans, spinner.with_text("Loading description..."), "AtlasTextMuted", PADDING_X)
		return lines, spans
	end
	local description = tostring(state.description or "")
	if description == "" then
		utils.push(lines, spans, "No description", "AtlasTextMuted", PADDING_X)
	else
		local pad = string.rep(" ", PADDING_X)
		for _, line in ipairs(utils.sanitize_lines(description)) do
			table.insert(lines, pad .. line)
		end
	end
	return lines, spans
end

---@param issues Issue[]
---@return integer
local function max_key_label_width(issues)
	local display = dashboard_providers.get(state.provider and state.provider.id)
	if not display.label then
		return 0
	end
	local width = 0
	for _, issue in ipairs(issues) do
		width = math.max(width, #tostring(display.label(issue) or ""))
	end
	return width
end

---@param issue Issue
---@param label_width integer
---@return table
local function work_item_row(issue, label_width)
	local display = dashboard_providers.get(state.provider and state.provider.id)
	local row = display.values(issue, { depth = 0, is_last = true }, "plain", label_width)
	row._item = { kind = "issue", key = issue.key, _issue = issue }
	row._issue = issue
	return row
end

---@param row table
---@param col table
---@param ctx { text: string, padded: string, width: integer }
---@return table[]|nil
local function work_item_cell_hl(row, col, ctx)
	local display = dashboard_providers.get(state.provider and state.provider.id)
	return display.highlights and display.highlights(row, col, ctx) or nil
end

--- Inserts a blank line between the window's own title (the tab bar) and
--- the table header, matching the gap every other tab's content has below
--- the border. Shifts the already-1-indexed lines/spans/line_map down by
--- one to make room.
---@param lines string[]
---@param spans table[]
---@param line_map table<integer, table>
---@return string[] lines
---@return table[] spans
---@return table<integer, table> line_map
local function prepend_header_gap(lines, spans, line_map)
	table.insert(lines, 1, "")
	for _, span in ipairs(spans) do
		span.line = span.line + 1
	end
	local shifted_map = {}
	for lnum, row in pairs(line_map) do
		shifted_map[lnum + 1] = row
	end
	return lines, spans, shifted_map
end

--- Same styled, columned table as the main issue dashboard (icon/name/
--- assignee/labels/status), just a flat list -- Work Items are always
--- issues linked to this milestone, never sub-milestones, so there's no
--- tree grouping to do, and no "Child Items" column (that's only ever
--- populated for a milestone-group row, which never appears here).
---@param issues Issue[]
---@param width integer
---@return string[] lines
---@return table[] spans
---@return table<integer, table> line_map
local function render_work_items_table(issues, width)
	local display = dashboard_providers.get(state.provider and state.provider.id)
	local columns = display.columns(false)
	local label_width = max_key_label_width(issues)
	local rows = {}
	for _, issue in ipairs(issues) do
		table.insert(rows, work_item_row(issue, label_width))
	end
	local lines, line_map, spans = table_tree.render({
		width = width,
		margin = PADDING_X,
		columns = columns,
		rows = rows,
		cell_hl = work_item_cell_hl,
		header_separator = true,
	})
	return prepend_header_gap(lines, spans, line_map)
end

---@param width integer
---@return string[] lines
---@return table[] spans
---@return table<integer, table> line_map
local function render_work_items(width)
	if state.work_items_loading then
		local lines, spans = {}, {}
		utils.push(lines, spans, spinner.with_text("Loading work items..."), "AtlasTextMuted", PADDING_X)
		return lines, spans, {}
	end
	if state.work_items == nil then
		local lines, spans = {}, {}
		utils.push(lines, spans, "Work items unavailable.", "AtlasTextMuted", PADDING_X)
		return lines, spans, {}
	end
	if #state.work_items == 0 then
		local lines, spans = {}, {}
		utils.push(lines, spans, "No linked issues", "AtlasTextMuted", PADDING_X)
		return lines, spans, {}
	end
	return render_work_items_table(state.work_items, width)
end

--- Same styled, columned table as the main pulls dashboard (title/comments/
--- reviewer/dates), just a flat "plain" list -- Merge Requests are always
--- linked to this milestone's own project, so there's no repo grouping to
--- do. Unlike the main pulls dashboard's own "plain" view, rows are kept
--- back-to-back with no blank line between them (`row_spacer = false`), to
--- keep this secondary list compact.
---@param pulls PullRequest[]
---@param width integer
---@return string[] lines
---@return table[] spans
---@return table<integer, table> line_map
local function render_merge_requests_table(pulls, width)
	local display = pulls_dashboard_providers.get(state.provider and state.provider.id)
	local lines, spans, line_map = pulls_dashboard_renderer.render_table(
		pulls,
		"plain",
		width,
		display,
		{ header_separator = true, row_spacer = false }
	)
	return prepend_header_gap(lines, spans, line_map)
end

---@param width integer
---@return string[] lines
---@return table[] spans
---@return table<integer, table> line_map
local function render_merge_requests(width)
	if state.merge_requests_loading then
		local lines, spans = {}, {}
		utils.push(lines, spans, spinner.with_text("Loading merge requests..."), "AtlasTextMuted", PADDING_X)
		return lines, spans, {}
	end
	if state.merge_requests == nil then
		local lines, spans = {}, {}
		utils.push(lines, spans, "Merge requests unavailable.", "AtlasTextMuted", PADDING_X)
		return lines, spans, {}
	end
	if #state.merge_requests == 0 then
		local lines, spans = {}, {}
		utils.push(lines, spans, "No linked merge requests", "AtlasTextMuted", PADDING_X)
		return lines, spans, {}
	end
	return render_merge_requests_table(state.merge_requests, width)
end

function M.render()
	local buf = state.buf
	local win = state.win
	if buf == nil or win == nil then
		return
	end
	if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_win_is_valid(win) then
		return
	end

	local milestone = state.current_milestone
	local header_win = state.header_win
	local header_buf = state.header_buf
	local has_header = utils.window.valid(header_win) and utils.buffer.valid(header_buf)

	if has_header then
		local header_lines, header_spans, header_regions = {}, {}, {}
		if milestone ~= nil then
			header_lines, header_spans, header_regions = render_header(milestone, vim.api.nvim_win_get_width(header_win))
		end
		set_lines(header_buf, header_lines)
		utils.apply_spans(header_buf, header_ns, header_spans)
		detail_ui.resize_header(#header_lines)
		state.header_regions = header_regions or {}
	end

	detail_ui.set_content_title(M.title_chunks(state.current_tab))

	-- Leading "─ " mirrors the top title's own border-dash prefix
	-- (tabs.title_chunks), so the hint aligns with the title above it.
	local footer_chunks
	if inline_edit.is_active(buf) then
		local hl = "AtlasFieldBoxBorderEditing"
		footer_chunks = {
			{ "─ ", hl },
			{ utils.field_hint_label("ui.submit", "Save", true), hl },
			{ " ── ", hl },
			{ utils.field_hint_label("ui.field_edit.close", "Cancel", true), hl },
			{ " ", hl },
		}
	elseif description_editable() then
		local hl = content_border_hl()
		footer_chunks = {
			{ "─ ", hl },
			{ utils.field_hint_label("ui.edit_description", "Edit", true), hl },
			{ " ", hl },
		}
	elseif state.current_tab == "work_items" or state.current_tab == "merge_requests" then
		local hl = content_border_hl()
		footer_chunks = {
			{ "─ ", hl },
			{ utils.field_hint_label("ui.inspect", "Inspect", true), hl },
			{ " ", hl },
		}
	end
	detail_ui.set_content_footer(footer_chunks)

	if inline_edit.is_active(buf) then
		-- Editing owns the border color (AtlasFieldBoxBorderEditing) until it
		-- finishes, and re-rendering the content here would clobber the
		-- in-progress raw edit buffer.
		return
	end
	detail_ui.set_content_border(content_border_hl())

	local lines, spans, line_map = nil, nil, {}
	if milestone == nil then
		lines, spans = { "", "  Nothing selected..." }, {}
	elseif state.current_tab == "work_items" then
		lines, spans, line_map = render_work_items(vim.api.nvim_win_get_width(win))
	elseif state.current_tab == "merge_requests" then
		lines, spans, line_map = render_merge_requests(vim.api.nvim_win_get_width(win))
	else
		lines, spans = render_description()
	end
	state.line_map = line_map

	set_lines(buf, lines)
	utils.apply_spans(buf, ns, spans)
end

return M
