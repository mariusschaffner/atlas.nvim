local M = {}

local utils = require("atlas.ui.shared.utils")
local ui_utils = require("atlas.ui.utils")
local spinner = require("atlas.ui.components.spinner")
local header = require("atlas.issues.ui.detail.components.header")
local sidebar = require("atlas.issues.ui.detail.components.sidebar")
local avatar = require("atlas.ui.components.avatar")
local progress_bar = require("atlas.ui.components.progress_bar")
local markdown_lines = require("atlas.ui.components.markdown_lines")
local state = require("atlas.issues.ui.detail.state")
local detail_ui = require("atlas.ui.detail")
local inline_edit = require("atlas.ui.inline_edit")
local highlights = require("atlas.ui.shared.highlights")
local conversation_state = require("atlas.issues.ui.detail.tabs.conversation.state")
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
	return #parts > 0 and table.concat(parts, " ") or nil
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

	local lines, spans, regions = header.render(data, width)

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
		local pad = "    "
		local strip = pad .. table.concat(parts, " · ")
		table.insert(lines, strip)
		table.insert(spans, { line = #lines - 1, start_col = #pad, end_col = #strip, hl_group = "AtlasTextMuted" })
	end

	-- Full-width divider, the header/body separator (matches the mockup's
	-- header `border-bottom`, spanning the entire width -- unindented, unlike
	-- every line above it).
	table.insert(lines, string.rep("─", width))
	table.insert(spans, { line = #lines - 1, line_hl_group = "AtlasBorder" })

	return lines, spans, regions
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
			empty = true,
			empty_text = "+ add label",
		}
	end
	local lines, spans = utils.render_chips(chips, { width = width, padding_x = 0, rounded = true })
	return {
		id = "labels",
		label = "Labels",
		key_hint = key_hint("issues.change_label"),
		value_lines = lines,
		value_highlights = spans,
	}
end

---@param gl IssuesGitLabHeaderData
---@param width integer
---@return IssuesSidebarEntry
local function milestone_entry(gl, width)
	local hints = key_hints({ "issues.go_to_milestone", "issues.change_milestone" })
	local milestone = gl.milestone
	if milestone == nil then
		return { id = "milestone", label = "Milestone", key_hint = hints, empty = true, empty_text = "+ set milestone" }
	end
	local title = ui_utils.text_width(milestone.title or "") > width - 2 and utils.truncate(milestone.title, width - 2)
		or tostring(milestone.title or "")
	local text = "◆ " .. title
	return {
		id = "milestone",
		label = "Milestone",
		key_hint = hints,
		value_lines = { text },
		value_highlights = { { line = 0, start_col = 0, end_col = #text, hl_group = "AtlasCyan" } },
	}
end

local DAY_SECONDS = 86400

---@param due_date string|nil
---@return string
local function due_hl(due_date)
	if due_date == nil or due_date == "" then
		return "AtlasTextBright"
	end
	local y, m, d = due_date:match("^(%d%d%d%d)-(%d%d)-(%d%d)")
	if not y then
		return "AtlasTextBright"
	end
	local ok, due_epoch = pcall(os.time, { year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
	if not ok then
		return "AtlasTextBright"
	end
	local diff_days = math.floor((due_epoch - os.time()) / DAY_SECONDS)
	if diff_days < 0 then
		return "AtlasLogError"
	end
	if diff_days <= 2 then
		return "AtlasOrange"
	end
	return "AtlasTextBright"
end

---@return IssuesSidebarEntry
local function dates_entry()
	local hints = key_hints({ "issues.change_start_date", "issues.change_due_date" })
	local dates = state.dates
	if dates == "loading" then
		return { ids = { "start_date", "due_date" }, label = "Start → Due", key_hint = hints, value_lines = {
			spinner.with_text("Loading..."),
		} }
	end
	if type(dates) == "string" then
		return {
			ids = { "start_date", "due_date" },
			label = "Start → Due",
			key_hint = hints,
			value_lines = { dates },
			value_highlights = { { line = 0, start_col = 0, end_col = #dates, hl_group = "AtlasLogError" } },
		}
	end
	if type(dates) ~= "table" or (not dates.start_date and not dates.due_date) then
		return {
			ids = { "start_date", "due_date" },
			label = "Start → Due",
			key_hint = hints,
			empty = true,
			empty_text = "not scheduled",
		}
	end
	local start_text = dates.start_date or "?"
	local due_text = dates.due_date or "?"
	local text = string.format("%s → %s", start_text, due_text)
	return {
		ids = { "start_date", "due_date" },
		label = "Start → Due",
		key_hint = hints,
		value_lines = { text },
		value_highlights = { { line = 0, start_col = #text - #due_text, end_col = #text, hl_group = due_hl(dates.due_date) } },
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
---@param width integer
---@return string[] lines
---@return AtlasUIHighlight[] highlights
---@return table<string, AtlasFieldBoxRegion> regions
local function render_sidebar(gl, width)
	local entries = {
		assignee_entry(gl),
		labels_entry(gl, width),
		milestone_entry(gl, width),
		dates_entry(),
		{ divider = true },
		development_entry(),
	}
	local lines, spans, regions = sidebar.render(entries, width)

	return lines, spans, regions
end

---@param tab_items IssuesDetailTabDefinition[]
---@return { key: string, label: string }[] Icon-less -- the borderless in-buffer tab bar doesn't show icons.
local function labeled_tabs(tab_items)
	local out = {}
	for _, tab in ipairs(tab_items) do
		local label = tab.label
		if tab.key == "conversation" and type(conversation_state.items) == "table" then
			label = label .. " " .. tostring(#conversation_state.items)
		elseif tab.key == "merge_requests" and type(state.linked_merge_requests) == "table" then
			label = label .. " " .. tostring(#state.linked_merge_requests)
		end
		table.insert(out, { key = tab.key, label = label })
	end
	return out
end

---@param text string
---@return string
local function escape_statusline(text)
	return (tostring(text):gsub("%%", "%%%%"))
end

--- The tab row, rendered via the content window's native `winbar` (a real
--- single-line window chrome row, like a statusline) rather than as plain
--- buffer content -- the borderless layout has no border to host a native
--- title on, and prepending buffer lines would shift every tab module's own
--- line-indexed state (`state.line_map`, the conversation tab's comment
--- regions, the overview tab's task-line index) out from under them. `winbar`
--- sidesteps that entirely: zero buffer lines consumed, tab modules keep
--- rendering from line 0 exactly as before.
---@param tab_items IssuesDetailTabDefinition[]
---@param active_tab string
---@return string winbar
local function render_tab_winbar(tab_items, active_tab)
	if #tab_items <= 1 then
		return ""
	end
	local left = {}
	for _, tab in ipairs(labeled_tabs(tab_items)) do
		local hl = tab.key == active_tab and "AtlasDetailTabActiveUnderline" or "AtlasTextMuted"
		table.insert(left, string.format("%%#%s# %s ", hl, escape_statusline(tab.label)))
	end
	return table.concat(left) .. "%=" .. "%#AtlasTextMuted# ⇥ switch tab "
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

	pcall(vim.api.nvim_set_option_value, "winbar", render_tab_winbar(tab_items, state.current_tab), {
		win = win,
		scope = "local",
	})

	if inline_edit.is_active(buf) then
		-- Editing owns the content buffer directly (inline_edit swapped it to
		-- a raw, modifiable textarea) -- don't let an unrelated re-render
		-- (spinner tick, header update, ...) clobber the in-progress edit.
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
