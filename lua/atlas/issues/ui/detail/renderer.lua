local M = {}

local utils = require("atlas.ui.shared.utils")
local ui_utils = require("atlas.ui.utils")
local spinner = require("atlas.ui.components.spinner")
local header = require("atlas.issues.ui.detail.components.header")
local sidebar = require("atlas.ui.components.sidebar")
local avatar = require("atlas.ui.components.avatar")
local progress_bar = require("atlas.ui.components.progress_bar")
local markdown_lines = require("atlas.ui.components.markdown_lines")
local tabs = require("atlas.ui.components.tabs")
local state = require("atlas.issues.ui.detail.state")
local detail_ui = require("atlas.ui.detail")
local inline_edit = require("atlas.ui.inline_edit")
local inline_field_edit = require("atlas.ui.inline_field_edit")
local highlights = require("atlas.ui.shared.highlights")
local conversation_state = require("atlas.issues.ui.detail.tabs.conversation.state")
local composer_dock = require("atlas.ui.components.composer.dock")
local presentation = require("atlas.issues.ui.presentation")
local resolver = require("atlas.core.keymaps")

local ns = vim.api.nvim_create_namespace("atlas.issues.provider_detail")
local header_ns = vim.api.nvim_create_namespace("atlas.issues.provider_detail.header")
local sidebar_ns = vim.api.nvim_create_namespace("atlas.issues.provider_detail.sidebar")

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

---@param action_id string
---@return string|nil
local function key_hint(action_id)
	local keys = resolver.resolve(action_id)
	return keys and keys[1] or nil
end

---@param action_ids string[]
---@return string|nil
local function key_hints(action_ids)
	local parts = {}
	for _, id in ipairs(action_ids) do
		local k = key_hint(id)
		if k then
			table.insert(parts, k)
		end
	end
	return #parts > 0 and table.concat(parts, " | ") or nil
end

---@param issue Issue
---@return string
local function breadcrumb(issue)
	---@cast issue GitLabIssue
	local path = tostring(issue.project_path or "")
	local parts = vim.split(path, "/", { plain = true, trimempty = true })
	local project = parts[#parts] or path
	table.remove(parts)
	local namespace = table.concat(parts, "/")
	local left = namespace ~= "" and (namespace .. " / " .. project) or project
	local iid = tostring(issue.key or ""):match("#%d+$") or ""
	return string.format("%s › issues › %s", left, iid)
end

---@param issue Issue
---@return string
local function meta_right(issue)
	local author = issue.reporter and tostring(issue.reporter.display_name or "") or "Unknown"
	local rel = utils.relative_time(issue.updated_at)
	local updated = rel ~= "-" and (rel .. " ago") or "-"
	return string.format("opened by %s · updated %s", author, updated)
end

---@param details IssueDetails|nil
---@return integer|nil completed, integer|nil total
local function checklist_progress(details)
	if details == nil then
		return nil, nil
	end
	local _, _, parsed_tasks = markdown_lines.render(tostring(details.description or ""), {})
	if #parsed_tasks == 0 then
		return nil, nil
	end
	local completed = 0
	for _, task in ipairs(parsed_tasks) do
		if task.checked then
			completed = completed + 1
		end
	end
	return completed, #parsed_tasks
end

---@param issue Issue
---@param gl IssuesGitLabHeaderData
---@param width integer
---@return string[] lines
---@return AtlasUIHighlight[] highlights
---@return table<string, AtlasFieldBoxRegion> regions
local function render_header(issue, gl, width)
	local provider_detail = state.provider_detail
	local status = provider_detail and provider_detail.title_status and provider_detail.title_status(issue)
		or { text = "Open", hl = "AtlasGLIssueOpenChip" }

	local chips = {}
	for _, label in ipairs(gl.labels or {}) do
		local name = tostring(label.name or "")
		if name ~= "" then
			local hl = provider_detail and provider_detail.label_chip_hl and provider_detail.label_chip_hl(label.color)
				or "AtlasChipActive"
			local cap_hl = provider_detail and provider_detail.label_cap_hl and provider_detail.label_cap_hl(label.color)
				or hl
			table.insert(chips, { label = name, hl = hl, cap_hl = cap_hl })
		end
	end

	local progress_text, progress_bar_text, progress_bar_spans
	local completed, total = checklist_progress(state.current_details)
	if completed ~= nil then
		progress_bar_text, progress_bar_spans =
			progress_bar.render_segments(completed, total, { segments = math.min(total, 10) })
		progress_text = string.format("%d/%d criteria", completed, total)
	end

	local data = {
		breadcrumb = breadcrumb(issue),
		meta_right = meta_right(issue),
		state_label = status.text,
		state_hl = status.hl,
		title = issue.title or "",
		iid_text = tostring(issue.key or ""):match("#%d+$") or "",
		chips = chips,
		milestone_text = gl.milestone and gl.milestone.title or nil,
		progress_bar = progress_bar_text,
		progress_bar_spans = progress_bar_spans,
		progress_text = progress_text,
	}

	-- Narrow-terminal fallback: fold the sidebar's information into one dim
	-- meta strip under the title/chip row instead of silently dropping it
	-- (DESIGN-detail-view.md §1's "Narrow terminals" collapse).
	if detail_ui.is_sidebar_collapsed() then
		local parts = {}
		table.insert(parts, status.text)
		local assignees = gl.assignees or {}
		table.insert(parts, assignees[1] and tostring(assignees[1].display_name or "") or "Unassigned")
		local label = gl.labels and gl.labels[1]
		if label then
			table.insert(parts, tostring(label.name or ""))
		end
		if gl.milestone then
			table.insert(parts, "◆ " .. tostring(gl.milestone.title or ""))
		end
		local dates = state.dates
		local due = (type(dates) == "table" and dates.due_date) or nil
		table.insert(parts, due and ("due " .. due) or "due -")
		local branches = state.linked_branches
		table.insert(parts, (type(branches) == "table" and #branches > 0) and branches[1].name or "no branch")
		data.meta_strip = table.concat(parts, " · ")
	end

	return header.render(data, width)
end

--- The label highlight for a sidebar field: orange while it's the one
--- currently under inline edit (mirrors the description border's editing
--- color), muted otherwise.
---@param field_id string
---@return string
local function field_label_hl(field_id)
	return state.editing_field == field_id and "AtlasFieldBoxBorderEditing" or "AtlasTextMuted"
end

---@param gl IssuesGitLabHeaderData
---@return IssuesSidebarEntry
local function assignee_entry(gl)
	local assignees = gl.assignees or {}
	if #assignees == 0 then
		return {
			id = "assignee",
			label = "Assignee",
			key_hint = key_hint("issues.change_assignee"),
			label_hl = field_label_hl("assignee"),
			empty = true,
			empty_text = "+ assign",
		}
	end
	local lines, spans = {}, {}
	for _, person in ipairs(assignees) do
		local name = tostring(person.display_name or "")
		local line, line_spans = avatar.render(name)
		local line_no = #lines
		table.insert(lines, line)
		for _, s in ipairs(line_spans) do
			table.insert(spans, { line = line_no, start_col = s.start_col, end_col = s.end_col, hl_group = s.hl_group })
		end
	end
	return {
		id = "assignee",
		label = "Assignee",
		key_hint = key_hint("issues.change_assignee"),
		label_hl = field_label_hl("assignee"),
		value_lines = lines,
		value_highlights = spans,
	}
end

---@param gl IssuesGitLabHeaderData
---@param width integer
---@return IssuesSidebarEntry
local function labels_entry(gl, width)
	local chips = {}
	for _, label in ipairs(gl.labels or {}) do
		local name = tostring(label.name or "")
		if name ~= "" then
			local hl = state.provider_detail
					and state.provider_detail.label_chip_hl
					and state.provider_detail.label_chip_hl(label.color)
				or "AtlasChipActive"
			local cap_hl = state.provider_detail
					and state.provider_detail.label_cap_hl
					and state.provider_detail.label_cap_hl(label.color)
				or hl
			table.insert(chips, { label = name, hl = hl, cap_hl = cap_hl })
		end
	end
	if #chips == 0 then
		return {
			id = "labels",
			label = "Labels",
			key_hint = key_hint("issues.change_label"),
			label_hl = field_label_hl("labels"),
			empty = true,
			empty_text = "+ add label",
		}
	end
	local lines, spans = utils.render_chips(chips, { width = width, padding_x = 0, rounded = true })
	return {
		id = "labels",
		label = "Labels",
		key_hint = key_hint("issues.change_label"),
		label_hl = field_label_hl("labels"),
		value_lines = lines,
		value_highlights = spans,
	}
end

---@param gl IssuesGitLabHeaderData
---@param width integer
---@return IssuesSidebarEntry
local function milestone_entry(gl, width)
	local hints = key_hints({ "issues.go_to_milestone", "issues.change_milestone" })
	local label_hl = field_label_hl("milestone")
	local milestone = gl.milestone
	if milestone == nil then
		return {
			id = "milestone",
			label = "Milestone",
			key_hint = hints,
			label_hl = label_hl,
			empty = true,
			empty_text = "+ set milestone",
		}
	end
	local title = ui_utils.text_width(milestone.title or "") > width - 2 and utils.truncate(milestone.title, width - 2)
		or tostring(milestone.title or "")
	local text = "◆ " .. title
	return {
		id = "milestone",
		label = "Milestone",
		key_hint = hints,
		label_hl = label_hl,
		value_lines = { text },
		value_highlights = { { line = 0, start_col = 0, end_col = #text, hl_group = "AtlasCyan" } },
	}
end

--- Builds the split "START gs | gd DUE" label line: start left-aligned with
--- its hint, due right-aligned with its hint, a dimmed "|" centered between
--- them. Each side's label turns orange while that specific field (not its
--- sibling) is under inline edit.
---@param width integer
---@return string label_line
---@return AtlasUIHighlight[] label_spans
local function dates_label(width)
	local start_hint = key_hint("issues.change_start_date")
	local due_hint = key_hint("issues.change_due_date")
	local start_hl = field_label_hl("start_date")
	local due_hl_group = field_label_hl("due_date")

	local left = "START"
	local right = "DUE"
	local left_text = start_hint and (left .. " " .. start_hint) or left
	local right_text = due_hint and (right .. " " .. due_hint) or right

	local free = math.max(1, width - ui_utils.text_width(left_text) - ui_utils.text_width(right_text) - 1)
	local left_pad = math.floor(free / 2)
	local right_pad = free - left_pad
	local line = left_text .. string.rep(" ", left_pad) .. "|" .. string.rep(" ", right_pad) .. right_text

	local spans = { { start_col = 0, end_col = #left, hl_group = start_hl } }
	if start_hint then
		table.insert(spans, { start_col = #left + 1, end_col = #left_text, hl_group = "AtlasKeyHint" })
	end
	local pipe_col = #left_text + left_pad
	table.insert(spans, { start_col = pipe_col, end_col = pipe_col + 1, hl_group = "AtlasTextMuted" })
	local right_col = pipe_col + 1 + right_pad
	table.insert(spans, { start_col = right_col, end_col = right_col + #right, hl_group = due_hl_group })
	if due_hint then
		table.insert(
			spans,
			{ start_col = right_col + #right + 1, end_col = right_col + #right_text, hl_group = "AtlasKeyHint" }
		)
	end

	return line, spans
end

---@param width integer
---@return IssuesSidebarEntry
local function dates_entry(width)
	local label_line, label_spans = dates_label(width)
	local dates = state.dates
	if dates == "loading" then
		return {
			ids = { "start_date", "due_date" },
			label_line = label_line,
			label_spans = label_spans,
			value_lines = { spinner.with_text("Loading...") },
		}
	end
	if type(dates) == "string" then
		return {
			ids = { "start_date", "due_date" },
			label_line = label_line,
			label_spans = label_spans,
			value_lines = { dates },
			value_highlights = { { line = 0, start_col = 0, end_col = #dates, hl_group = "AtlasLogError" } },
		}
	end
	if type(dates) ~= "table" or (not dates.start_date and not dates.due_date) then
		return {
			ids = { "start_date", "due_date" },
			label_line = label_line,
			label_spans = label_spans,
			empty = true,
			empty_text = "not scheduled",
		}
	end
	local start_text = dates.start_date or "?"
	local due_text = dates.due_date or "?"
	-- Due date flush right (mirroring the label line's left/right split),
	-- start date flush left.
	local gap = math.max(1, width - #start_text - #due_text)
	local text = start_text .. string.rep(" ", gap) .. due_text
	return {
		ids = { "start_date", "due_date" },
		label_line = label_line,
		label_spans = label_spans,
		value_lines = { text },
		value_highlights = {
			{ line = 0, start_col = 0, end_col = #start_text, hl_group = "AtlasPurple" },
			{ line = 0, start_col = #text - #due_text, end_col = #text, hl_group = "AtlasPurple" },
		},
	}
end

---@return IssuesSidebarEntry
local function development_entry()
	local branches = state.linked_branches
	local mrs = state.linked_merge_requests
	local lines, spans = {}, {}

	---@param text string
	---@param hl string
	local function add(text, hl)
		table.insert(spans, { line = #lines, start_col = 0, end_col = #text, hl_group = hl })
		table.insert(lines, text)
	end

	if branches == "loading" or mrs == "loading" then
		add(spinner.with_text("Loading..."), "AtlasTextMuted")
	else
		if type(branches) == "table" and #branches > 0 then
			for _, b in ipairs(branches) do
				add(tostring(b.name), highlights.dynamic_for(tostring(b.name)) or "AtlasTextMuted")
			end
		elseif type(branches) == "string" then
			add(branches, "AtlasLogError")
		else
			add("+ link branch", "AtlasTextMutedItalic")
		end

		lines[#lines + 1] = ""

		if type(mrs) == "table" and #mrs > 0 then
			for _, mr in ipairs(mrs) do
				local hl = mr.state == "merged" and "AtlasTextPositive"
					or (mr.state == "closed" and "AtlasLogError" or "AtlasTextMuted")
				add(string.format("!%d %s", mr.id, tostring(mr.title or "")), hl)
			end
		elseif type(mrs) == "string" then
			add(mrs, "AtlasLogError")
		else
			add("+ link merge request", "AtlasTextMutedItalic")
		end
	end

	return {
		label = "Development",
		key_hint = key_hints({ "issues.create_branch", "issues.go_to_pull" }),
		value_lines = lines,
		value_highlights = spans,
	}
end

---@param gl IssuesGitLabHeaderData
---@param outer_width integer Sidebar window's full width.
---@return string[] lines
---@return AtlasUIHighlight[] highlights
---@return table<string, AtlasFieldBoxRegion> regions
local function render_sidebar(gl, outer_width)
	-- Entries are built against the same inner width `sidebar.render` lays
	-- them out at, so e.g. the Start/Due split line's hint ends exactly where
	-- the padded value lines end, not where the unpadded window does.
	local width = math.max(1, outer_width - 2 * sidebar.PAD_X)
	local entries = {
		assignee_entry(gl),
		labels_entry(gl, width),
		milestone_entry(gl, width),
		dates_entry(width),
		{ divider = true },
		development_entry(),
	}
	local lines, spans, regions = sidebar.render(entries, width)

	return lines, spans, regions
end

--- Whether the description field (the "overview" tab's content) can be
--- edited right now -- drives the content box's editable border color, same
--- signal `register_edit_keymap` uses to decide whether "i" does anything.
---@return boolean
local function description_editable()
	local core = state.provider and state.provider.capabilities.core
	return state.current_tab == "overview"
		and core ~= nil
		and core.update_description ~= nil
		and presentation.is_open(state.current_issue)
end

--- The Activity tab's own border color -- blue by default whenever the tab
--- supports adding a top-level comment (mirrors the description tab always
--- being blue while editable), escalating to orange while any composer
--- (docked new comment, inline reply/edit) is open. Grey on a closed issue.
---@return string|nil
local function conversation_border_hl()
	if state.current_tab ~= "conversation" then
		return nil
	end
	if not presentation.is_open(state.current_issue) then
		return "AtlasBorder"
	end
	local comments = state.provider and state.provider.capabilities.comments
	if comments == nil or comments.add_comment == nil then
		return nil
	end
	local session = conversation_state.session
	if (session ~= nil and session.is_open()) or composer_dock.is_expanded() then
		return "AtlasFieldBoxBorderEditing"
	end
	return "AtlasFieldBoxBorderEditable"
end

--- The content box's current border color -- reused for both the actual
--- border (`detail_ui.set_content_border`) and the title's non-label
--- characters, so the "-" separators/leading dash match the border instead
--- of sitting at the default `FloatTitle` color.
---@return string
local function content_border_hl()
	return conversation_border_hl() or (description_editable() and "AtlasFieldBoxBorderEditable" or "AtlasBorder")
end

--- Whether the Activity tab's "[i] - Add" footer hint should show: only on
--- that tab, only when the provider supports adding a top-level comment, and
--- not while the docked composer is there (it carries its own "c focus"
--- hint) or a comment is already being inline-edited.
---@return boolean
local function conversation_addable()
	local comments = state.provider and state.provider.capabilities.comments
	return state.current_tab == "conversation"
		and comments ~= nil
		and comments.add_comment ~= nil
		and not inline_field_edit.is_active()
		and not composer_dock.is_attached()
		and presentation.is_open(state.current_issue)
end

---@param tab_items IssuesDetailTabDefinition[]
---@param active_tab string
---@return { key: string, label: string, icon: AtlasIconStyle|nil }[]
local function labeled_tabs(tab_items)
	local out = {}
	for _, tab in ipairs(tab_items) do
		local label = tab.label
		if tab.key == "conversation" and type(conversation_state.items) == "table" then
			label = label .. " " .. tostring(#conversation_state.items)
		end
		table.insert(out, { key = tab.key, label = label, icon = tab.icon })
	end
	return out
end

---@param tab_items IssuesDetailTabDefinition[]
---@param active_tab string
---@return { [1]: string, [2]: string }[]
function M.title_chunks(tab_items, active_tab)
	if #tab_items <= 1 then
		return {}
	end
	return tabs.title_chunks(labeled_tabs(tab_items), active_tab, {
		active_hl = "AtlasDetailTabActive",
		inactive_hl = "AtlasTextMuted",
		gap = " - ",
		border_hl = content_border_hl(),
	})
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
	local provider_detail = state.provider_detail
	local gl = issue
			and provider_detail
			and provider_detail.header_fields
			and provider_detail.header_fields(issue, state.current_details, state.details_loading)
		or {}

	if has_header then
		local header_lines, header_spans, header_regions = {}, {}, {}
		if issue ~= nil then
			header_lines, header_spans, header_regions = render_header(issue, gl, vim.api.nvim_win_get_width(header_win))
		end
		set_lines(header_buf, header_lines)
		utils.apply_spans(header_buf, header_ns, header_spans)
		state.header_regions = header_regions
		detail_ui.resize_header(#header_lines)
	end

	local sidebar_buf = state.buf and detail_ui.sidebar_buf() or nil
	local sidebar_win = sidebar_buf and detail_ui.sidebar_win() or nil
	if sidebar_buf and sidebar_win then
		local sidebar_lines, sidebar_spans, sidebar_regions = {}, {}, {}
		if issue ~= nil then
			sidebar_lines, sidebar_spans, sidebar_regions = render_sidebar(gl, vim.api.nvim_win_get_width(sidebar_win))
		end
		set_lines(sidebar_buf, sidebar_lines)
		utils.apply_spans(sidebar_buf, sidebar_ns, sidebar_spans)
		state.sidebar_regions = sidebar_regions
	else
		state.sidebar_regions = {}
	end

	detail_ui.set_content_title(M.title_chunks(tab_items, state.current_tab))

	-- Leading "─ " mirrors the top title's own border-dash prefix
	-- (tabs.title_chunks), so the hint aligns with the title above it.
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
	elseif description_editable() then
		local hl = content_border_hl()
		footer_chunks = {
			{ "─ ", hl },
			{ utils.field_hint_label("ui.edit_description", "Edit", true), hl },
			{ " ", hl },
		}
	elseif conversation_addable() then
		local hl = content_border_hl()
		footer_chunks = {
			{ "─ ", hl },
			{ utils.field_hint_label("issues.add_comment", "Add", true), "AtlasFooterInfo" },
			{ " ", hl },
		}
	end
	detail_ui.set_content_footer(footer_chunks)

	if inline_edit.is_active(buf) then
		-- Editing owns the border color (AtlasFieldBoxBorderEditing) until it
		-- finishes; don't let an unrelated re-render (spinner tick, header
		-- update, ...) stomp it back to the merely-editable color mid-edit.
		return
	end
	detail_ui.set_content_border(content_border_hl())

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
