-- The merge request detail view's sidebar (DESIGN-merge-request-view.md §5):
-- BRANCHES, ASSIGNEE, REVIEWERS, LABELS, a divider, ON MERGE. Built from the
-- shared `atlas.ui.components.sidebar`/`sidebar_field`/`avatar` components,
-- same as the issue and milestone sidebars.
local M = {}

local sidebar = require("atlas.ui.components.sidebar")
local avatar = require("atlas.ui.components.avatar")
local spinner = require("atlas.ui.components.spinner")
local utils = require("atlas.ui.shared.utils")
local ui_utils = require("atlas.ui.utils")
local resolver = require("atlas.core.keymaps")
local presentation = require("atlas.pulls.ui.presentation")
local closing_refs = require("atlas.pulls.ui.detail.closing_refs")
local state = require("atlas.pulls.ui.detail.state")

local BRANCH = "⎇ "
local TARGET_PREFIX = "↳ "

---@param action_id string
---@return string|nil
local function key_hint(action_id)
	local keys = resolver.resolve(action_id)
	return keys and keys[1] or nil
end

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

--- The field's key hint, only while that edit is actually available.
---@param action_id string
---@param keymap_id string
---@return string|nil
local function edit_hint(action_id, keymap_id)
	if supports_action(action_id) and presentation.is_open_or_draft(state.current_pr) then
		return key_hint(keymap_id)
	end
	return nil
end

---@param text string
---@param width integer
---@return string
local function fit(text, width)
	if ui_utils.text_width(text) > width then
		return utils.truncate(text, math.max(1, width))
	end
	return text
end

---@param lines string[]
---@param spans AtlasUIHighlight[]
---@param line string
---@param line_spans AtlasUIHighlight[]
local function push(lines, spans, line, line_spans)
	local row = #lines
	table.insert(lines, line)
	for _, s in ipairs(line_spans) do
		table.insert(spans, { line = row, start_col = s.start_col, end_col = s.end_col, hl_group = s.hl_group })
	end
end

---@param label string
---@param hint string|nil
---@return IssuesSidebarEntry
local function loading_entry(label, hint)
	local text = spinner.with_text("Loading...")
	return {
		label = label,
		key_hint = hint,
		value_lines = { text },
		value_highlights = { { line = 0, start_col = 0, end_col = #text, hl_group = "AtlasTextMuted" } },
	}
end

---@param pr PullRequest
---@param width integer
---@return IssuesSidebarEntry
local function branches_entry(pr, width)
	local core = state.provider and state.provider.capabilities.core
	local hint = (core and core.update_target_branch and presentation.is_open_or_draft(pr))
			and key_hint("pulls.edit_target_branch")
		or nil
	local src = BRANCH .. fit(tostring(pr.source and pr.source.branch or ""), width - ui_utils.text_width(BRANCH))
	local dst_text = fit(
		tostring(pr.destination and pr.destination.branch or ""),
		width - ui_utils.text_width(TARGET_PREFIX .. BRANCH)
	)
	local dst = TARGET_PREFIX .. BRANCH .. dst_text
	return {
		id = "branches",
		label = "Branches",
		key_hint = hint,
		value_lines = { src, dst },
		value_highlights = {
			{ line = 0, start_col = 0, end_col = #src, hl_group = "AtlasCyan" },
			{ line = 1, start_col = 0, end_col = #TARGET_PREFIX, hl_group = "AtlasTextMuted" },
			{ line = 1, start_col = #TARGET_PREFIX, end_col = #dst, hl_group = "AtlasPurple" },
		},
	}
end

---@param people { username: string|nil, name: string|nil, nickname: string|nil }[]
---@param width integer
---@param right (fun(person: table): string|nil, string|nil)|nil Right-aligned text + highlight per person.
---@return string[] lines
---@return AtlasUIHighlight[] spans
local function people_lines(people, width, right)
	local lines, spans = {}, {}
	for _, person in ipairs(people) do
		local name = presentation.user_handle(person)
		local right_text, right_hl
		if right then
			right_text, right_hl = right(person)
		end
		local right_w = right_text and (ui_utils.text_width(right_text) + 1) or 0
		local full_name = person.name ~= "" and person.name or nil
		local badge_w = ui_utils.text_width(string.format("(%s) ", avatar.initials(full_name or name)))
		local line, line_spans = avatar.render(fit(name, math.max(1, width - badge_w - right_w)), nil, full_name)
		if right_text then
			local pad = math.max(1, width - ui_utils.text_width(line) - ui_utils.text_width(right_text))
			local col = #line + pad
			line = line .. string.rep(" ", pad) .. right_text
			table.insert(line_spans, { line = 0, start_col = col, end_col = #line, hl_group = right_hl })
		end
		push(lines, spans, line, line_spans)
	end
	return lines, spans
end

---@param details PullRequestDetails|nil
---@param width integer
---@return IssuesSidebarEntry
local function assignee_entry(details, width)
	local hint = edit_hint("edit_assignees", "pulls.edit_assignees")
	if details == nil then
		return state.details_loading and loading_entry("Assignee", hint)
			or { id = "assignee", label = "Assignee", key_hint = hint, empty = true, empty_text = "+ assign" }
	end
	local assignees = details.assignees or {}
	if #assignees == 0 then
		return { id = "assignee", label = "Assignee", key_hint = hint, empty = true, empty_text = "+ assign" }
	end
	local lines, spans = people_lines(assignees, width)
	return { id = "assignee", label = "Assignee", key_hint = hint, value_lines = lines, value_highlights = spans }
end

local REVIEW_STATES = {
	approved = { text = "✓ approved", hl = "AtlasGreen" },
	changes_requested = { text = "✗ changes", hl = "AtlasRed" },
	reviewed = { text = "● reviewed", hl = "AtlasTextMuted" },
	pending = { text = "◷ pending", hl = "AtlasYellow" },
}

---@param width integer
---@return IssuesSidebarEntry
local function reviewers_entry(width)
	local hint = edit_hint("edit_reviewers", "pulls.edit_reviewers")
	local reviewers = state.reviewers
	if reviewers == "loading" then
		return loading_entry("Reviewers", hint)
	end
	if type(reviewers) == "string" then
		return {
			id = "reviewers",
			label = "Reviewers",
			key_hint = hint,
			value_lines = { reviewers },
			value_highlights = { { line = 0, start_col = 0, end_col = #reviewers, hl_group = "AtlasLogError" } },
		}
	end
	local requested = {}
	for _, reviewer in ipairs(type(reviewers) == "table" and reviewers or {}) do
		if reviewer.role ~= "participant" then
			table.insert(requested, reviewer)
		end
	end
	if #requested == 0 then
		return { id = "reviewers", label = "Reviewers", key_hint = hint, empty = true, empty_text = "+ add reviewer" }
	end
	local lines, spans = people_lines(requested, width, function(reviewer)
		local style = REVIEW_STATES[reviewer.decision or "pending"] or REVIEW_STATES.pending
		return style.text, style.hl
	end)
	return { id = "reviewers", label = "Reviewers", key_hint = hint, value_lines = lines, value_highlights = spans }
end

---@param details PullRequestDetails|nil
---@param width integer
---@return IssuesSidebarEntry
local function labels_entry(details, width)
	local hint = supports_action("edit_labels") and key_hint("pulls.edit_labels") or nil
	if details == nil and state.details_loading then
		return loading_entry("Labels", hint)
	end
	local provider_detail = state.provider and state.provider.capabilities.ui and state.provider.capabilities.ui.detail
	local chips = {}
	for _, label in ipairs(details and details.labels or {}) do
		local name = tostring(label.name or "")
		if name ~= "" then
			local hl = provider_detail and provider_detail.label_chip_hl and provider_detail.label_chip_hl(label.color)
				or "AtlasChipActive"
			local cap_hl = provider_detail and provider_detail.label_cap_hl and provider_detail.label_cap_hl(label.color)
				or hl
			table.insert(chips, { label = name, hl = hl, cap_hl = cap_hl })
		end
	end
	if #chips == 0 then
		return { id = "labels", label = "Labels", key_hint = hint, empty = true, empty_text = "+ add label" }
	end
	local lines, spans = utils.render_chips(chips, { width = width, padding_x = 0, rounded = true })
	return { id = "labels", label = "Labels", key_hint = hint, value_lines = lines, value_highlights = spans }
end

---@param pr PullRequest
---@param details PullRequestDetails|nil
---@param width integer
---@return IssuesSidebarEntry
local function on_merge_entry(pr, details, width)
	local core = state.provider and state.provider.capabilities.core
	local hint = (core and core.update_remove_source_branch and presentation.is_open_or_draft(pr))
			and key_hint("pulls.toggle_remove_source_branch")
		or nil
	local lines, spans = {}, {}

	local enabled = pr.remove_source_branch == true
	local delete_text = (enabled and "● " or "○ ") .. "Delete source branch"
	local dot_len = #(enabled and "● " or "○ ")
	push(lines, spans, delete_text, {
		{ start_col = 0, end_col = dot_len, hl_group = enabled and "AtlasGreen" or "AtlasTextMuted" },
		{ start_col = dot_len, end_col = #delete_text, hl_group = enabled and "AtlasTextBright" or "AtlasTextMuted" },
	})

	for _, ref in ipairs(closing_refs.parse(details and details.description or "")) do
		local ref_text = fit((ref.project or "") .. "#" .. ref.iid, width - ui_utils.text_width("● Close "))
		local line = "● Close " .. ref_text
		push(lines, spans, line, {
			{ start_col = 0, end_col = #"● ", hl_group = "AtlasGreen" },
			{ start_col = #"● ", end_col = #"● Close", hl_group = "AtlasTextBright" },
			{ start_col = #line - #ref_text, end_col = #line, hl_group = "AtlasAccent" },
		})
	end

	return { id = "remove_source_branch", label = "On merge", key_hint = hint, value_lines = lines, value_highlights = spans }
end

--- Renders the sidebar for `pr` at the sidebar window's full width.
---@param pr PullRequest
---@param details PullRequestDetails|nil
---@param outer_width integer
---@return string[] lines
---@return AtlasUIHighlight[] highlights
---@return table<string, AtlasFieldBoxRegion> regions
function M.render(pr, details, outer_width)
	local width = math.max(1, outer_width - 2 * sidebar.PAD_X)
	local lines, spans, regions = sidebar.render({
		branches_entry(pr, width),
		assignee_entry(details, width),
		reviewers_entry(width),
		labels_entry(details, width),
		{ divider = true },
		on_merge_entry(pr, details, width),
	}, width)

	-- `gB` edits the target branch: anchor its inline edit on the "↳ ⎇ target"
	-- line rather than the whole two-line BRANCHES value.
	local branches = regions.branches
	if branches then
		local offset = ui_utils.text_width(TARGET_PREFIX .. BRANCH)
		regions.target_branch = {
			row = branches.row + 1,
			col = branches.col + offset,
			width = math.max(1, branches.width - offset),
			height = 1,
		}
	end
	return lines, spans, regions
end

return M
