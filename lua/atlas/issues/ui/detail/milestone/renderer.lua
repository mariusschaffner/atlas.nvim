-- The milestone detail view (DESIGN-milestone-view.md): a boxed header
-- (meta line in the top border + state pill/title, reusing
-- `issues.ui.detail.components.header`) with a 3-line timeline strip inside it,
-- a tab bar + per-tab main pane content, and a sidebar (reusing
-- `atlas.ui.components.sidebar`/`sidebar_field`) with PROGRESS/WORK ITEMS/
-- MERGE REQUESTS/IN PROGRESS fields. Mirrors the issue detail view's renderer
-- (`issues/ui/detail/renderer.lua`) in shape; see DESIGN-milestone-view.md §1-§8.
local M = {}

local utils = require("atlas.ui.shared.utils")
local ui_utils = require("atlas.ui.utils")
local spinner = require("atlas.ui.components.spinner")
local header = require("atlas.issues.ui.detail.components.header")
local sidebar = require("atlas.ui.components.sidebar")
local tabs = require("atlas.ui.components.tabs")
local progress_bar = require("atlas.ui.components.progress_bar")
local markdown_sections = require("atlas.issues.ui.detail.milestone.markdown_sections")
local timeline = require("atlas.issues.ui.detail.milestone.timeline")
local wf_state = require("atlas.issues.providers.gitlab.wf_state")
local table_tree = require("atlas.ui.components.table_tree")
local dashboard_providers = require("atlas.issues.ui.dashboard.providers")
local pulls_dashboard_renderer = require("atlas.pulls.ui.dashboard.renderer")
local pulls_dashboard_providers = require("atlas.pulls.ui.dashboard.providers")
local detail_ui = require("atlas.ui.detail")
local inline_edit = require("atlas.ui.inline_edit")
local resolver = require("atlas.core.keymaps")
local state = require("atlas.issues.ui.detail.milestone.state")

local ns = vim.api.nvim_create_namespace("atlas.issues.milestone_detail")
local header_ns = vim.api.nvim_create_namespace("atlas.issues.milestone_detail.header")
local sidebar_ns = vim.api.nvim_create_namespace("atlas.issues.milestone_detail.sidebar")
local PADDING_X = 1

local TABS = {
	{ key = "description", label = "Description" },
	{ key = "work_items", label = "Work items" },
	{ key = "merge_requests", label = "Merge requests" },
}
M.tabs = TABS

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

--- "gs gd" (space-joined, unlike `key_hints`' " | " style elsewhere -- these
--- are two different fields' keys shown together, not alternatives for one).
---@return string|nil
local function dates_hint()
	local parts = {}
	local gs = key_hint("issues.change_milestone_start_date")
	local gd = key_hint("issues.change_milestone_due_date")
	if gs then
		table.insert(parts, gs)
	end
	if gd then
		table.insert(parts, gd)
	end
	if #parts == 0 then
		return nil
	end
	return table.concat(parts, " ")
end

---@param milestone IssueMilestone
---@return string
local function breadcrumb(milestone)
	local path = tostring(state.project_path or "")
	local parts = vim.split(path, "/", { plain = true, trimempty = true })
	local project = parts[#parts] or path
	table.remove(parts)
	local namespace = table.concat(parts, "/")
	local left = namespace ~= "" and (namespace .. " / " .. project) or project
	return string.format("%s › milestones › %%%s", left, tostring(milestone.id or ""))
end

---@param milestone IssueMilestone
---@return string
local function meta_right(milestone)
	local scope = milestone.group_id and "group" or "project"
	local rel = utils.relative_time(milestone.updated_at)
	local updated = rel ~= "-" and (rel .. " ago") or "-"
	return string.format("%s milestone · updated %s", scope, updated)
end

---@param milestone IssueMilestone
---@param work_items Issue[]|nil
---@param merge_requests PullRequest[]|nil
---@return string
local function narrow_meta_strip(milestone, work_items, merge_requests)
	local counts = { todo = 0, doing = 0, done = 0 }
	local unassigned = 0
	for _, issue in ipairs(work_items or {}) do
		local bucket = wf_state.state_for(issue)
		counts[bucket] = counts[bucket] + 1
		if issue.assignee == nil then
			unassigned = unassigned + 1
		end
	end
	local total = counts.todo + counts.doing + counts.done
	return string.format(
		"%d/%d closed · %d doing · %d unassigned · %d MRs",
		counts.done,
		total,
		counts.doing,
		unassigned,
		#(merge_requests or {})
	)
end

---@param milestone IssueMilestone
---@param today_iso string
---@return IssuesDetailHeaderData
local function header_data(milestone, today_iso)
	local pill = timeline.state_pill(milestone, today_iso)
	return {
		breadcrumb = breadcrumb(milestone),
		meta_right = meta_right(milestone),
		state_label = pill.label,
		state_hl = pill.hl,
		title = milestone.title or "",
		iid_text = "%" .. tostring(milestone.id or ""),
		meta_strip = detail_ui.is_sidebar_collapsed()
				and narrow_meta_strip(milestone, state.work_items, state.merge_requests)
			or nil,
	}
end

---@param width integer
---@return string[] cells
local function build_cells(width)
	local cells = {}
	for i = 1, width do
		cells[i] = " "
	end
	return cells
end

---@param cells string[]
---@param start_col integer 0-indexed
---@param text string
local function set_text(cells, start_col, text)
	for i = 1, #text do
		local idx = start_col + i
		if cells[idx] then
			cells[idx] = text:sub(i, i)
		end
	end
end

---@param cells string[]
---@param col integer 0-indexed
---@param glyph string
local function set_glyph(cells, col, glyph)
	if cells[col + 1] then
		cells[col + 1] = glyph
	end
end

--- Concatenates `cells` into the rendered line, plus a `byte_range(from_col,
--- to_col)` helper mapping 0-indexed column ranges to byte offsets -- needed
--- because the timeline strip's glyphs (│ ━ ─ ┃) are multi-byte UTF-8, so a
--- column index and a byte offset aren't the same number.
---@param cells string[]
---@return string line
---@return fun(from_col: integer, to_col: integer): integer, integer byte_range
local function finalize_cells(cells)
	local parts, offsets = {}, {}
	local byte_pos = 0
	for i, cell in ipairs(cells) do
		offsets[i] = byte_pos
		table.insert(parts, cell)
		byte_pos = byte_pos + #cell
	end
	offsets[#cells + 1] = byte_pos
	local line = table.concat(parts)
	local function byte_range(from_col, to_col)
		from_col = math.max(0, math.min(#cells, from_col))
		to_col = math.max(0, math.min(#cells, to_col))
		return offsets[from_col + 1], offsets[to_col + 1]
	end
	return line, byte_range
end

--- The timeline strip (DESIGN-milestone-view.md §4): date ticks, a fill/
--- today-marker bar, and a label line, built on `timeline.lua`'s pure day
--- math. Returns 1 line (the "+ set dates" hint) when there isn't enough
--- date information to draw a proportional bar, 3 lines otherwise.
---@param milestone IssueMilestone
---@param width integer Inner width, already excluding the left/right pad.
---@param today_iso string
---@return string[] lines
---@return AtlasUIHighlight[] highlights
---@return table<string, AtlasFieldBoxRegion> regions `start_date`/`due_date` inline-edit anchors.
local function render_timeline_unpadded(milestone, width, today_iso)
	width = math.max(1, width)
	local lines, spans, regions = {}, {}, {}
	local closed = milestone.state == "closed"
	local start_iso = timeline.resolve_start(milestone)
	local due_iso = (milestone.due_date and milestone.due_date ~= "") and milestone.due_date or nil
	local bar = timeline.bar_state(today_iso, start_iso, due_iso, closed)

	-- Without both ends of the range there's no cols_per_day to compute --
	-- same degenerate "+ set dates" treatment as the no-dates case.
	if bar.state == "no_dates" or start_iso == nil or due_iso == nil then
		local hint = dates_hint()
		local text = "+ set dates"
		local full = hint and (text .. "  " .. hint) or text
		table.insert(lines, full)
		table.insert(spans, { line = 0, start_col = 0, end_col = #text, hl_group = "AtlasTextMutedItalic" })
		if hint then
			table.insert(spans, { line = 0, start_col = #full - #hint, end_col = #full, hl_group = "AtlasKeyHint" })
			-- No separate start/due anchors to point at here (neither date is
			-- set yet) -- both keys open their picker anchored over the hint.
			-- Two distinct tables (not the same one aliased twice), since a
			-- caller may adjust one's `col` independently of the other's.
			regions.start_date = { row = 0, col = #full - #hint, width = #hint, height = 1 }
			regions.due_date = { row = 0, col = #full - #hint, width = #hint, height = 1 }
		end
		return lines, spans, regions
	end

	local marker_col = timeline.column_for(today_iso, start_iso, due_iso, width)

	-- Line 1: date ticks, with "gs"/"gd" right next to the start/due labels
	-- (the start date's tick is always ticks[1], the due date's is always
	-- ticks[#ticks] -- `timeline.date_ticks` guarantees both are present).
	do
		local ticks = timeline.date_ticks(start_iso, due_iso, width)
		local gs_hint = key_hint("issues.change_milestone_start_date")
		local gd_hint = key_hint("issues.change_milestone_due_date")

		-- The hints extend the start/due ticks' occupied range beyond what
		-- `timeline.date_ticks`'s own overlap-drop already accounted for (it
		-- only knows about the plain date text, not these appended hints).
		-- Start/due take priority over their immediate neighbor on collision.
		if gs_hint and ticks[1].text and ticks[2] and ticks[2].text then
			-- +1 so the two labels keep at least one column of breathing room
			-- instead of just touching.
			local start_end = ticks[1].col + #ticks[1].text + 1 + #gs_hint + 1
			if start_end > ticks[2].col then
				ticks[2].text = nil
			end
		end
		if gd_hint and #ticks >= 2 then
			local due_tick = ticks[#ticks]
			local neighbor = ticks[#ticks - 1]
			if due_tick.text and neighbor.text then
				local due_start = due_tick.col - #due_tick.text + 1 - 1 - #gd_hint
				if due_start <= neighbor.col + #neighbor.text then
					neighbor.text = nil
				end
			end
		end

		local cells = build_cells(width)
		local hint_ranges = {}
		-- Byte-independent column ranges of the start/due date text itself
		-- (not the "gs"/"gd" hint), so an inline edit opens right over the
		-- date -- converted to byte offsets once the line is finalized below.
		local date_col_ranges = {}

		for idx, tick in ipairs(ticks) do
			set_glyph(cells, tick.col, "│")
			if tick.text then
				local text_start = tick.right_aligned and (tick.col - #tick.text + 1) or tick.col

				if idx == 1 and gs_hint then
					-- Start date: hint follows the date, growing rightward.
					set_text(cells, text_start, tick.text)
					date_col_ranges.start_date = { col = text_start, len = #tick.text }
					local hint_col = text_start + #tick.text + 1
					set_text(cells, hint_col, gs_hint)
					table.insert(hint_ranges, { start_col = hint_col, end_col = hint_col + #gs_hint })
				elseif idx == #ticks and gd_hint then
					-- Due date: hint precedes the date so the date itself stays
					-- flush against the strip's closing border.
					local hint_col = text_start - 1 - #gd_hint
					if hint_col >= 0 then
						set_text(cells, hint_col, gd_hint)
						table.insert(hint_ranges, { start_col = hint_col, end_col = hint_col + #gd_hint })
					end
					set_text(cells, text_start, tick.text)
					date_col_ranges.due_date = { col = text_start, len = #tick.text }
				else
					set_text(cells, text_start, tick.text)
				end

				if idx == 1 and date_col_ranges.start_date == nil then
					date_col_ranges.start_date = { col = text_start, len = #tick.text }
				elseif idx == #ticks and date_col_ranges.due_date == nil then
					date_col_ranges.due_date = { col = text_start, len = #tick.text }
				end
			end
		end

		local line, byte_range = finalize_cells(cells)
		table.insert(lines, line)
		local s0, s1 = byte_range(0, width)
		table.insert(spans, { line = 0, start_col = s0, end_col = s1, hl_group = "AtlasTextMuted" })
		for _, hint_range in ipairs(hint_ranges) do
			local h0, h1 = byte_range(hint_range.start_col, hint_range.end_col)
			table.insert(spans, { line = 0, start_col = h0, end_col = h1, hl_group = "AtlasKeyHint" })
		end

		-- Display columns (every cell is 1 column wide), not byte offsets:
		-- the "│" tick glyphs before a date are multi-byte, and the inline
		-- edit overlay is positioned by screen column.
		for field, range in pairs(date_col_ranges) do
			regions[field] = { row = 0, col = range.col, width = math.max(1, range.len), height = 1 }
		end
	end

	-- Line 2: bar.
	do
		local cells = build_cells(width)
		local fill_upto, bar_hl, show_marker

		if bar.state == "closed" then
			fill_upto, bar_hl, show_marker = width, "AtlasProgressEmpty", false
		elseif bar.state == "overdue" then
			-- Foreground-only red, not the bg-filled pill group (that one's
			-- meant for the title's tinted pill, not a full-width bar).
			fill_upto, bar_hl, show_marker = width, "AtlasLogError", false
		elseif bar.state == "before_start" then
			fill_upto, bar_hl, show_marker = 0, "AtlasBorder", false
		else -- in_progress
			fill_upto, bar_hl, show_marker = (marker_col or 0) + 1, "AtlasCyan", true
		end

		for i = 0, width - 1 do
			cells[i + 1] = (i < fill_upto) and "━" or "─"
		end
		if show_marker and marker_col then
			set_glyph(cells, marker_col, "┃")
		end

		local line, byte_range = finalize_cells(cells)
		table.insert(lines, line)
		local line_no = #lines - 1

		if show_marker and marker_col then
			if marker_col > 0 then
				local f0, f1 = byte_range(0, marker_col)
				table.insert(spans, { line = line_no, start_col = f0, end_col = f1, hl_group = bar_hl })
			end
			local m0, m1 = byte_range(marker_col, marker_col + 1)
			table.insert(spans, { line = line_no, start_col = m0, end_col = m1, hl_group = "AtlasTextBright" })
			if marker_col + 1 < width then
				local e0, e1 = byte_range(marker_col + 1, width)
				table.insert(spans, { line = line_no, start_col = e0, end_col = e1, hl_group = "AtlasBorder" })
			end
		else
			if fill_upto > 0 then
				local f0, f1 = byte_range(0, fill_upto)
				table.insert(spans, { line = line_no, start_col = f0, end_col = f1, hl_group = bar_hl })
			end
			if fill_upto < width then
				local e0, e1 = byte_range(fill_upto, width)
				table.insert(spans, { line = line_no, start_col = e0, end_col = e1, hl_group = "AtlasBorder" })
			end
		end
	end

	-- Line 3: label only -- "gs"/"gd" now sit next to the dates themselves on
	-- line 1, so there's no separate key-hint to show here any more.
	do
		local label_text
		if bar.state == "before_start" then
			label_text = string.format("starts in %d day%s", bar.days, bar.days == 1 and "" or "s")
		elseif bar.state == "overdue" then
			label_text = string.format("%d day%s overdue", bar.days, bar.days == 1 and "" or "s")
		elseif bar.state == "closed" then
			label_text = "closed " .. (timeline.format_date(due_iso) or "")
		else
			label_text = "today"
		end

		local label_col = 0
		if bar.state == "in_progress" and marker_col then
			local half = math.floor(ui_utils.text_width(label_text) / 2)
			label_col = math.max(0, math.min(width - ui_utils.text_width(label_text), marker_col - half))
		end

		local cells = build_cells(width)
		set_text(cells, label_col, label_text)

		local line, byte_range = finalize_cells(cells)
		table.insert(lines, line)
		local line_no = #lines - 1

		local l0, l1 = byte_range(label_col, label_col + #label_text)
		table.insert(spans, { line = line_no, start_col = l0, end_col = l1, hl_group = "AtlasTextBright" })
	end

	return lines, spans, regions
end

--- The boxed header with the timeline strip inside it, below the title.
---@param milestone IssueMilestone
---@param outer_width integer
---@param today_iso string
---@return string[] lines
---@return AtlasUIHighlight[] highlights
---@return table<string, AtlasFieldBoxRegion> regions `title`, `start_date`, `due_date` inline-edit anchors.
local function render_header(milestone, outer_width, today_iso)
	local t_lines, t_spans, t_regions =
		render_timeline_unpadded(milestone, header.inner_width(outer_width), today_iso)
	return header.render(
		header_data(milestone, today_iso),
		outer_width,
		{ lines = t_lines, highlights = t_spans, regions = t_regions }
	)
end

---@param work_items Issue[]
---@return { todo: integer, doing: integer, done: integer } counts
---@return integer unassigned
local function work_item_buckets(work_items)
	local counts = { todo = 0, doing = 0, done = 0 }
	local unassigned = 0
	for _, issue in ipairs(work_items) do
		local bucket = wf_state.state_for(issue)
		counts[bucket] = counts[bucket] + 1
		if issue.assignee == nil then
			unassigned = unassigned + 1
		end
	end
	return counts, unassigned
end

---@param label string
---@param hl string
---@param count integer
---@param width integer
---@return string line
---@return AtlasUIHighlight[] spans -- 0-indexed, relative to this one line
local function count_row(label, hl, count, width)
	local count_text = tostring(count)
	-- Display width, not byte length -- some labels carry a multi-byte glyph
	-- (e.g. "○ To do"'s leading circle) that's 1 display cell but 3 bytes.
	local gap = math.max(1, width - ui_utils.text_width(label) - ui_utils.text_width(count_text))
	local line = label .. string.rep(" ", gap) .. count_text
	return line,
		{
			{ line = 0, start_col = 0, end_col = #label, hl_group = hl },
			{ line = 0, start_col = #line - #count_text, end_col = #line, hl_group = "AtlasTextMuted" },
		}
end

---@param milestone IssueMilestone
---@param work_items Issue[]|nil
---@param width integer
---@return string[] lines
---@return AtlasUIHighlight[] highlights
---@return table<string, AtlasFieldBoxRegion> regions
local function render_sidebar(milestone, work_items, width)
	work_items = work_items or {}
	local counts, unassigned = work_item_buckets(work_items)
	local total = counts.todo + counts.doing + counts.done

	local entries = {}

	-- PROGRESS
	do
		local segments = math.min(20, math.max(1, total))
		local bar_text, bar_spans = progress_bar.render_tri_segments(counts.done, counts.doing, counts.todo, {
			segments = segments,
		})
		local ratio = string.format("%d/%d closed", counts.done, total)
		local value_spans = { { line = 1, start_col = 0, end_col = #ratio, hl_group = "AtlasTextMuted" } }
		for _, s in ipairs(bar_spans) do
			table.insert(value_spans, { line = 0, start_col = s.start_col, end_col = s.end_col, hl_group = s.hl_group })
		end
		table.insert(entries, {
			label = "Progress",
			value_lines = { bar_text, ratio },
			value_highlights = value_spans,
		})
	end

	-- WORK ITEMS
	do
		local lines, spans = {}, {}
		local function add(label, hl, count)
			local line, row_spans = count_row(label, hl, count, width)
			for _, s in ipairs(row_spans) do
				table.insert(spans, { line = #lines, start_col = s.start_col, end_col = s.end_col, hl_group = s.hl_group })
			end
			table.insert(lines, line)
		end
		add("○ To do", "AtlasAccent", counts.todo)
		add("◐ Doing", "AtlasPurple", counts.doing)
		add("✓ Done", "AtlasProgressFill", counts.done)
		if unassigned > 0 then
			add("unassigned", "AtlasTextMuted", unassigned)
			-- Recolor the just-added row's count orange (count_row defaults it
			-- to muted, right for To do/Doing/Done but not for unassigned).
			spans[#spans].hl_group = "AtlasOrange"
		end
		table.insert(entries, { label = "Work items", value_lines = lines, value_highlights = spans })
	end

	-- IN PROGRESS (hidden entirely when empty, per DESIGN-milestone-view.md §5)
	do
		local doing_items = {}
		for _, issue in ipairs(work_items) do
			if wf_state.state_for(issue) == "doing" then
				table.insert(doing_items, issue)
			end
		end
		if #doing_items > 0 then
			table.insert(entries, { divider = true })
			local lines, spans = {}, {}
			for _, issue in ipairs(doing_items) do
				local iid_text = "#" .. tostring(issue.iid or "?")
				local prefix = iid_text .. " "
				local title = tostring(issue.title or "")
				local avail = math.max(1, width - #prefix)
				if ui_utils.text_width(title) > avail then
					title = utils.truncate(title, avail)
				end
				local line = prefix .. title
				table.insert(spans, { line = #lines, start_col = 0, end_col = #iid_text, hl_group = "AtlasTextMuted" })
				table.insert(lines, line)
			end
			table.insert(entries, { label = "In progress", value_lines = lines, value_highlights = spans })
		end
	end

	return sidebar.render(entries, width)
end

---@return { key: string, label: string }[]
local function labeled_tabs()
	local items = {}
	for _, tab in ipairs(TABS) do
		local label = tab.label
		if tab.key == "work_items" and type(state.work_items) == "table" then
			label = label .. " " .. #state.work_items
		elseif tab.key == "merge_requests" and type(state.merge_requests) == "table" then
			label = label .. " " .. #state.merge_requests
		end
		table.insert(items, { key = tab.key, label = label })
	end
	return items
end

---@param width integer
---@return string[] lines
---@return AtlasUIHighlight[] highlights
local function render_description(width)
	if state.description_loading then
		local lines, spans = {}, {}
		utils.push(lines, spans, spinner.with_text("Loading description..."), "AtlasTextMuted", PADDING_X)
		return lines, spans
	end
	local lines, spans = markdown_sections.render(tostring(state.description or ""), { width = width - 2 * PADDING_X })
	if #lines == 0 then
		utils.push(lines, spans, "No description", "AtlasTextMuted", PADDING_X)
		return lines, spans
	end
	local padded_lines, padded_spans = {}, {}
	local pad = string.rep(" ", PADDING_X)
	for i, line in ipairs(lines) do
		padded_lines[i] = line ~= "" and (pad .. line) or line
	end
	for _, span in ipairs(spans) do
		if span.line_hl_group == nil then
			table.insert(padded_spans, {
				line = span.line,
				start_col = span.start_col + PADDING_X,
				end_col = span.end_col + PADDING_X,
				hl_group = span.hl_group,
			})
		else
			table.insert(padded_spans, span)
		end
	end
	return padded_lines, padded_spans
end

---@param issues Issue[]
---@return integer
local function max_key_label_width(issues)
	local display = dashboard_providers.get(state.provider and state.provider.id)
	if not display.label then
		return 0
	end
	local width = 0
	for _, issue in ipairs(issues) do
		width = math.max(width, #tostring(display.label(issue) or ""))
	end
	return width
end

---@param issue Issue
---@param label_width integer
---@return table
local function work_item_row(issue, label_width)
	local display = dashboard_providers.get(state.provider and state.provider.id)
	local row = display.values(issue, { depth = 0, is_last = true }, "plain", label_width)
	row._item = { kind = "issue", key = issue.key, _issue = issue }
	row._issue = issue
	return row
end

---@param row table
---@param col table
---@param ctx { text: string, padded: string, width: integer }
---@return table[]|nil
local function work_item_cell_hl(row, col, ctx)
	local display = dashboard_providers.get(state.provider and state.provider.id)
	return display.highlights and display.highlights(row, col, ctx) or nil
end

---@param issues Issue[]
---@param width integer
---@return string[] lines
---@return table[] spans
---@return table<integer, table> line_map
local function render_work_items_table(issues, width)
	local display = dashboard_providers.get(state.provider and state.provider.id)
	local columns = display.columns(false)
	local label_width = max_key_label_width(issues)
	local rows = {}
	for _, issue in ipairs(issues) do
		table.insert(rows, work_item_row(issue, label_width))
	end
	-- `table_tree.render` returns (lines, line_map, spans) -- reordered here
	-- to (lines, spans, line_map) to match `render_merge_requests_table`'s
	-- order (and this file's own convention) at the call site below.
	local lines, line_map, spans = table_tree.render({
		width = width,
		margin = PADDING_X,
		columns = columns,
		rows = rows,
		cell_hl = work_item_cell_hl,
		header_separator = true,
	})
	return lines, spans, line_map
end

---@param width integer
---@return string[] lines
---@return table[] spans
---@return table<integer, table> line_map
local function render_work_items(width)
	if state.work_items_loading then
		local lines, spans = {}, {}
		utils.push(lines, spans, spinner.with_text("Loading work items..."), "AtlasTextMuted", PADDING_X)
		return lines, spans, {}
	end
	if state.work_items == nil then
		local lines, spans = {}, {}
		utils.push(lines, spans, "Work items unavailable.", "AtlasTextMuted", PADDING_X)
		return lines, spans, {}
	end
	if #state.work_items == 0 then
		local lines, spans = {}, {}
		utils.push(lines, spans, "No linked issues", "AtlasTextMuted", PADDING_X)
		return lines, spans, {}
	end
	return render_work_items_table(state.work_items, width)
end

---@param pulls PullRequest[]
---@param width integer
---@return string[] lines
---@return table[] spans
---@return table<integer, table> line_map
local function render_merge_requests_table(pulls, width)
	local display = pulls_dashboard_providers.get(state.provider and state.provider.id)
	return pulls_dashboard_renderer.render_table(
		pulls,
		"plain",
		width,
		display,
		{ header_separator = true, row_spacer = false }
	)
end

---@param width integer
---@return string[] lines
---@return table[] spans
---@return table<integer, table> line_map
local function render_merge_requests(width)
	if state.merge_requests_loading then
		local lines, spans = {}, {}
		utils.push(lines, spans, spinner.with_text("Loading merge requests..."), "AtlasTextMuted", PADDING_X)
		return lines, spans, {}
	end
	if state.merge_requests == nil then
		local lines, spans = {}, {}
		utils.push(lines, spans, "Merge requests unavailable.", "AtlasTextMuted", PADDING_X)
		return lines, spans, {}
	end
	if #state.merge_requests == 0 then
		local lines, spans = {}, {}
		utils.push(lines, spans, "No linked merge requests", "AtlasTextMuted", PADDING_X)
		return lines, spans, {}
	end
	return render_merge_requests_table(state.merge_requests, width)
end

--- Whether the description field (the "description" tab's content) can be
--- edited right now -- drives the content box's editable border color, same
--- signal `M.edit_description`'s guard uses to decide whether "i" does
--- anything.
---@return boolean
local function description_editable()
	local core = state.provider and state.provider.capabilities.core
	return state.current_tab == "description" and core ~= nil and core.update_milestone_description ~= nil
end

--- The content box's current border color -- reused for both the actual
--- border (`detail_ui.set_content_border`) and the title's non-label
--- characters (leading dash, "-" separators, trailing space), so the "-"s
--- match the border instead of sitting at the default `FloatTitle` color.
---@return string
local function content_border_hl()
	return description_editable() and "AtlasFieldBoxBorderEditable" or "AtlasBorder"
end

--- The tab bar, rendered as the content window's native title -- same
--- bordered-box-with-tabs look as the issue detail view
--- (`issues/ui/detail/renderer.lua`'s own `M.title_chunks`).
---@param active_tab string
---@return { [1]: string, [2]: string }[]
function M.title_chunks(active_tab)
	return tabs.title_chunks(labeled_tabs(), active_tab, {
		active_hl = "AtlasDetailTabActive",
		inactive_hl = "AtlasTextMuted",
		gap = " - ",
		border_hl = content_border_hl(),
	})
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

	-- Computed once per render pass so the header's pill, the timeline
	-- strip, and (if it ever needs "today") the sidebar all agree.
	local today_iso = os.date("!%Y-%m-%d")

	local milestone = state.current_milestone
	local header_win = state.header_win
	local header_buf = state.header_buf
	local has_header = utils.window.valid(header_win) and utils.buffer.valid(header_buf)

	if has_header then
		local header_lines, header_spans, header_regions = {}, {}, {}
		if milestone ~= nil then
			header_lines, header_spans, header_regions =
				render_header(milestone, vim.api.nvim_win_get_width(header_win), today_iso)
		end
		set_lines(header_buf, header_lines)
		utils.apply_spans(header_buf, header_ns, header_spans)
		detail_ui.resize_header(#header_lines)
		state.header_regions = header_regions
	end

	local sidebar_buf = state.buf and detail_ui.sidebar_buf() or nil
	local sidebar_win = sidebar_buf and detail_ui.sidebar_win() or nil
	if sidebar_buf and sidebar_win then
		local sidebar_lines, sidebar_spans = {}, {}
		if milestone ~= nil then
			local width = math.max(1, vim.api.nvim_win_get_width(sidebar_win) - 2 * sidebar.PAD_X)
			sidebar_lines, sidebar_spans = render_sidebar(milestone, state.work_items, width)
		end
		set_lines(sidebar_buf, sidebar_lines)
		utils.apply_spans(sidebar_buf, sidebar_ns, sidebar_spans)
	end

	detail_ui.set_content_title(M.title_chunks(state.current_tab))

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
	elseif state.current_tab == "work_items" or state.current_tab == "merge_requests" then
		local hl = content_border_hl()
		footer_chunks = {
			{ "─ ", hl },
			{ utils.field_hint_label("ui.inspect", "Inspect", true), hl },
			{ " ", hl },
		}
	end
	detail_ui.set_content_footer(footer_chunks)

	if inline_edit.is_active(buf) then
		return
	end
	detail_ui.set_content_border(content_border_hl())

	local width = vim.api.nvim_win_get_width(win)
	local lines, spans, line_map = {}, {}, {}

	if milestone == nil then
		lines = { "", "  Nothing selected..." }
	else
		local content_lines, content_spans, content_line_map
		if state.current_tab == "work_items" then
			content_lines, content_spans, content_line_map = render_work_items(width)
		elseif state.current_tab == "merge_requests" then
			content_lines, content_spans, content_line_map = render_merge_requests(width)
		else
			content_lines, content_spans = render_description(width)
		end

		lines, spans = content_lines, content_spans
		for lnum, row in pairs(content_line_map or {}) do
			line_map[lnum] = row
		end
	end

	state.line_map = line_map
	set_lines(buf, lines)
	utils.apply_spans(buf, ns, spans)
end

return M
