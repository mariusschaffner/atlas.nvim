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
local keymaps = require("atlas.core.keymaps")

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
	local label = utils.field_hint_label("pulls.edit_reviewers", "Reviewers", editable)
	if state.reviewers == "loading" then
		return {
			id = "reviewers",
			label = label,
			value = spinner.with_text("Loading..."),
			hl = "AtlasTextMuted",
			editable = editable,
		}
	end
	if type(state.reviewers) == "string" then
		return {
			id = "reviewers",
			label = label,
			value = state.reviewers,
			hl = "AtlasLogError",
			editable = editable,
		}
	end
	if #state.reviewers == 0 then
		return {
			id = "reviewers",
			label = label,
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
	return { id = "reviewers", label = label, value = table.concat(parts, ", "), hl = spans, editable = editable }
end

--- Merge checks + the delete-source-branch toggle, grouped into one
--- "Merge Readiness" box with one row per item, rather than separate
--- one-line text fields. The toggle's own keymap hint lives on the box
--- title (there's no separate "row hint" concept), since the checks
--- themselves aren't independently actionable.
---@param delete_source_branch_field PullsDetailHeaderField|nil
---@return PullsDetailHeaderField|nil
local function merge_readiness_field(delete_source_branch_field)
	local rows = {}

	if state.merge_checks == "loading" then
		table.insert(rows, { text = spinner.with_text("Loading..."), hl = "AtlasTextMuted" })
	elseif type(state.merge_checks) == "string" then
		table.insert(rows, { text = state.merge_checks, hl = "AtlasLogError" })
	elseif type(state.merge_checks) == "table" and #state.merge_checks > 0 then
		local checks = vim.list_slice(state.merge_checks --[[@as PullsMergeCheck[] ]])
		table.sort(checks, function(a, b)
			return (MERGE_CHECK_PRIORITY[a.state] or math.huge) < (MERGE_CHECK_PRIORITY[b.state] or math.huge)
		end)
		for _, check in ipairs(checks) do
			local pair = MERGE_CHECK_STATE[check.state] or MERGE_CHECK_STATE.muted
			table.insert(rows, {
				text = string.format("%s %s", pair.icon, check.label),
				hl = { { start_col = 0, end_col = #pair.icon, hl_group = pair.hl } },
			})
		end
	end

	if delete_source_branch_field then
		local checked = delete_source_branch_field.enabled == true
		local mark = checked and "◉" or "○"
		table.insert(rows, {
			text = string.format("%s %s", mark, delete_source_branch_field.label),
			hl = checked and "AtlasTextPositive" or "AtlasTextMuted",
		})
	end

	if #rows == 0 then
		return nil
	end

	local editable = delete_source_branch_field ~= nil and delete_source_branch_field.editable == true
	return {
		label = utils.field_hint_label("pulls.toggle_remove_source_branch", "Merge Readiness", editable),
		rows = rows,
		editable = editable,
	}
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

	-- Fields, four columns: Assignee/Reviewers on the left, Labels next,
	-- Source/Target branch after that, and a "Merge Readiness" box (checks
	-- + the delete-source-branch toggle as rows) on the far right. Title
	-- spans all columns as the first row, its border color conveying PR
	-- status.
	local left_fields = {}
	utils.insert_if(left_fields, provider_fields.assignee)
	utils.insert_if(left_fields, reviewers_field())

	local middle_fields = {}
	utils.insert_if(middle_fields, provider_fields.labels)

	local branch_fields = {}
	table.insert(branch_fields, header.source_branch_field(pr.source.branch, state.diffstat))
	table.insert(branch_fields, header.target_branch_field(pr.destination.branch))

	local readiness_fields = {}
	utils.insert_if(readiness_fields, merge_readiness_field(provider_fields.delete_source_branch))

	local field_lines, field_spans, field_regions =
		field_box.render_columns({ left_fields, middle_fields, branch_fields, readiness_fields }, {
			width = width,
			top_field = header.title_field(pr, supports_action("edit_title")),
		})
	utils.append_block(lines, spans, { lines = field_lines, highlights = field_spans })

	-- Chips
	local chip_lines, chip_spans = chips.render(pr, {
		width = width,
		pipelines = state.pipelines,
		loading = state.details_loading or state.pipelines == "loading",
	})
	if #chip_lines > 0 then
		table.insert(lines, "")
		utils.append_block(lines, spans, { lines = chip_lines, highlights = chip_spans })
	end

	return lines, spans, field_regions or {}
end

--- Whether the description field (the "overview" tab's content) can be
--- edited right now -- drives the content box's editable border color, same
--- signal the overview tab module's `edit_description_keys()` uses to decide
--- whether "i" does anything.
---@return boolean
local function description_editable()
	if state.current_tab ~= "overview" then
		return false
	end
	local provider = state.provider
	local capability = provider and provider.capabilities.actions
	for _, action in ipairs(capability and capability.items or {}) do
		if action.id == "edit_description" then
			return true
		end
	end
	return false
end

--- "[i] - " prefix shown on the Description tab's own label, but only while
--- it's the active tab (and only when editing is actually possible) -- the
--- statusline hint was deliberately removed, so this is the sole affordance.
---@return string|nil
local function edit_hint_prefix()
	if not description_editable() then
		return nil
	end
	local keys = keymaps.resolve("ui.edit_description")
	if not keys or not keys[1] then
		return nil
	end
	return string.format("[%s] - ", keys[1])
end

---@param tab_items PullsDetailTab[]
---@param active_tab string
---@return { [1]: string, [2]: string }[]
function M.title_chunks(tab_items, active_tab)
	if #tab_items <= 1 then
		return {}
	end
	return detail_tabs.title_chunks(tab_items, active_tab, edit_hint_prefix())
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

	detail_ui.set_content_title(M.title_chunks(tab_items, state.current_tab))

	if inline_edit.is_active(buf) then
		-- Editing owns the border color (AtlasFieldBoxBorderEditing) until it
		-- finishes; don't let an unrelated re-render (spinner tick, header
		-- update, ...) stomp it back to the merely-editable color mid-edit.
		return
	end
	detail_ui.set_content_border(description_editable() and "AtlasFieldBoxBorderEditable" or nil)

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
