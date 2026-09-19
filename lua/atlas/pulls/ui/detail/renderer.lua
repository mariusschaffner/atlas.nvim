local M = {}

local utils = require("atlas.ui.shared.utils")
local state = require("atlas.pulls.ui.detail.state")
local header = require("atlas.pulls.ui.components.header")
local field_box = require("atlas.ui.components.field_box")
local chips = require("atlas.pulls.ui.components.chips")
local detail_tabs = require("atlas.pulls.ui.components.tabs")
local icons = require("atlas.ui.shared.icons")
local spinner = require("atlas.ui.components.spinner")
local presentation = require("atlas.pulls.ui.presentation")
local detail_ui = require("atlas.ui.detail")
local inline_edit = require("atlas.ui.inline_edit")

local ns = vim.api.nvim_create_namespace("atlas.provider_detail")
local header_ns = vim.api.nvim_create_namespace("atlas.provider_detail.header")

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

-- Reviewers / merge checks (folded into the header fields, one box per field)

---@param action_id string
---@return boolean
local function supports_action(action_id)
	local capability = state.provider and state.provider.capabilities.actions
	for _, action in ipairs(capability and capability.items or {}) do
		if action.id == action_id then
			return true
		end
	end
	return false
end

local DECISION_ICONS = {
	approved = { icon = icons.pulls_status("successful"), hl = "AtlasTextPositive" },
	changes_requested = { icon = icons.pulls_status("failed"), hl = "AtlasLogError" },
	reviewed = { icon = icons.pulls("review"), hl = "AtlasTextMuted" },
	pending = { icon = icons.pulls_status("inprogress"), hl = "AtlasTextMuted" },
}

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

---@return PullsDetailHeaderField|nil
local function reviewers_field()
	if state.reviewers == nil then
		return nil
	end
	local editable = supports_action("edit_reviewers")
	if state.reviewers == "loading" then
		return { label = "Reviewers", value = spinner.with_text("Loading..."), hl = "AtlasTextMuted", editable = editable }
	end
	if type(state.reviewers) == "string" then
		return { label = "Reviewers", value = state.reviewers, hl = "AtlasLogError", editable = editable }
	end
	if #state.reviewers == 0 then
		return { label = "Reviewers", value = "no reviewers yet", hl = "AtlasTextMuted", editable = editable }
	end

	local parts, spans, cursor = {}, {}, 0
	for i, reviewer in ipairs(state.reviewers) do
		local style = DECISION_ICONS[reviewer.decision or "pending"] or DECISION_ICONS.pending
		local token = string.format("%s %s", style.icon, presentation.user_handle(reviewer))
		table.insert(parts, token)
		table.insert(spans, { start_col = cursor, end_col = cursor + #style.icon, hl_group = style.hl })
		cursor = cursor + #token + (i < #state.reviewers and 2 or 0)
	end
	return { label = "Reviewers", value = table.concat(parts, ", "), hl = spans, editable = editable }
end

---@return PullsDetailHeaderField|nil
local function merge_checks_field()
	if state.merge_checks == nil then
		return nil
	end
	local prefix = "Checks: "
	if state.merge_checks == "loading" then
		return { value = prefix .. spinner.with_text("Loading..."), hl = "AtlasTextMuted", kind = "text" }
	end
	if type(state.merge_checks) == "string" then
		return { value = prefix .. state.merge_checks, hl = "AtlasLogError", kind = "text" }
	end
	if #state.merge_checks == 0 then
		return nil
	end

	local checks = vim.list_slice(state.merge_checks --[[@as PullsMergeCheck[] ]])
	table.sort(checks, function(a, b)
		return (MERGE_CHECK_PRIORITY[a.state] or math.huge) < (MERGE_CHECK_PRIORITY[b.state] or math.huge)
	end)

	local parts, spans, cursor = {}, {}, #prefix
	for i, check in ipairs(checks) do
		local pair = MERGE_CHECK_STATE[check.state] or MERGE_CHECK_STATE.muted
		local token = string.format("%s %s", pair.icon, check.label)
		table.insert(parts, token)
		table.insert(spans, { start_col = cursor, end_col = cursor + #pair.icon, hl_group = pair.hl })
		cursor = cursor + #token + (i < #checks and 2 or 0)
	end
	return { value = prefix .. table.concat(parts, ", "), hl = spans, kind = "text" }
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
	local provider_fields = provider_detail
			and provider_detail.header_fields
			and provider_detail.header_fields(pr, details, state.details_loading)
		or {}

	-- Fields, three columns: Assignee/Reviewers on the left, Labels in the
	-- middle, Source/Target branch + Checks + Delete-source-branch on the
	-- right (checks and the toggle are plain text, not boxed, and the
	-- toggle sits last). Title spans all columns as the first row, its
	-- border color conveying PR status.
	local left_fields = {}
	utils.insert_if(left_fields, provider_fields.assignee)
	utils.insert_if(left_fields, reviewers_field())

	local middle_fields = {}
	utils.insert_if(middle_fields, provider_fields.labels)

	local right_fields = {}
	table.insert(right_fields, header.source_branch_field(pr.source.branch, state.diffstat))
	table.insert(right_fields, header.target_branch_field(pr.destination.branch))
	utils.insert_if(right_fields, merge_checks_field())
	utils.insert_if(right_fields, provider_fields.delete_source_branch)

	local field_lines, field_spans = field_box.render_columns({ left_fields, middle_fields, right_fields }, {
		width = width,
		top_field = header.title_field(pr),
	})
	utils.append_block(lines, spans, { lines = field_lines, highlights = field_spans })
	table.insert(lines, "")

	-- Chips
	local chip_lines, chip_spans = chips.render(pr, {
		width = width,
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
		local header_lines, header_spans = {}, {}
		if pr ~= nil then
			header_lines, header_spans = render_header(pr, tab_items, vim.api.nvim_win_get_width(header_win))
		end
		set_lines(header_buf, header_lines)
		utils.apply_spans_clamped(header_buf, header_ns, header_spans)
		detail_ui.resize_header(#header_lines)
	end

	if inline_edit.is_active(buf) then
		return
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
	utils.apply_spans_clamped(buf, ns, spans)
end

return M
