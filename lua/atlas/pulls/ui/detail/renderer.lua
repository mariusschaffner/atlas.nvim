local M = {}

local utils = require("atlas.ui.shared.utils")
local state = require("atlas.pulls.ui.detail.state")
local header = require("atlas.pulls.ui.components.header")
local field_box = require("atlas.ui.components.field_box")
local detail_tabs = require("atlas.pulls.ui.components.tabs")
local icons = require("atlas.ui.shared.icons")
local spinner = require("atlas.ui.components.spinner")
local presentation = require("atlas.pulls.ui.presentation")
local pipeline_utils = require("atlas.pulls.pipelines")
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

---@return PullsDetailHeaderField|nil
local function reviewers_field()
	if state.reviewers == nil then
		return nil
	end
	local editable = supports_action("edit_reviewers")
	if state.reviewers == "loading" then
		return {
			id = "reviewers",
			label = "Reviewers",
			value = spinner.with_text("Loading..."),
			hl = "AtlasTextMuted",
			editable = editable,
		}
	end
	if type(state.reviewers) == "string" then
		return {
			id = "reviewers",
			label = "Reviewers",
			value = state.reviewers,
			hl = "AtlasLogError",
			editable = editable,
		}
	end
	if #state.reviewers == 0 then
		return {
			id = "reviewers",
			label = "Reviewers",
			value = "no reviewers yet",
			hl = "AtlasTextMuted",
			editable = editable,
		}
	end

	local parts, spans, cursor = {}, {}, 0
	for i, reviewer in ipairs(state.reviewers) do
		local style = DECISION_ICONS[reviewer.decision or "pending"] or DECISION_ICONS.pending
		local token = string.format("%s %s", style.icon, presentation.user_handle(reviewer))
		table.insert(parts, token)
		table.insert(spans, { start_col = cursor, end_col = cursor + #style.icon, hl_group = style.hl })
		cursor = cursor + #token + (i < #state.reviewers and 2 or 0)
	end
	return { id = "reviewers", label = "Reviewers", value = table.concat(parts, ", "), hl = spans, editable = editable }
end

--- The delete-source-branch toggle as its own boxed field (a checkbox-style
--- value line), alongside Source/Target rather than folded into a
--- checks-listing box.
---@param delete_source_branch_field PullsDetailHeaderField|nil
---@return PullsDetailHeaderField|nil
local function after_merge_field(delete_source_branch_field)
	if delete_source_branch_field == nil then
		return nil
	end
	local checked = delete_source_branch_field.enabled == true
	local mark = checked and "[x]" or "[ ]"
	return {
		label = "After merge",
		value = string.format("%s %s", mark, delete_source_branch_field.label),
		hl = checked and "AtlasTextPositive" or "AtlasTextMuted",
	}
end

---@param key string
---@return PullsMergeCheck|nil
local function find_check(key)
	if type(state.merge_checks) ~= "table" then
		return nil
	end
	for _, check in ipairs(state.merge_checks) do
		if check.key == key then
			return check
		end
	end
	return nil
end

---@return string|nil value
---@return table[]|nil spans Relative to `value`.
local function diffstat_segment()
	if type(state.diffstat) ~= "table" then
		return nil, nil
	end
	local additions, deletions = 0, 0
	for _, entry in ipairs(state.diffstat) do
		additions = additions + (tonumber(entry.lines_added) or 0)
		deletions = deletions + (tonumber(entry.lines_removed) or 0)
	end
	if additions + deletions == 0 then
		return nil, nil
	end
	local plus = string.format("+%d", additions)
	local minus = string.format("-%d", deletions)
	return plus .. " " .. minus,
		{
			{ start_col = 0, end_col = #plus, hl_group = "AtlasTextPositive" },
			{ start_col = #plus + 1, end_col = #plus + 1 + #minus, hl_group = "AtlasLogError" },
		}
end

---@return string|nil value
---@return string|table[]|nil hl
local function closing_issues_segment()
	local value = state.closing_issues
	if value == nil then
		return nil, nil
	end
	if value == "loading" then
		return spinner.with_text("Loading..."), "AtlasTextMuted"
	end
	if type(value) == "string" then
		return value, "AtlasLogError"
	end
	if #value == 0 then
		return "none", "AtlasTextMuted"
	end

	local parts, hl_spans, cursor = {}, {}, 0
	for i, issue in ipairs(value) do
		local token = "#" .. tostring(issue.iid)
		table.insert(parts, token)
		table.insert(hl_spans, { start_col = cursor, end_col = cursor + #token, hl_group = "AtlasTextPositive" })
		cursor = cursor + #token + (i < #value and 2 or 0)
	end
	return table.concat(parts, ", "), hl_spans
end

--- "Author jane · Milestone v2 · +12 -3 · Closes #4, #5" -- unboxed, sized to
--- its own content.
---@param pr PullRequest
---@param details PullRequestDetails|nil
---@return string|nil line
---@return table[] spans
local function render_info_line_1(pr, details)
	local author_name = presentation.user_handle(pr.author)

	local milestone_value
	if details and details.milestone then
		milestone_value = details.milestone.title
	elseif details ~= nil then
		milestone_value = "none"
	elseif state.details_loading then
		milestone_value = spinner.with_text("Loading...")
	end

	local diffstat_value, diffstat_hl = diffstat_segment()
	local closing_value, closing_hl = closing_issues_segment()

	return utils.render_info_line({
		{ label = "Author", value = author_name, hl = presentation.author_hl(author_name) },
		{ label = "Milestone", value = milestone_value, hl = "AtlasTextMuted" },
		{ label = "", value = diffstat_value, hl = diffstat_hl },
		{ label = "Closes", value = closing_value, hl = closing_hl },
	})
end

--- "✓ Pipeline · ✓ Approved 1/1 · ✓ 0 open threads · ✓ No conflicts · Ready
--- to merge" -- each segment is its own icon-prefixed status (only the icon
--- is colored, matching the icon-only coloring convention already used for
--- Reviewers' decision icons), not a "label value" pair.
---@param pr PullRequest
---@return string|nil line
---@return table[] spans
local function render_info_line_2(pr)
	---@param icon string
	---@param hl string
	---@return string|table[]
	local function icon_span(icon, hl)
		return { { start_col = 0, end_col = #icon, hl_group = hl } }
	end

	local segments = {}

	if type(state.pipelines) == "table" and #state.pipelines > 0 then
		local status = pipeline_utils.aggregate_state(state.pipelines):lower()
		local pair = MERGE_CHECK_STATE[status] or MERGE_CHECK_STATE.muted
		table.insert(segments, {
			label = "",
			value = string.format("%s Pipeline", pair.icon),
			hl = icon_span(pair.icon, pair.hl),
		})
	elseif state.pipelines == "loading" then
		table.insert(segments, { label = "", value = spinner.with_text("Pipeline"), hl = "AtlasTextMuted" })
	end

	if type(state.reviewers) == "table" then
		local total, approved = 0, 0
		for _, reviewer in ipairs(state.reviewers) do
			if reviewer.role == "reviewer" then
				total = total + 1
				if reviewer.decision == "approved" then
					approved = approved + 1
				end
			end
		end
		if total > 0 then
			local pair = approved >= total and MERGE_CHECK_STATE.successful or MERGE_CHECK_STATE.muted
			table.insert(segments, {
				label = "",
				value = string.format("%s Approved %d/%d", pair.icon, approved, total),
				hl = icon_span(pair.icon, pair.hl),
			})
		end
	end

	local details = state.current_details
	if details and details.open_threads ~= nil then
		local n = details.open_threads
		local pair = n == 0 and MERGE_CHECK_STATE.successful or MERGE_CHECK_STATE.warning
		table.insert(segments, {
			label = "",
			value = string.format("%s %d open thread%s", pair.icon, n, n == 1 and "" or "s"),
			hl = icon_span(pair.icon, pair.hl),
		})
	end

	local conflict_check = find_check("conflicts")
	if conflict_check then
		local pair = MERGE_CHECK_STATE[conflict_check.state] or MERGE_CHECK_STATE.muted
		local text = conflict_check.state == "successful" and "No conflicts" or conflict_check.label
		table.insert(segments, {
			label = "",
			value = string.format("%s %s", pair.icon, text),
			hl = icon_span(pair.icon, pair.hl),
		})
	end

	if type(state.merge_checks) == "table" then
		local blocking = 0
		for _, check in ipairs(state.merge_checks) do
			if check.state == "failed" or check.state == "warning" then
				blocking = blocking + 1
			end
		end
		local ready = blocking == 0 and pr.state == "open"
		local pair = ready and MERGE_CHECK_STATE.successful or MERGE_CHECK_STATE.failed
		table.insert(segments, {
			label = "",
			value = string.format("%s %s", pair.icon, ready and "Ready to merge" or "Not ready to merge"),
			hl = icon_span(pair.icon, pair.hl),
		})
	end

	return utils.render_info_line(segments)
end

---@param pr PullRequest
---@param tab_items PullsDetailTab[]
---@param width integer
---@return string[] lines
---@return table[] highlights
---@return table<string, AtlasFieldBoxRegion> regions
local function render_header(pr, tab_items, width)
	local lines, spans = {}, {}
	local details = state.current_details
	local provider = state.provider
	local provider_detail = provider and provider.capabilities.ui and provider.capabilities.ui.detail
	local provider_fields = provider_detail
			and provider_detail.header_fields
			and provider_detail.header_fields(pr, details, state.details_loading)
		or {}

	-- Row 1 (title spans above it): Assignees, Reviewers, Labels -- one box
	-- each, side by side, spanning the full width.
	local assignee_col, reviewers_col, labels_col = {}, {}, {}
	utils.insert_if(assignee_col, provider_fields.assignee)
	utils.insert_if(reviewers_col, reviewers_field())
	utils.insert_if(labels_col, provider_fields.labels)

	local row1_lines, row1_spans, row1_regions = field_box.render_columns({ assignee_col, reviewers_col, labels_col }, {
		width = width,
		top_field = header.title_field(pr),
	})
	utils.append_block(lines, spans, { lines = row1_lines, highlights = row1_spans })

	-- Row 2: Source, Target, After merge -- one box each, side by side.
	local source_col = { header.source_branch_field(pr.source.branch) }
	local target_col = { header.target_branch_field(pr.destination.branch) }
	local after_merge_col = {}
	utils.insert_if(after_merge_col, after_merge_field(provider_fields.delete_source_branch))

	local row2_offset = #row1_lines
	local row2_lines, row2_spans, row2_regions =
		field_box.render_columns({ source_col, target_col, after_merge_col }, { width = width })
	utils.append_block(lines, spans, { lines = row2_lines, highlights = row2_spans })

	local field_regions = {}
	for id, region in pairs(row1_regions or {}) do
		field_regions[id] = region
	end
	for id, region in pairs(row2_regions or {}) do
		field_regions[id] =
			{ row = region.row + row2_offset, col = region.col, width = region.width, height = region.height }
	end

	local info1_line, info1_spans = render_info_line_1(pr, details)
	if info1_line then
		utils.append_block(lines, spans, { lines = { info1_line }, highlights = info1_spans })
	end

	local info2_line, info2_spans = render_info_line_2(pr)
	if info2_line then
		utils.append_block(lines, spans, { lines = { info2_line }, highlights = info2_spans })
	end

	table.insert(lines, "")

	-- Tab bar
	if #tab_items > 1 then
		local tab_lines, tab_spans =
			detail_tabs.render(tab_items, state.current_tab, { width = width, padding_x = PADDING_X })
		utils.append_block(lines, spans, { lines = tab_lines, highlights = tab_spans })
	end

	return lines, spans, field_regions
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
		local header_lines, header_spans, header_regions = {}, {}, {}
		if pr ~= nil then
			header_lines, header_spans, header_regions =
				render_header(pr, tab_items, vim.api.nvim_win_get_width(header_win))
		end
		set_lines(header_buf, header_lines)
		utils.apply_spans_clamped(header_buf, header_ns, header_spans)
		state.header_regions = header_regions
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
