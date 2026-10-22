local M = {}

local utils = require("atlas.ui.shared.utils")
local spinner = require("atlas.ui.components.spinner")
local presentation = require("atlas.pulls.ui.presentation")
local icons = require("atlas.ui.shared.icons")
local notify = require("atlas.core.notify")
local request_scope = require("atlas.core.requests")
local detail = require("atlas.pulls.ui.detail.state")

local PADDING_X = 1
local TRUNK = "│"

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

--- Two rows per commit, no box (DESIGN-merge-request-view.md §6 "restyled
--- with the shared tokens"): a graph node + bright subject with the short
--- hash flush right, then the dim "author · date" under it, the trunk line
--- connecting consecutive commits.
---@param commit PullsCommit
---@param width integer
---@param last boolean
---@return string[] lines
---@return table[] highlights
local function render_commit(commit, width, last)
	local pad = string.rep(" ", PADDING_X)
	local icon, icon_hl = icons.pulls("commit")
	local prefix = pad .. icon .. " "
	local cont = pad .. (last and " " or TRUNK) .. " "
	local hash = tostring(commit.short_hash or commit.hash or ""):sub(1, 8)

	local message = tostring(commit.message or ""):gsub("\r\n", "\n")
	message = message:match("([^\n]+)") or message
	local room = math.max(1, width - vim.api.nvim_strwidth(prefix) - #hash - 2)
	message = utils.truncate(message, room)
	local fill = math.max(1, width - vim.api.nvim_strwidth(prefix .. message) - #hash - 1)
	local first = prefix .. message .. string.rep(" ", fill) .. hash

	local author = display_author(commit)
	local date_text = utils.format_datetime(commit.date)
	local second = cont .. author .. " · " .. date_text

	local highlights = {
		{ line = 0, start_col = #pad, end_col = #pad + #icon, hl_group = icon_hl },
		{ line = 0, start_col = #prefix, end_col = #prefix + #message, hl_group = "AtlasTextBright" },
		{ line = 0, start_col = #first - #hash, end_col = #first, hl_group = "AtlasAccent" },
		{ line = 1, start_col = #pad, end_col = #cont, hl_group = "AtlasTextMuted" },
		{ line = 1, start_col = #cont, end_col = #cont + #author, hl_group = presentation.author_hl(author) },
		{ line = 1, start_col = #cont + #author, end_col = #second, hl_group = "AtlasTextMuted" },
	}
	return { first, second }, highlights
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

	table.insert(lines, "")
	for idx, commit in ipairs(entries) do
		local last = idx == #entries
		local commit_lines, commit_highlights = render_commit(commit, width - 1, last)
		local first_line = #lines
		utils.append_block(lines, spans, { lines = commit_lines, highlights = commit_highlights })
		for lnum = first_line + 1, #lines do
			line_map[lnum] = { kind = "commit", commit = commit }
		end
		if not last then
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
