local M = {}

local utils = require("atlas.ui.shared.utils")
local icons = require("atlas.ui.shared.icons")
local spinner = require("atlas.ui.components.spinner")
local table_tree = require("atlas.ui.components.table_tree")
local tabs = require("atlas.ui.components.tabs")
local detail_ui = require("atlas.ui.detail")
local state = require("atlas.issues.ui.detail.milestone.state")

local ns = vim.api.nvim_create_namespace("atlas.issues.milestone_detail")
local header_ns = vim.api.nvim_create_namespace("atlas.issues.milestone_detail.header")
local PADDING_X = 1
local BAR_WIDTH = 24

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

---@param percent integer
---@param width integer
---@return string, integer filled_len
local function progress_bar(percent, width)
	local filled = math.max(0, math.min(width, math.floor((percent / 100) * width + 0.5)))
	return string.rep("█", filled) .. string.rep("░", width - filled), filled
end

---@param milestone IssueMilestone
---@param width integer
---@return string[], table[]
local function render_header(milestone, width)
	local title_line = string.format(" %s %s", icons.general("milestone"), tostring(milestone.title or ""))

	local fields = {}
	if milestone.state then
		table.insert(fields, {
			k1 = "Status:",
			v1 = milestone.state == "closed" and "Closed" or "Active",
			v1_hl = milestone.state == "closed" and "AtlasGLIssueClosedChip" or "AtlasGLIssueOpenChip",
		})
	end
	if milestone.start_date and milestone.start_date ~= "" then
		table.insert(fields, { k1 = "Start date:", v1 = milestone.start_date, v1_hl = "AtlasTextMuted" })
	end
	if milestone.due_date and milestone.due_date ~= "" then
		table.insert(fields, { k1 = "Due date:", v1 = milestone.due_date, v1_hl = "AtlasTextMuted" })
	end

	local completed, total, percent
	if state.work_items_loading then
		table.insert(fields, { k1 = "Work items:", v1 = spinner.with_text("Loading..."), v1_hl = "AtlasTextMuted" })
	elseif state.work_items ~= nil then
		completed, total, percent = work_item_stats(state.work_items)
		table.insert(fields, { k1 = "Work items:", v1 = tostring(total), v1_hl = "AtlasTextMuted" })
	end

	local field_lines, field_spans = {}, {}
	if #fields > 0 then
		field_lines, _, field_spans = table_tree.render({
			columns = {
				{ key = "k1", name = "", can_grow = false },
				{ key = "v1", name = "", can_grow = true, grow_last = true },
			},
			rows = fields,
			width = width,
			margin = 1,
			show_header = false,
			column_gap = 2,
			fill = true,
			cell_hl = function(row, col)
				if col.key == "k1" then
					return { { start_col = 0, end_col = #row.k1, hl_group = "AtlasTextMuted" } }
				end
				if col.key == "v1" and row.v1_hl then
					return { { start_col = 0, end_col = #tostring(row.v1), hl_group = row.v1_hl } }
				end
				return nil
			end,
		})
	end

	local lines = { title_line, "" }
	local spans = {
		{ line = 0, line_hl_group = "AtlasTabInactive" },
		{ line = 0, start_col = 1, end_col = #title_line, hl_group = "AtlasGLMilestone" },
	}
	for _, l in ipairs(field_lines) do
		table.insert(lines, l)
	end
	for _, span in ipairs(field_spans) do
		table.insert(spans, {
			line = span.line + 2,
			start_col = span.start_col,
			end_col = span.end_col,
			hl_group = span.hl_group,
		})
	end

	if total ~= nil and total > 0 then
		local bar, filled_len = progress_bar(percent, BAR_WIDTH)
		local bar_line = string.format(" %s %d%% (%d/%d closed)", bar, percent, completed, total)
		table.insert(lines, bar_line)
		local bar_line_index = #lines - 1
		table.insert(spans, {
			line = bar_line_index,
			start_col = 1,
			end_col = 1 + filled_len,
			hl_group = "AtlasTextPositive",
		})
		table.insert(spans, {
			line = bar_line_index,
			start_col = 1 + filled_len,
			end_col = 1 + BAR_WIDTH,
			hl_group = "AtlasTextMuted",
		})
	end
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
