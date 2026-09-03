local M = {}

local utils = require("atlas.ui.shared.utils")
local state = require("atlas.pulls.ui.detail.state")
local header = require("atlas.pulls.ui.components.header")
local chips = require("atlas.pulls.ui.components.chips")
local detail_tabs = require("atlas.pulls.ui.components.tabs")
local icons = require("atlas.ui.shared.icons")
local spinner = require("atlas.ui.components.spinner")
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

-- Reviewers / merge checks (folded into the header fields, two-column grid)

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
	if state.reviewers == "loading" then
		return { label = "Reviewers", value = spinner.with_text("Loading..."), hl = "AtlasTextMuted" }
	end
	if type(state.reviewers) == "string" then
		return { label = "Reviewers", value = state.reviewers, hl = "AtlasLogError" }
	end
	if #state.reviewers == 0 then
		return { label = "Reviewers", value = "no reviewers yet", hl = "AtlasTextMuted" }
	end

	local parts, spans, cursor = {}, {}, 0
	for i, reviewer in ipairs(state.reviewers) do
		local style = DECISION_ICONS[reviewer.decision or "pending"] or DECISION_ICONS.pending
		local token = string.format("%s %s", style.icon, presentation.user_handle(reviewer))
		table.insert(parts, token)
		table.insert(spans, { start_col = cursor, end_col = cursor + #style.icon, hl_group = style.hl })
		cursor = cursor + #token + (i < #state.reviewers and 2 or 0)
	end
	return { label = "Reviewers", value = table.concat(parts, ", "), hl = spans }
end

---@return PullsDetailHeaderField|nil
local function merge_checks_field()
	if state.merge_checks == nil then
		return nil
	end
	if state.merge_checks == "loading" then
		return { label = "Checks", value = spinner.with_text("Loading..."), hl = "AtlasTextMuted" }
	end
	if type(state.merge_checks) == "string" then
		return { label = "Checks", value = state.merge_checks, hl = "AtlasLogError" }
	end
	if #state.merge_checks == 0 then
		return nil
	end

	local checks = vim.list_slice(state.merge_checks --[[@as PullsMergeCheck[] ]])
	table.sort(checks, function(a, b)
		return (MERGE_CHECK_PRIORITY[a.state] or math.huge) < (MERGE_CHECK_PRIORITY[b.state] or math.huge)
	end)

	local parts, spans, cursor = {}, {}, 0
	for i, check in ipairs(checks) do
		local pair = MERGE_CHECK_STATE[check.state] or MERGE_CHECK_STATE.muted
		local token = string.format("%s %s", pair.icon, check.label)
		table.insert(parts, token)
		table.insert(spans, { start_col = cursor, end_col = cursor + #pair.icon, hl_group = pair.hl })
		cursor = cursor + #token + (i < #checks and 2 or 0)
	end
	return { label = "Checks", value = table.concat(parts, ", "), hl = spans }
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

	-- Title
	local title_lines, title_spans = header.render_title(pr, width)
	utils.append_block(lines, spans, { lines = title_lines, highlights = title_spans })
	table.insert(lines, "")

	-- Fields, two columns (Repo/Updated/Assignees/Branch/Reviewers/Checks)
	local trailing_fields = {}
	local reviewers = reviewers_field()
	if reviewers then
		table.insert(trailing_fields, reviewers)
	end
	local checks = merge_checks_field()
	if checks then
		table.insert(trailing_fields, checks)
	end
	local field_lines, field_spans = header.render_fields(pr, width, extra_fields, trailing_fields)
	utils.append_block(lines, spans, { lines = field_lines, highlights = field_spans })
	table.insert(lines, "")

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
			detail_tabs.render(tab_items, state.current_tab, { width = width, padding_x = PADDING_X, divider = false })
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
