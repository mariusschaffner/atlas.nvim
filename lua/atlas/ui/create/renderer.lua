-- Renders the unified issue/milestone/merge-request create view: a required
-- Type+Title row (30/70 split, red border while empty, blue once filled --
-- see `field_box.render_row`), then, once `Type` is chosen, the subset of
-- the matching real detail view's header fields that are actually settable
-- at creation time. Required fields (Type, Title, and -- for merge_request
-- -- Source/Target branch) get the red/blue treatment; everything else stays
-- grey regardless of whether it's filled (unlike the real detail views'
-- "editable = blue" convention). Description lives in the content area
-- below, exactly like the milestone/issue/PR detail views' own Description
-- tab.
local M = {}

local utils = require("atlas.ui.shared.utils")
local icons = require("atlas.ui.shared.icons")
local highlights = require("atlas.ui.shared.highlights")
local presentation = require("atlas.issues.ui.presentation")
local pulls_presentation = require("atlas.pulls.ui.presentation")
local spinner = require("atlas.ui.components.spinner")
local field_box = require("atlas.ui.components.field_box")
local tabs = require("atlas.ui.components.tabs")
local detail_ui = require("atlas.ui.detail")
local inline_edit = require("atlas.ui.inline_edit")
local state = require("atlas.ui.create.state")

local ns = vim.api.nvim_create_namespace("atlas.ui.create")
local header_ns = vim.api.nvim_create_namespace("atlas.ui.create.header")
local PADDING_X = 1
local TYPE_WIDTH_RATIO = 0.3
local ROW_GAP = 2
local DESCRIPTION_TAB = { { key = "description", label = "Description" } }

---@param buf integer
---@param lines string[]
local function set_lines(buf, lines)
	if buf == nil or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	-- Every render marks the buffer 'modified' (nvim_buf_set_lines always
	-- does, independent of 'modifiable'). The content buffer is `acwrite` so
	-- `:w`/`BufWriteCmd` works -- but that also makes Vim enforce "no write
	-- since last change" on close, unlike the other detail views' `nofile`
	-- buffers. Clear it after every render so `q`/`:q` can always close the
	-- view; it doesn't affect `BufWriteCmd`, which fires on explicit `:w`
	-- regardless of 'modified'.
	vim.api.nvim_set_option_value("modified", false, { buf = buf })
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
end

---@param value string
---@return string
local function required_border(value)
	return vim.trim(tostring(value or "")) == "" and "AtlasFieldBoxBorderRequired" or "AtlasFieldBoxBorderEditable"
end

---@return AtlasFieldBoxField
local function type_field()
	return {
		id = "type",
		label = utils.field_hint_label("ui.create.field_type", "Type", true) .. " - (*)",
		value = state.type,
		border_hl = required_border(state.type),
	}
end

---@return AtlasFieldBoxField
local function title_field()
	return {
		id = "title",
		label = utils.field_hint_label("ui.create.field_title", "Title", true) .. " - (*)",
		value = state.fields.title,
		border_hl = required_border(state.fields.title),
	}
end

---@param width integer
---@return string[] lines
---@return table[] highlights
---@return table<string, AtlasFieldBoxRegion> regions
local function type_title_row(width)
	local type_width = math.max(12, math.floor(width * TYPE_WIDTH_RATIO))
	local title_width = math.max(12, width - type_width - ROW_GAP)
	return field_box.render_row({ type_field(), title_field() }, { type_width, title_width }, { gap = ROW_GAP })
end

---@param id string
---@param action_id string
---@param label string
---@param value string
---@return AtlasFieldBoxField
local function optional_date_field(id, action_id, label, value)
	return {
		id = id,
		label = utils.field_hint_label(action_id, label, true),
		value = value ~= "" and value or "None",
		hl = "AtlasTextMuted",
		border_hl = "AtlasFieldBoxBorder",
	}
end

--- Read-only, like the real issue detail view's Author field: no `id` (not
--- focusable/editable) and no border_hl override needed beyond the usual
--- optional-field grey.
---@return AtlasFieldBoxField
local function author_field()
	if state.current_user_loading then
		return {
			label = "Author",
			value = spinner.with_text("Loading..."),
			hl = "AtlasTextMuted",
			border_hl = "AtlasFieldBoxBorder",
		}
	end

	local user = state.current_user
	local name = user and tostring(user.display_name or "") or ""
	if name == "" then
		name = "Unknown"
	end
	return {
		label = "Author",
		value = string.format("%s %s", icons.general("user"), name),
		hl = presentation.person_hl(name),
		border_hl = "AtlasFieldBoxBorder",
	}
end

---@return AtlasFieldBoxField
local function assignee_field()
	local assignees = state.fields.assignees
	if #assignees == 0 then
		return {
			id = "assignee",
			label = utils.field_hint_label("issues.change_assignee", "Assignee", true),
			value = string.format("%s Unassigned", icons.general("user")),
			hl = "AtlasTextMuted",
			border_hl = "AtlasFieldBoxBorder",
		}
	end

	local names = {}
	for _, a in ipairs(assignees) do
		table.insert(names, tostring(a.display_name or a.account_id or ""))
	end
	return {
		id = "assignee",
		label = utils.field_hint_label("issues.change_assignee", "Assignee", true),
		value = string.format("%s %s", icons.general("user"), table.concat(names, ", ")),
		hl = presentation.person_hl(assignees[1].display_name),
		border_hl = "AtlasFieldBoxBorder",
	}
end

---@return AtlasFieldBoxField
local function labels_field()
	local labels = state.fields.labels
	local label = utils.field_hint_label("issues.change_label", "Labels", true)
	if #labels == 0 then
		return { id = "labels", label = label, value = "None", hl = "AtlasTextMuted", border_hl = "AtlasFieldBoxBorder" }
	end

	local names, spans, cursor = {}, {}, 0
	for _, item in ipairs(labels) do
		local name = tostring(item.name or "")
		if name ~= "" then
			table.insert(spans, {
				start_col = cursor,
				end_col = cursor + #name,
				hl_group = highlights.dynamic_for(name) or "AtlasTextMuted",
			})
			table.insert(names, name)
			cursor = cursor + #name + 2
		end
	end
	return {
		id = "labels",
		label = label,
		value = table.concat(names, ", "),
		hl = spans,
		border_hl = "AtlasFieldBoxBorder",
	}
end

---@return AtlasFieldBoxField
local function milestone_field()
	local milestone = state.fields.milestone
	return {
		id = "milestone",
		label = utils.field_hint_label("issues.change_milestone", "Milestone", true),
		value = milestone and tostring(milestone.title or "") or "None",
		hl = "AtlasTextMuted",
		border_hl = "AtlasFieldBoxBorder",
	}
end

---@return AtlasFieldBoxField
local function source_branch_field()
	local value = state.fields.source_branch
	return {
		id = "source_branch",
		label = utils.field_hint_label("pulls.create_field_source_branch", "Source branch", true) .. " - (*)",
		value = value ~= "" and value or "",
		border_hl = required_border(value),
	}
end

---@return AtlasFieldBoxField
local function target_branch_field()
	local value = state.fields.target_branch
	return {
		id = "target_branch",
		label = utils.field_hint_label("pulls.edit_target_branch", "Target branch", true) .. " - (*)",
		value = value ~= "" and value or "",
		border_hl = required_border(value),
	}
end

---@return AtlasFieldBoxField
local function mr_assignees_field()
	local assignees = state.fields.assignees
	local label = utils.field_hint_label("pulls.edit_assignees", "Assignees", true)
	if #assignees == 0 then
		return {
			id = "assignee",
			label = label,
			value = string.format("%s Unassigned", icons.general("user")),
			hl = "AtlasTextMuted",
			border_hl = "AtlasFieldBoxBorder",
		}
	end

	local names = {}
	for _, a in ipairs(assignees) do
		table.insert(names, tostring(a.name or a.username or ""))
	end
	return {
		id = "assignee",
		label = label,
		value = string.format("%s %s", icons.general("user"), table.concat(names, ", ")),
		hl = pulls_presentation.author_hl(assignees[1].username),
		border_hl = "AtlasFieldBoxBorder",
	}
end

---@return AtlasFieldBoxField
local function mr_labels_field()
	local labels = state.fields.labels
	local label = utils.field_hint_label("pulls.edit_labels", "Labels", true)
	if #labels == 0 then
		return { id = "labels", label = label, value = "None", hl = "AtlasTextMuted", border_hl = "AtlasFieldBoxBorder" }
	end

	local names, spans, cursor = {}, {}, 0
	for _, item in ipairs(labels) do
		local name = tostring(item.name or "")
		if name ~= "" then
			table.insert(spans, {
				start_col = cursor,
				end_col = cursor + #name,
				hl_group = highlights.dynamic_for(name) or "AtlasTextMuted",
			})
			table.insert(names, name)
			cursor = cursor + #name + 2
		end
	end
	return {
		id = "labels",
		label = label,
		value = table.concat(names, ", "),
		hl = spans,
		border_hl = "AtlasFieldBoxBorder",
	}
end

---@return AtlasFieldBoxField
local function reviewers_field()
	local reviewers = state.fields.reviewers
	local label = utils.field_hint_label("pulls.edit_reviewers", "Reviewers", true)
	if #reviewers == 0 then
		return { id = "reviewers", label = label, value = "None", hl = "AtlasTextMuted", border_hl = "AtlasFieldBoxBorder" }
	end
	local names = {}
	for _, r in ipairs(reviewers) do
		table.insert(names, tostring(r.name or r.username or ""))
	end
	return {
		id = "reviewers",
		label = label,
		value = table.concat(names, ", "),
		hl = pulls_presentation.author_hl(reviewers[1].username),
		border_hl = "AtlasFieldBoxBorder",
	}
end

---@return AtlasFieldBoxField
local function draft_field()
	return {
		id = "draft",
		kind = "toggle",
		label = utils.field_hint_label("pulls.create_field_draft", "Draft", true),
		enabled = state.fields.draft == true,
	}
end

---@param width integer
---@return string[] lines
---@return table[] highlights
---@return table<string, AtlasFieldBoxRegion> regions
local function render_header(width)
	local lines, spans, regions = {}, {}, {}

	local row_lines, row_spans, row_regions = type_title_row(width)
	utils.append_block(lines, spans, { lines = row_lines, highlights = row_spans })
	for id, region in pairs(row_regions or {}) do
		regions[id] = region
	end

	local columns
	if state.type == "milestone" then
		columns = {
			{ optional_date_field("start_date", "issues.change_milestone_start_date", "Start date", state.fields.start_date) },
			{ optional_date_field("due_date", "issues.change_milestone_due_date", "Due date", state.fields.due_date) },
		}
	elseif state.type == "issue" then
		columns = {
			{ author_field(), assignee_field() },
			{ labels_field(), milestone_field() },
			{
				optional_date_field("start_date", "issues.change_start_date", "Start date", state.fields.start_date),
				optional_date_field("due_date", "issues.change_due_date", "Due date", state.fields.due_date),
			},
		}
	elseif state.type == "merge_request" then
		columns = {
			{ source_branch_field(), target_branch_field() },
			{ mr_assignees_field(), mr_labels_field() },
			{ reviewers_field(), draft_field() },
		}
	end

	if columns then
		local col_lines, col_spans, col_regions = field_box.render_columns(columns, { width = width })
		local base = #lines
		utils.append_block(lines, spans, { lines = col_lines, highlights = col_spans })
		for id, region in pairs(col_regions or {}) do
			regions[id] = { row = base + region.row, col = region.col, width = region.width, height = region.height }
		end
	end

	return lines, spans, regions
end

--- Description is always optional, for every type, so its idle border stays
--- grey -- only actively editing it (via `inline_edit`, which owns the whole
--- content buffer) escalates to orange.
---@return string
local function content_border_hl()
	return inline_edit.is_active(state.buf) and "AtlasFieldBoxBorderEditing" or "AtlasFieldBoxBorder"
end

---@return string[] lines
---@return table[] highlights
local function render_description()
	local lines, spans = {}, {}
	local description = tostring(state.fields.description or "")
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

function M.render()
	local buf = state.buf
	local win = state.win
	if buf == nil or win == nil then
		return
	end
	if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_win_is_valid(win) then
		return
	end

	local header_win = state.header_win
	local header_buf = state.header_buf
	if utils.window.valid(header_win) and utils.buffer.valid(header_buf) then
		local header_lines, header_spans, header_regions = render_header(vim.api.nvim_win_get_width(header_win))
		set_lines(header_buf, header_lines)
		utils.apply_spans(header_buf, header_ns, header_spans)
		detail_ui.resize_header(#header_lines)
		state.header_regions = header_regions or {}
	end

	detail_ui.set_content_title(tabs.title_chunks(DESCRIPTION_TAB, "description", {
		active_hl = "AtlasDetailTabActive",
		border_hl = content_border_hl(),
	}))

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
	else
		local hl = content_border_hl()
		footer_chunks = {
			{ "─ ", hl },
			{ utils.field_hint_label("ui.edit_description", "Edit", true), hl },
			{ " ", hl },
		}
	end
	detail_ui.set_content_footer(footer_chunks)

	if inline_edit.is_active(buf) then
		return
	end
	detail_ui.set_content_border(content_border_hl())

	local lines, spans = render_description()
	set_lines(buf, lines)
	utils.apply_spans(buf, ns, spans)
end

return M
