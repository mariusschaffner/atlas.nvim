local M = {}

local utils = require("atlas.ui.shared.utils")
local icons = require("atlas.ui.shared.icons")
local spinner = require("atlas.ui.components.spinner")
local field_box = require("atlas.ui.components.field_box")
local tabs = require("atlas.ui.components.tabs")
local detail_ui = require("atlas.ui.detail")
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
---@return string[], table[]
local function render_header(milestone, width)
	local title_field = {
		label = string.format("Title - %s", tostring(milestone.id)),
		value = tostring(milestone.title or ""),
		border_hl = milestone.state == "closed" and "AtlasGLIssueClosed" or "AtlasGLIssueOpen",
	}
	local lines, spans = field_box.render_columns({}, { width = width, top_field = title_field })

	-- One row, three columns: Start date, Due date, Progress side by side.
	local start_date_col = {}
	if milestone.start_date and milestone.start_date ~= "" then
		table.insert(start_date_col, { label = "Start date", value = milestone.start_date, hl = "AtlasTextMuted" })
	end
	local due_date_col = {}
	if milestone.due_date and milestone.due_date ~= "" then
		table.insert(due_date_col, { label = "Due date", value = milestone.due_date, hl = "AtlasTextMuted" })
	end
	local progress_col = {}
	utils.insert_if(progress_col, progress_field())

	local field_lines, field_spans =
		field_box.render_columns({ start_date_col, due_date_col, progress_col }, { width = width })
	utils.append_block(lines, spans, { lines = field_lines, highlights = field_spans })
	table.insert(lines, "")

	local tab_lines, tab_spans = tabs.render(TABS, state.current_tab, width, {
		active_hl = "AtlasFilterActive",
		inactive_hl = "AtlasTextMuted",
		gap = " ",
		padding_x = PADDING_X,
	})
	utils.append_block(lines, spans, { lines = tab_lines, highlights = tab_spans })

	return lines, spans
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

---@param items table[]|nil
---@param loading boolean
---@param loading_text string
---@param empty_text string
---@param unavailable_text string
---@return string[], table[]
local function render_bare_list(items, loading, loading_text, empty_text, unavailable_text)
	local lines, spans = {}, {}
	if loading then
		utils.push(lines, spans, spinner.with_text(loading_text), "AtlasTextMuted", PADDING_X)
		return lines, spans
	end
	if items == nil then
		utils.push(lines, spans, unavailable_text, "AtlasTextMuted", PADDING_X)
		return lines, spans
	end
	if #items == 0 then
		utils.push(lines, spans, empty_text, "AtlasTextMuted", PADDING_X)
		return lines, spans
	end
	for _, item in ipairs(items) do
		local text = string.format("%s  %s", tostring(item.key or ""), tostring(item.title or ""))
		utils.push(lines, spans, text, nil, PADDING_X)
	end
	return lines, spans
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
		local header_lines, header_spans = {}, {}
		if milestone ~= nil then
			header_lines, header_spans = render_header(milestone, vim.api.nvim_win_get_width(header_win))
		end
		set_lines(header_buf, header_lines)
		utils.apply_spans(header_buf, header_ns, header_spans)
		detail_ui.resize_header(#header_lines)
	end

	local lines, spans
	if milestone == nil then
		lines, spans = { "", "  Nothing selected..." }, {}
	elseif state.current_tab == "work_items" then
		lines, spans =
			render_bare_list(state.work_items, state.work_items_loading, "Loading work items...", "No linked issues", "Work items unavailable.")
	elseif state.current_tab == "merge_requests" then
		lines, spans = render_bare_list(
			state.merge_requests,
			state.merge_requests_loading,
			"Loading merge requests...",
			"No linked merge requests",
			"Merge requests unavailable."
		)
	else
		lines, spans = render_description()
	end

	set_lines(buf, lines)
	utils.apply_spans(buf, ns, spans)
end

return M
