local M = {}

local utils = require("atlas.ui.shared.utils")
local state = require("atlas.pulls.ui.detail.state")
local header = require("atlas.pulls.ui.components.header")
local chips = require("atlas.pulls.ui.components.chips")
local detail_tabs = require("atlas.pulls.ui.components.tabs")
local icons = require("atlas.ui.shared.icons")
local spinner = require("atlas.ui.components.spinner")
local box = require("atlas.ui.components.box")
local presentation = require("atlas.pulls.ui.presentation")
local detail_ui = require("atlas.ui.detail")

local ns = vim.api.nvim_create_namespace("atlas.provider_detail")
local header_ns = vim.api.nvim_create_namespace("atlas.provider_detail.header")

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
			local line_text = vim.api.nvim_buf_get_lines(buf, span.line, span.line + 1, false)[1] or ""
			local max_col = #line_text
			local sc = math.min(span.start_col, max_col)
			local ec = math.min(span.end_col, max_col)
			if ec > sc then
				vim.api.nvim_buf_set_extmark(buf, namespace, span.line, sc, {
					end_row = span.line,
					end_col = ec,
					hl_group = span.hl_group,
				})
			end
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

---@param win integer
---@param pr PullRequest|nil
local function set_winbar(win, pr)
	local winbar_items = {}
	if pr ~= nil then
		if type(state.diffstat) == "table" then
			local additions, deletions = 0, 0
			for _, entry in ipairs(state.diffstat) do
				additions = additions + (tonumber(entry.lines_added) or 0)
				deletions = deletions + (tonumber(entry.lines_removed) or 0)
			end
			if additions + deletions > 0 then
				winbar_items[#winbar_items + 1] = string.format("%%#AtlasTextPositive#+%d%%*", additions)
				winbar_items[#winbar_items + 1] = string.format("%%#AtlasLogError#-%d%%*", deletions)
			end
		end
		local details = state.current_details
		if details and details.is_subscribed ~= nil then
			local bell, bell_hl = icons.general(details.is_subscribed and "bell" or "bell_no")
			if details.is_subscribed then
				bell_hl = "AtlasLogInfo"
			end
			winbar_items[#winbar_items + 1] = string.format("%%#%s#%s%%*", bell_hl, bell)
		end
	end
	vim.api.nvim_set_option_value(
		"winbar",
		#winbar_items > 0 and ("%=" .. table.concat(winbar_items, "  ") .. " ") or " ",
		{ win = win }
	)
end

-- Reviewers

local DECISION_GROUPS = { "approved", "changes_requested", "reviewed", "pending" }
local OTHER_DECISION_GROUPS = { "approved", "changes_requested" }

local DECISION_ICONS = {
	approved = { icon = icons.pulls_status("successful"), hl = "AtlasTextPositive" },
	changes_requested = { icon = icons.pulls_status("failed"), hl = "AtlasLogError" },
	reviewed = { icon = icons.pulls("review"), hl = "AtlasTextMuted" },
	pending = { icon = icons.pulls_status("inprogress"), hl = "AtlasTextMuted" },
}

---@param decisions PullsReviewer[]
---@param groups string[]
---@param width integer
---@return BoxContentGroup
local function decision_content(decisions, groups, width)
	local box_lines = {}
	local box_spans = {}
	local grouped = { approved = {}, changes_requested = {}, reviewed = {}, pending = {} }
	for _, decision in ipairs(decisions) do
		local decision_state = decision.decision or "pending"
		if grouped[decision_state] == nil then
			decision_state = "pending"
		end
		table.insert(grouped[decision_state], presentation.user_handle(decision))
	end

	local box_inner = math.max(10, width - (PADDING_X * 2) - 4)
	for _, decision_state in ipairs(groups) do
		local names = grouped[decision_state]
		if #names > 0 then
			table.sort(names)
			local display = DECISION_ICONS[decision_state] or DECISION_ICONS.pending
			local label = table.concat(names, ", ")
			local icon_prefix = display.icon .. " "
			local icon_prefix_width = vim.api.nvim_strwidth(icon_prefix)
			local label_width = math.max(1, box_inner - icon_prefix_width)
			local wrapped = utils.wrap_line(label, label_width)

			local line_text = icon_prefix .. wrapped[1]
			table.insert(box_lines, line_text)
			table.insert(box_spans, {
				line = #box_lines - 1,
				start_col = 0,
				end_col = #display.icon,
				hl_group = display.hl,
			})

			local continuation_prefix = string.rep(" ", icon_prefix_width)
			for i = 2, #wrapped do
				table.insert(box_lines, continuation_prefix .. wrapped[i])
			end
		end
	end

	return { lines = box_lines, spans = box_spans }
end

---@param width integer
---@param lines string[]
---@param spans table[]
local function render_reviewers(width, lines, spans)
	if state.reviewers == nil or state.reviewers == "loading" then
		return
	end

	if type(state.reviewers) == "string" then
		utils.push(lines, spans, "Reviewers", "AtlasColumnHeader", PADDING_X)
		local err_text = state.reviewers
		utils.append_block(
			lines,
			spans,
			box.render({
				{
					lines = { err_text },
					spans = { { line = 0, start_col = 0, end_col = #err_text, hl_group = "AtlasLogError" } },
				},
			}, { width = width, padding_x = PADDING_X })
		)
		table.insert(lines, "")
		return
	end

	local decisions = {}
	local others = {}
	for _, reviewer in ipairs(state.reviewers) do
		table.insert(reviewer.role == "participant" and others or decisions, reviewer)
	end
	local approved_count = 0
	for _, r in ipairs(decisions) do
		if r.decision == "approved" then
			approved_count = approved_count + 1
		end
	end

	local header_text = string.format("Reviewers (%d/%d)", approved_count, #decisions)
	utils.push(lines, spans, header_text, "AtlasColumnHeader", PADDING_X)
	local count_text = string.format("(%d/%d)", approved_count, #decisions)
	table.insert(spans, {
		line = #lines - 1,
		start_col = PADDING_X + #header_text - #count_text,
		end_col = PADDING_X + #header_text,
		hl_group = "AtlasTextMuted",
	})

	local content
	if #decisions == 0 then
		local empty_text = "no reviewers yet"
		content = {
			lines = { empty_text },
			spans = { { line = 0, start_col = 0, end_col = #empty_text, hl_group = "AtlasTextMuted" } },
		}
	else
		content = decision_content(decisions, DECISION_GROUPS, width)
	end

	if #others > 0 then
		table.insert(content.lines, "")
		local label = "Other decisions"
		table.insert(content.lines, label)
		table.insert(content.spans, {
			line = #content.lines - 1,
			start_col = 0,
			end_col = #label,
			hl_group = "AtlasColumnHeader",
		})

		local other_content = decision_content(others, OTHER_DECISION_GROUPS, width)
		local line_offset = #content.lines
		for _, line in ipairs(other_content.lines) do
			table.insert(content.lines, line)
		end
		for _, span in ipairs(other_content.spans) do
			table.insert(content.spans, {
				line = line_offset + span.line,
				start_col = span.start_col,
				end_col = span.end_col,
				hl_group = span.hl_group,
			})
		end
	end

	utils.append_block(lines, spans, box.render({ content }, { width = width, padding_x = PADDING_X }))
	table.insert(lines, "")
end

-- Merge checks

local MERGE_CHECK_STATE = {
	successful = { icon = icons.pulls_status("successful"), hl = "AtlasTextPositive" },
	failed = { icon = icons.pulls_status("failed"), hl = "AtlasLogError" },
	inprogress = { icon = icons.pulls_status("inprogress"), hl = "AtlasTextMuted" },
	warning = { icon = icons.pulls_status("inprogress"), hl = "AtlasTextWarning" },
	muted = { icon = icons.pulls_status("inprogress"), hl = "AtlasTextMuted" },
}

local MERGE_CHECK_PRIORITY = {
	failed = 1,
	warning = 2,
	inprogress = 3,
	successful = 4,
	muted = 5,
}

---@param check PullsMergeCheck
---@param width integer
---@return BoxContentGroup
local function render_merge_check_group(check, width)
	local pair = MERGE_CHECK_STATE[check.state] or MERGE_CHECK_STATE.muted
	local lines = {}
	local spans = {}
	local content_width = math.max(2, width - (PADDING_X * 2) - 3)

	local icon_prefix = pair.icon .. " "
	local icon_width = vim.api.nvim_strwidth(icon_prefix)
	local title_width = math.max(2, content_width - icon_width)
	local title_lines = utils.wrap_line(check.label, title_width)
	for index, title in ipairs(title_lines) do
		local prefix = index == 1 and icon_prefix or string.rep(" ", icon_width)
		table.insert(lines, prefix .. title)
		if index == 1 then
			table.insert(spans, { line = #lines - 1, start_col = 0, end_col = #pair.icon, hl_group = pair.hl })
		end
	end

	for _, message in ipairs(check.details or {}) do
		local indent = "  "
		local detail_width = math.max(2, content_width - vim.api.nvim_strwidth(indent))
		for _, detail_line in ipairs(utils.wrap_line(message, detail_width)) do
			local text = indent .. detail_line
			table.insert(lines, text)
			table.insert(spans, { line = #lines - 1, start_col = 0, end_col = #text, hl_group = "AtlasTextMuted" })
		end
	end

	return { lines = lines, spans = spans }
end

---@param text string
---@param hl_group string
---@param width integer
---@return BoxContentGroup
local function render_merge_check_message_group(text, hl_group, width)
	local content_width = math.max(2, width - (PADDING_X * 2) - 3)
	local lines = utils.wrap_line(text, content_width)
	local spans = {}
	for index, line in ipairs(lines) do
		table.insert(spans, { line = index - 1, start_col = 0, end_col = #line, hl_group = hl_group })
	end
	return { lines = lines, spans = spans }
end

---@param width integer
---@param lines string[]
---@param spans table[]
local function render_merge_checks(width, lines, spans)
	if state.merge_checks == nil or state.merge_checks == "loading" then
		return
	end
	if type(state.merge_checks) == "table" and #state.merge_checks == 0 then
		return
	end

	utils.push(lines, spans, "Merge Checks", "AtlasColumnHeader", PADDING_X)

	if type(state.merge_checks) == "string" then
		local err_text = state.merge_checks --[[@as string]]
		utils.append_block(
			lines,
			spans,
			box.render(
				{ render_merge_check_message_group(err_text, "AtlasLogError", width) },
				{ width = width, padding_x = PADDING_X }
			)
		)
		table.insert(lines, "")
		return
	end

	local checks = vim.list_slice(state.merge_checks --[[@as PullsMergeCheck[] ]])
	table.sort(checks, function(a, b)
		return (MERGE_CHECK_PRIORITY[a.state] or math.huge) < (MERGE_CHECK_PRIORITY[b.state] or math.huge)
	end)

	local groups = {}
	for _, check in ipairs(checks) do
		table.insert(groups, render_merge_check_group(check, width))
	end

	utils.append_block(lines, spans, box.render(groups, { width = width, padding_x = PADDING_X }))
	table.insert(lines, "")
end

---@param pr PullRequest
---@param tab_items PullsDetailTab[]
---@param width integer
---@return string[], table[]
local function render_header(pr, tab_items, width)
	local lines, spans = {}, {}
	local details = state.current_details
	local provider = state.provider
	local provider_detail = provider and provider.capabilities.ui and provider.capabilities.ui.detail
	local extra_fields = provider_detail
			and provider_detail.header_fields
			and provider_detail.header_fields(pr, details, state.details_loading)
		or {}
	local extra_chips = provider_detail
			and provider_detail.chips
			and provider_detail.chips(pr, details, state.details_loading)
		or {}

	-- Header
	local h_lines, h_spans = header.render(pr, width, extra_fields)
	utils.append_block(lines, spans, { lines = h_lines, highlights = h_spans })

	-- Chips
	local chip_lines, chip_spans = chips.render(pr, {
		width = width,
		extra_chips = extra_chips,
		pipelines = state.pipelines,
		loading = state.details_loading or state.pipelines == "loading",
	})
	if #chip_lines > 0 then
		utils.append_block(lines, spans, { lines = chip_lines, highlights = chip_spans })
		table.insert(lines, "")
	end

	-- Tab bar
	if #tab_items > 1 then
		local tab_lines, tab_spans =
			detail_tabs.render(tab_items, state.current_tab, { width = width, padding_x = PADDING_X })
		utils.append_block(lines, spans, { lines = tab_lines, highlights = tab_spans })
		table.insert(lines, "")
	end

	-- Reviewers / merge checks (global, independent of the active tab)
	render_reviewers(width, lines, spans)
	render_merge_checks(width, lines, spans)
	if state.reviewers == "loading" or state.merge_checks == "loading" then
		utils.push(lines, spans, spinner.with_text("Loading overview..."), "AtlasTextMuted", PADDING_X)
	end

	return lines, spans
end

---@param tab_items PullsDetailTab[]
---@param get_tab_module fun(key: string): PullsDetailTabModule|nil
function M.render(tab_items, get_tab_module)
	local buf = state.buf
	local win = state.win
	if buf == nil or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	if win == nil or not vim.api.nvim_win_is_valid(win) then
		return
	end

	local pr = state.current_pr
	local header_win = state.header_win
	local header_buf = state.header_buf
	local has_header = utils.window.valid(header_win) and utils.buffer.valid(header_buf)
	local tab_mod = pr ~= nil and get_tab_module(state.current_tab) or nil

	if has_header then
		set_winbar(header_win, pr)
		local header_lines, header_spans = {}, {}
		if pr ~= nil then
			header_lines, header_spans = render_header(pr, tab_items, vim.api.nvim_win_get_width(header_win))
		end
		set_lines(header_buf, header_lines)
		apply_spans(header_buf, header_ns, header_spans)
		detail_ui.resize_header(#header_lines)
	end

	local width = vim.api.nvim_win_get_width(win)
	local lines = {}
	local spans = {}

	if pr == nil then
		if state.pr_loading then
			utils.push(lines, spans, spinner.with_text("Loading pull request..."), "AtlasTextMuted", PADDING_X)
		else
			lines = { "", "  Nothing selected..." }
		end
		state.line_map = {}
	else
		if tab_mod then
			local tab_lines, tab_spans, tab_line_map = tab_mod.render(pr, state.current_details, width)
			lines, spans = tab_lines, tab_spans
			state.line_map = tab_line_map or {}
		else
			lines = { "  Unknown tab: " .. tostring(state.current_tab) }
			state.line_map = {}
		end
	end

	set_lines(buf, lines)
	apply_spans(buf, ns, spans)
end

return M
