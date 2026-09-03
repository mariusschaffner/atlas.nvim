local M = {}

local utils = require("atlas.ui.shared.utils")
local icons = require("atlas.ui.shared.icons")
local spinner = require("atlas.ui.components.spinner")
local box = require("atlas.ui.components.box")
local table_tree = require("atlas.ui.components.table_tree")
local state = require("atlas.pulls.ui.detail.tabs.overview.state")
local detail = require("atlas.pulls.ui.detail.state")
local presentation = require("atlas.pulls.ui.presentation")
local request_scope = require("atlas.core.requests")

local PADDING_X = 1
local PADDING = string.rep(" ", PADDING_X)

---@param pr PullRequest
---@return boolean
local function is_current(pr)
	local current = detail.current_pr
	return current ~= nil
		and tostring(current.id or "") == tostring(pr.id or "")
		and tostring(current.repo_full_name or "") == tostring(pr.repo_full_name or "")
end

local function reset_requests()
	state.requests.cancel()
	state.requests = request_scope.new()
end

function M.reset()
	state.reset()
end

---@param pr PullRequest
---@param refresh fun()
---@param opts { force_refresh: boolean|nil }|nil
function M.on_select(pr, refresh, opts)
	opts = opts or {}

	local provider = detail.provider
	if not provider then
		return
	end
	local core = provider.capabilities.core

	local force_refresh = opts.force_refresh == true
	local can_fetch_reviewers = core.fetch_reviewers ~= nil
	local can_fetch_merge_checks = core.fetch_merge_checks ~= nil
	local should_fetch_reviewers = can_fetch_reviewers
		and (force_refresh or state.reviewers == nil or state.reviewers == "loading")
	local should_fetch_merge_checks = can_fetch_merge_checks
		and (force_refresh or state.merge_checks == nil or state.merge_checks == "loading")

	if should_fetch_reviewers or should_fetch_merge_checks then
		reset_requests()
	end

	if should_fetch_reviewers then
		state.reviewers = "loading"
	end
	if should_fetch_merge_checks then
		state.merge_checks = "loading"
	end

	if should_fetch_reviewers then
		state.requests.run(function(done)
			return core.fetch_reviewers(pr, opts, done)
		end, function(reviewers, err)
			if not is_current(pr) then
				return
			end
			if err then
				state.reviewers = err
			else
				state.reviewers = reviewers or {}
			end
			refresh()
		end)
	end

	if should_fetch_merge_checks then
		state.requests.run(function(done)
			return core.fetch_merge_checks(pr, opts, done)
		end, function(checks, err)
			if not is_current(pr) then
				return
			end
			if err then
				state.merge_checks = err
			else
				state.merge_checks = checks or {}
			end
			refresh()
		end)
	end
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

-- Description

---@param details PullRequestDetails
---@param width integer
---@param lines string[]
---@param spans table[]
---@param line_map table<integer, table>
local function render_description(details, width, lines, spans, line_map)
	utils.push(lines, spans, "Description", "AtlasColumnHeader", PADDING_X)

	local desc_text = utils.strip_markup(details.description)
	if desc_text == "" then
		utils.push(lines, spans, "No description provided.", "AtlasTextMuted", PADDING_X)
		table.insert(lines, "")
		return
	end

	local desc_lines = utils.sanitize_lines(desc_text)
	while #desc_lines > 0 and vim.trim(desc_lines[#desc_lines]) == "" do
		table.remove(desc_lines)
	end

	for _, line in ipairs(desc_lines) do
		table.insert(lines, PADDING .. line)
	end

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

---@param _pr PullRequest
---@param details PullRequestDetails|nil
---@param width integer
---@return string[], table[], table<integer, table>|nil
function M.render(_pr, details, width)
	local lines = {}
	local spans = {}
	local line_map = {}

	if details then
		render_description(details, width, lines, spans, line_map)
	elseif detail.details_loading then
		utils.push(lines, spans, spinner.with_text("Loading description..."), "AtlasTextMuted", PADDING_X)
	else
		utils.push(lines, spans, "Pull request details unavailable.", "AtlasTextMuted", PADDING_X)
	end

	return lines, spans, line_map
end

---@param pr PullRequest
---@param width integer
---@return string[], table[], table<integer, table>|nil
function M.render_side(pr, width)
	local lines = {}
	local spans = {}

	render_reviewers(width, lines, spans)
	render_merge_checks(width, lines, spans)

	if state.reviewers == "loading" or state.merge_checks == "loading" then
		utils.push(lines, spans, spinner.with_text("Loading overview..."), "AtlasTextMuted", PADDING_X)
	end

	return lines, spans, {}
end

---@return boolean
function M.is_loading()
	return state.reviewers == "loading" or state.merge_checks == "loading"
end

function M.activate(buf, _refresh)
	if not (buf and vim.api.nvim_buf_is_valid(buf)) then
		return
	end
	vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })
	vim.api.nvim_set_option_value("syntax", "markdown", { buf = buf })
end

function M.deactivate(buf)
	if not (buf and vim.api.nvim_buf_is_valid(buf)) then
		return
	end
	vim.api.nvim_set_option_value("filetype", "atlas.detail", { buf = buf })
	vim.api.nvim_set_option_value("syntax", "OFF", { buf = buf })
	pcall(vim.treesitter.stop, buf)
	reset_requests()
end

return M
