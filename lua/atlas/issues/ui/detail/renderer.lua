local M = {}

local utils = require("atlas.ui.shared.utils")
local spinner = require("atlas.ui.components.spinner")
local header = require("atlas.issues.ui.detail.components.header")
local tabs = require("atlas.ui.components.tabs")
local state = require("atlas.issues.ui.detail.state")
local detail_ui = require("atlas.ui.detail")
local inline_edit = require("atlas.ui.inline_edit")
local highlights = require("atlas.ui.shared.highlights")

local ns = vim.api.nvim_create_namespace("atlas.issues.provider_detail")
local header_ns = vim.api.nvim_create_namespace("atlas.issues.provider_detail.header")

local PADDING_X = 1

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

	local parts, spans, cursor = {}, {}, 0
	for i, branch in ipairs(value) do
		local name = tostring(branch.name)
		table.insert(parts, name)
		local hl = highlights.dynamic_for(name) or "AtlasTextMuted"
		table.insert(spans, { start_col = cursor, end_col = cursor + #name, hl_group = hl })
		cursor = cursor + #name + (i < #value and 2 or 0)
	end
	return { label = "Linked Branches", value = table.concat(parts, ", "), hl = spans }
end

---@param label string
---@param value string|nil
---@param hl string|table[]|nil
---@param parts string[]
---@param spans table[]
---@param cursor integer
---@return integer cursor
local function add_info_segment(label, value, hl, parts, spans, cursor)
	if value == nil or value == "" then
		return cursor
	end
	if #parts > 1 then
		local sep = " · "
		table.insert(parts, sep)
		cursor = cursor + #sep
	end

	local prefix = label .. " "
	table.insert(parts, prefix)
	cursor = cursor + #prefix

	table.insert(parts, value)
	if type(hl) == "table" then
		for _, span in ipairs(hl) do
			table.insert(spans, {
				line = 0,
				start_col = cursor + span.start_col,
				end_col = cursor + span.end_col,
				hl_group = span.hl_group,
			})
		end
	elseif hl then
		table.insert(spans, { line = 0, start_col = cursor, end_col = cursor + #value, hl_group = hl })
	end
	cursor = cursor + #value

	return cursor
end

--- Single unboxed, foreground-colored line summarizing Author / linked MR /
--- linked branch -- sized to its own content (not padded/spanned across the
--- header width) rather than boxed like Assignee/Labels/Milestone.
---@param provider_fields IssuesProviderHeaderFields
---@return string|nil line
---@return table[] spans
local function render_info_line(provider_fields)
	local parts, spans = { " " }, {}
	local cursor = 1

	local author = provider_fields.author
	cursor = add_info_segment("Author", author and author.value, author and author.hl, parts, spans, cursor)

	local mr = linked_mr_field()
	local mr_value = mr and (mr.value == "None" and "none" or mr.value)
	cursor = add_info_segment("MR", mr_value, mr and mr.hl, parts, spans, cursor)

	local branch = linked_branches_field()
	local branch_value = branch and (branch.value == "None" and "none" or branch.value)
	cursor = add_info_segment("Branch", branch_value, branch and branch.hl, parts, spans, cursor)

	if #parts <= 1 then
		return nil, {}
	end
	return table.concat(parts), spans
end

---@param issue Issue
---@param tab_items IssuesDetailTabDefinition[]
---@param width integer
---@return string[] lines
---@return table[] highlights
---@return table<string, AtlasFieldBoxRegion> regions
local function render_header(issue, tab_items, width)
	local lines, spans = {}, {}
	local details = state.current_details
	local provider_detail = state.provider_detail
	local provider_fields = provider_detail
			and provider_detail.header_fields
			and provider_detail.header_fields(issue, details, state.details_loading)
		or {}
	local status_badge = provider_detail and provider_detail.title_status and provider_detail.title_status(issue) or nil

	-- One box each, side by side, spanning the full width: Assignee, Labels,
	-- Milestone. Author/linked-MR/linked-branch move to a plain info line
	-- below instead of sharing these boxes.
	local assignee_col, labels_col, milestone_col = {}, {}, {}
	utils.insert_if(assignee_col, provider_fields.assignee)
	utils.insert_if(labels_col, provider_fields.labels)
	utils.insert_if(milestone_col, provider_fields.milestone)

	local header_lines, header_spans, header_regions =
		header.render(issue, width, assignee_col, labels_col, milestone_col, status_badge)
	utils.append_block(lines, spans, { lines = header_lines, highlights = header_spans })

	local info_line, info_spans = render_info_line(provider_fields)
	if info_line then
		utils.append_block(lines, spans, { lines = { info_line }, highlights = info_spans })
	end
	table.insert(lines, "")

	if #tab_items > 1 then
		local tab_lines, tab_spans = tabs.render(tab_items, state.current_tab, width, {
			active_hl = "AtlasFilterActive",
			inactive_hl = "AtlasTextMuted",
			gap = " ",
			padding_x = PADDING_X,
		})
		utils.append_block(lines, spans, { lines = tab_lines, highlights = tab_spans })
	end

	return lines, spans, header_regions or {}
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
		local header_lines, header_spans, header_regions = {}, {}, {}
		if issue ~= nil then
			header_lines, header_spans, header_regions = render_header(issue, tab_items, vim.api.nvim_win_get_width(header_win))
		end
		set_lines(header_buf, header_lines)
		utils.apply_spans(header_buf, header_ns, header_spans)
		state.header_regions = header_regions
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
	utils.apply_spans(buf, ns, spans)
end

return M
