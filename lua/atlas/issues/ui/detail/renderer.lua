local M = {}

local utils = require("atlas.ui.shared.utils")
local spinner = require("atlas.ui.components.spinner")
local header = require("atlas.issues.ui.detail.components.header")
local chips = require("atlas.issues.ui.detail.components.chips")
local tabs = require("atlas.ui.components.tabs")
local state = require("atlas.issues.ui.detail.state")
local detail_ui = require("atlas.ui.detail")
local inline_edit = require("atlas.ui.inline_edit")

local ns = vim.api.nvim_create_namespace("atlas.issues.provider_detail")
local header_ns = vim.api.nvim_create_namespace("atlas.issues.provider_detail.header")

local PADDING_X = 1

---@param buf integer
---@param namespace integer
---@param spans table[]
local function apply_spans(buf, namespace, spans)
	vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
	for _, span in ipairs(spans) do
		if span.line ~= nil and span.line_hl_group ~= nil then
			vim.api.nvim_buf_set_extmark(buf, namespace, span.line, 0, {
				line_hl_group = span.line_hl_group,
			})
		elseif span.line ~= nil and span.start_col ~= nil and span.end_col ~= nil and span.hl_group ~= nil then
			vim.api.nvim_buf_set_extmark(buf, namespace, span.line, span.start_col, {
				end_row = span.line,
				end_col = span.end_col,
				hl_group = span.hl_group,
			})
		end
	end
end

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

---@return IssuesDetailHeaderField|nil
local function linked_mr_field()
	local value = state.linked_merge_requests
	if value == nil then
		return nil
	end
	if value == "loading" then
		return { label = "Linked MR", value = spinner.with_text("Loading..."), hl = "AtlasTextMuted" }
	end
	if type(value) == "string" then
		return { label = "Linked MR", value = value, hl = "AtlasLogError" }
	end
	if #value == 0 then
		return { label = "Linked MR", value = "None", hl = "AtlasTextMuted" }
	end

	local parts, spans, cursor = {}, {}, 0
	for i, mr in ipairs(value) do
		local token = "!" .. tostring(mr.id)
		table.insert(parts, token)
		local hl = mr.state == "merged" and "AtlasTextPositive"
			or (mr.state == "closed" and "AtlasLogError" or "AtlasTextMuted")
		table.insert(spans, { start_col = cursor, end_col = cursor + #token, hl_group = hl })
		cursor = cursor + #token + (i < #value and 2 or 0)
	end
	return { label = "Linked MR", value = table.concat(parts, ", "), hl = spans }
end

---@return IssuesDetailHeaderField|nil
local function linked_branches_field()
	local value = state.linked_branches
	if value == nil then
		return nil
	end
	if value == "loading" then
		return { label = "Linked Branches", value = spinner.with_text("Loading..."), hl = "AtlasTextMuted" }
	end
	if type(value) == "string" then
		return { label = "Linked Branches", value = value, hl = "AtlasLogError" }
	end
	if #value == 0 then
		return { label = "Linked Branches", value = "None", hl = "AtlasTextMuted" }
	end

	local names = {}
	for _, branch in ipairs(value) do
		table.insert(names, tostring(branch.name))
	end
	return { label = "Linked Branches", value = table.concat(names, ", "), hl = "AtlasTextMuted" }
end

---@param issue Issue
---@param tab_items IssuesDetailTabDefinition[]
---@param width integer
---@return string[], table[]
local function render_header(issue, tab_items, width)
	local lines, spans = {}, {}
	local details = state.current_details
	local provider_detail = state.provider_detail
	local extra_fields = provider_detail
			and provider_detail.header_fields
			and provider_detail.header_fields(issue, details, state.details_loading)
		or {}
	local extra_chips = provider_detail
			and provider_detail.chips
			and provider_detail.chips(issue, details, state.details_loading)
		or {}

	local secondary_fields = {}
	utils.insert_if(secondary_fields, linked_mr_field())
	utils.insert_if(secondary_fields, linked_branches_field())

	local header_lines, header_spans = header.render(issue, width, extra_fields, secondary_fields)
	utils.append_block(lines, spans, { lines = header_lines, highlights = header_spans })

	local chip_lines, chip_spans = chips.render({ width = width, extra_chips = extra_chips })
	if #chip_lines > 0 then
		utils.append_block(lines, spans, { lines = chip_lines, highlights = chip_spans })
		table.insert(lines, "")
	end

	if #tab_items > 1 then
		local tab_lines, tab_spans = tabs.render(tab_items, state.current_tab, width, {
			active_hl = "AtlasFilterActive",
			inactive_hl = "AtlasTextMuted",
			gap = " ",
			padding_x = PADDING_X,
		})
		utils.append_block(lines, spans, { lines = tab_lines, highlights = tab_spans })
	end

	return lines, spans
end

---@param tab_items IssuesDetailTabDefinition[]
---@param get_tab_module fun(key: string|nil): IssuesDetailTabModule|nil
function M.render(tab_items, get_tab_module)
	local buf = state.buf
	local win = state.win
	if buf == nil or win == nil then
		return
	end
	if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_win_is_valid(win) then
		return
	end

	local issue = state.current_issue
	local header_win = state.header_win
	local header_buf = state.header_buf
	local has_header = utils.window.valid(header_win) and utils.buffer.valid(header_buf)

	if has_header then
		local header_lines, header_spans = {}, {}
		if issue ~= nil then
			header_lines, header_spans = render_header(issue, tab_items, vim.api.nvim_win_get_width(header_win))
		end
		set_lines(header_buf, header_lines)
		apply_spans(header_buf, header_ns, header_spans)
		detail_ui.resize_header(#header_lines)
	end

	if inline_edit.is_active(buf) then
		return
	end

	local width = vim.api.nvim_win_get_width(win)
	local lines = {}
	local spans = {}

	if issue == nil then
		if state.issue_loading then
			utils.push(lines, spans, spinner.with_text("Loading issue..."), "AtlasTextMuted", PADDING_X)
		else
			lines = { "", "  Nothing selected..." }
		end
		state.line_map = {}
	else
		local details = state.current_details
		local tab_mod = get_tab_module(state.current_tab)

		if tab_mod and tab_mod.render then
			local tab_lines, tab_spans, tab_line_map = tab_mod.render(issue, details, width)
			lines, spans = tab_lines, tab_spans
			state.line_map = tab_line_map or {}
			if details == nil and state.current_tab == "overview" then
				if #lines > 0 then
					table.insert(lines, "")
				end
				local text = state.details_loading and spinner.with_text("Loading issue details...")
					or "Issue details unavailable."
				utils.push(lines, spans, text, "AtlasTextMuted", PADDING_X)
			end
		elseif details == nil then
			local text = state.details_loading and spinner.with_text("Loading issue...") or "Issue details unavailable."
			utils.push(lines, spans, text, "AtlasTextMuted", PADDING_X)
			state.line_map = {}
		else
			lines = { "  Unknown tab: " .. tostring(state.current_tab) }
			state.line_map = {}
		end
	end

	set_lines(buf, lines)
	apply_spans(buf, ns, spans)
end

return M
