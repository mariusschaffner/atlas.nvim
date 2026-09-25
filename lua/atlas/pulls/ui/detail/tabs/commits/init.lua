local M = {}

local utils = require("atlas.ui.shared.utils")
local spinner = require("atlas.ui.components.spinner")
local bordered_box = require("atlas.ui.components.bordered_box")
local presentation = require("atlas.pulls.ui.presentation")
local icons = require("atlas.ui.shared.icons")
local notify = require("atlas.core.notify")
local request_scope = require("atlas.core.requests")
local detail = require("atlas.pulls.ui.detail.state")

local PADDING_X = 1
local TRUNK = "│"
local MIN_BOX_WIDTH = 20
local BOX_WIDTH_RATIO = 0.8

---@class PullsCommitsTabState
---@field current_pr PullRequest|nil
---@field commits PullsCommit[]|"loading"|string|nil
---@field requests AtlasRequestScope
local state = {
	current_pr = nil,
	commits = nil,
	requests = request_scope.new(),
}

local function reset_requests()
	state.requests.cancel()
	state.requests = request_scope.new()
end

function M.reset()
	reset_requests()
	state.current_pr = nil
	state.commits = nil
end

---@param pr PullRequest
---@return boolean
local function is_current(pr)
	return state.current_pr ~= nil
		and tostring(state.current_pr.id or "") == tostring(pr.id or "")
		and tostring(state.current_pr.repo_full_name or "") == tostring(pr.repo_full_name or "")
end

---@param commit PullsCommit
---@return string
local function display_author(commit)
	local nickname = commit.author_nickname
	if type(nickname) == "string" and nickname ~= "" then
		return nickname
	end
	local name = commit.author_name
	if type(name) == "string" and name ~= "" then
		return name
	end
	return "Unknown"
end

--- Lays `left` and `right` out on one row, `right` flush to the row's right
--- edge (at least one space of gap), clamping `left` if both don't fit.
---@param left string
---@param left_hl string|nil
---@param right string
---@param right_highlights table[]|nil Spans {start_col, end_col, hl_group} relative to `right`.
---@param interior_width integer
---@return string line
---@return table[] highlights Spans {start_col, end_col, hl_group} relative to `line`.
local function build_row(left, left_hl, right, right_highlights, interior_width)
	local right_dw = right ~= "" and vim.api.nvim_strwidth(right) or 0
	local gap_dw = right ~= "" and 1 or 0
	local max_left_dw = math.max(0, interior_width - right_dw - gap_dw)
	local left_clamped = utils.truncate(left, max_left_dw)
	local left_dw = vim.api.nvim_strwidth(left_clamped)
	local fill_dw = math.max(gap_dw, interior_width - left_dw - right_dw)
	local line = left_clamped .. string.rep(" ", fill_dw) .. right
	local right_start = #left_clamped + fill_dw

	local highlights = {}
	if left_hl and left_clamped ~= "" then
		table.insert(highlights, { start_col = 0, end_col = #left_clamped, hl_group = left_hl })
	end
	for _, span in ipairs(right_highlights or {}) do
		table.insert(highlights, {
			start_col = right_start + span.start_col,
			end_col = right_start + span.end_col,
			hl_group = span.hl_group,
		})
	end
	return line, highlights
end

--- Prefixes every box line with a padding + trunk-line column ("│ "),
--- connecting cards into one continuous vertical strand, and offsets the
--- box's own highlight spans to match. On `marker_line` (0-indexed within
--- `box_lines`), the trunk character is replaced by `marker_icon` -- a
--- graph-node marker sitting outside the box, on the commit's own row.
---@param box_lines string[]
---@param box_highlights table[]
---@param padding_x integer
---@param marker_line integer
---@param marker_icon string
---@param marker_icon_hl string
---@return string[] lines
---@return table[] highlights
local function apply_trunk(box_lines, box_highlights, padding_x, marker_line, marker_icon, marker_icon_hl)
	local pad = string.rep(" ", padding_x)

	local lines = {}
	local prefix_lens = {}
	local highlights = {}
	for i, line in ipairs(box_lines) do
		local is_marker = (i - 1) == marker_line
		local glyph = is_marker and marker_icon or TRUNK
		local glyph_hl = is_marker and marker_icon_hl or "AtlasTextMuted"
		local prefix = pad .. glyph .. " "
		lines[i] = prefix .. line
		prefix_lens[i - 1] = #prefix
		table.insert(highlights, { line = i - 1, start_col = #pad, end_col = #pad + #glyph, hl_group = glyph_hl })
	end

	for _, span in ipairs(box_highlights) do
		if span.line_hl_group then
			table.insert(highlights, span)
		else
			local plen = prefix_lens[span.line] or (#pad + #TRUNK + 1)
			table.insert(highlights, {
				line = span.line,
				start_col = span.start_col + plen,
				end_col = span.end_col + plen,
				hl_group = span.hl_group,
			})
		end
	end

	return lines, highlights
end

---@param commit PullsCommit
---@param width integer
---@return string[] lines
---@return table[] highlights
local function render_card(commit, width)
	local reserved = PADDING_X + 2 -- "│ " trunk column + gap before the box
	local available = math.max(MIN_BOX_WIDTH, width - reserved)
	local box_width = math.max(MIN_BOX_WIDTH, math.floor(available * BOX_WIDTH_RATIO))
	local interior_width = math.max(1, box_width - 2)

	local author = display_author(commit)
	local author_hl = presentation.author_hl(author)
	local title = author
	local title_highlights = { { start_col = 0, end_col = #title, hl_group = author_hl } }

	local date_text = utils.format_datetime(commit.date)
	local row1, row1_spans = build_row(date_text, "AtlasTextMuted", "", nil, interior_width)

	local message = tostring(commit.message or ""):gsub("\r\n", "\n")
	message = message:match("([^\n]+)") or message
	local hash = tostring(commit.short_hash or commit.hash or ""):sub(1, 8)
	local row2, row2_spans =
		build_row(message, nil, hash, { { start_col = 0, end_col = #hash, hl_group = "AtlasLogInfo" } }, interior_width)

	local content_highlights = {}
	for _, span in ipairs(row1_spans) do
		table.insert(
			content_highlights,
			{ line = 0, start_col = span.start_col, end_col = span.end_col, hl_group = span.hl_group }
		)
	end
	for _, span in ipairs(row2_spans) do
		table.insert(
			content_highlights,
			{ line = 1, start_col = span.start_col, end_col = span.end_col, hl_group = span.hl_group }
		)
	end

	local box_lines, box_highlights = bordered_box.render({
		width = box_width,
		box_width = box_width,
		title = title,
		title_highlights = title_highlights,
		content_lines = { row1, row2 },
		content_highlights = content_highlights,
		border_hl = "AtlasBorder",
	})

	local commit_icon, commit_icon_hl = icons.pulls("commit")
	return apply_trunk(box_lines, box_highlights, PADDING_X, 1, commit_icon, commit_icon_hl)
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
	local should_fetch = force_refresh
		or not is_current(pr)
		or state.commits == nil
		or state.commits == "loading"
		or type(state.commits) == "string"

	if not should_fetch or not core.fetch_commits then
		return
	end

	M.reset()
	state.current_pr = pr
	local pr_id = tostring(pr.id or "")
	state.commits = "loading"
	notify.loading(string.format("Loading commits for #%s...", pr_id))
	state.requests.run(function(done)
		return core.fetch_commits(pr, opts, done)
	end, function(commits, err)
		if not is_current(pr) then
			return
		end
		if err then
			state.commits = tostring(err)
			notify.error(string.format("Failed to load commits for #%s", pr_id))
			refresh()
			return
		end

		state.commits = commits or {}
		notify.success(string.format("Commits loaded for #%s", pr_id), { timeout = 1200 })
		refresh()
	end)
end

---@param _pr PullRequest
---@param _details PullRequestDetails|nil
---@param width integer
---@return string[], table[], table<integer, table>|nil
function M.render(_pr, _details, width)
	local lines = {}
	local spans = {}
	local line_map = {}

	if state.commits == nil then
		return lines, spans, line_map
	end

	-- Loading
	if state.commits == "loading" then
		utils.push(lines, spans, spinner.with_text("Loading commits..."), "AtlasTextMuted", PADDING_X)
		return lines, spans, line_map
	end

	-- Error
	if type(state.commits) == "string" then
		utils.push(lines, spans, state.commits, "AtlasLogError", PADDING_X)
		return lines, spans, line_map
	end

	-- Empty
	local entries = state.commits
	if #entries == 0 then
		utils.push(lines, spans, "No commits yet.", "AtlasTextMuted", PADDING_X)
		return lines, spans, line_map
	end

	for idx, commit in ipairs(entries) do
		local card_lines, card_highlights = render_card(commit, width)
		local first_line = #lines
		utils.append_block(lines, spans, { lines = card_lines, highlights = card_highlights })
		for lnum = first_line + 1, #lines do
			line_map[lnum] = { kind = "commit", commit = commit }
		end

		if idx < #entries then
			utils.push(lines, spans, TRUNK, "AtlasTextMuted", PADDING_X)
		end
	end

	return lines, spans, line_map
end

---@return boolean
function M.is_loading()
	return state.commits == "loading"
end

function M.deactivate()
	M.reset()
	notify.clear()
end

return M
