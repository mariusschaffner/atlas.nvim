-- The MR detail view's Commits tab: commits grouped by day (author avatar
-- chips + date), one row each with a graph node and a Conventional Commits
-- type chip coloured by type, the scope, the subject, then time, author and
-- short hash in fixed columns. The cursor row fills its node and shows
-- "⏎ diff · y sha"; a per-type tally sits at the bottom right.
local M = {}

local utils = require("atlas.ui.shared.utils")
local spinner = require("atlas.ui.components.spinner")
local avatar = require("atlas.ui.components.avatar")
local keyhints = require("atlas.ui.components.keyhints")
local help = require("atlas.ui.popups.help")
local resolver = require("atlas.core.keymaps")
local presentation = require("atlas.pulls.ui.presentation")
local notify = require("atlas.core.notify")
local request_scope = require("atlas.core.requests")
local detail = require("atlas.pulls.ui.detail.state")
local model = require("atlas.pulls.ui.detail.tabs.commits.model")

local PADDING_X = 1
local COL_GAP = 2
local MAX_SCOPE_W = 10
local MAX_AUTHOR_W = 18
local HASH_W = 8
local TIME_W = 5

local hint_ns = vim.api.nvim_create_namespace("atlas.pulls.detail.commits.cursor")

---@class AtlasCommitTypeStyle
---@field chip string Chip highlight (tinted background).
---@field node string Graph node / tally colour.

---@type table<string, AtlasCommitTypeStyle>
local TYPE_STYLES = {
	feat = { chip = "AtlasCommitChipFeat", node = "AtlasGreen" },
	fix = { chip = "AtlasCommitChipFix", node = "AtlasOrange" },
	testing = { chip = "AtlasCommitChipTesting", node = "AtlasYellow" },
	test = { chip = "AtlasCommitChipTesting", node = "AtlasYellow" },
	merge = { chip = "AtlasCommitChipMerge", node = "AtlasPurple" },
	docs = { chip = "AtlasCommitChipDocs", node = "AtlasAccent" },
	refactor = { chip = "AtlasCommitChipRefactor", node = "AtlasCyan" },
	perf = { chip = "AtlasCommitChipRefactor", node = "AtlasCyan" },
	revert = { chip = "AtlasCommitChipRevert", node = "AtlasRed" },
}
local OTHER_STYLE = { chip = "AtlasCommitChipOther", node = "AtlasTextMuted" }

---@param kind string|nil
---@return AtlasCommitTypeStyle
local function style_for(kind)
	return kind and TYPE_STYLES[kind] or OTHER_STYLE
end

---@class PullsCommitsTabState
---@field current_pr PullRequest|nil
---@field commits PullsCommit[]|"loading"|string|nil
---@field requests AtlasRequestScope
---@field layout { node_col: integer, hint_end_col: integer }|nil Display columns from the last render, for the cursor-row overlay.
local state = {
	current_pr = nil,
	commits = nil,
	requests = request_scope.new(),
	layout = nil,
}

local function reset_requests()
	state.requests.cancel()
	state.requests = request_scope.new()
end

function M.reset()
	reset_requests()
	state.current_pr = nil
	state.commits = nil
	state.layout = nil
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

---@param text string
---@param width integer
---@return string
local function fit(text, width)
	if width <= 0 then
		return ""
	end
	if vim.api.nvim_strwidth(text) > width then
		text = utils.truncate(text, width)
	end
	return text .. string.rep(" ", math.max(0, width - vim.api.nvim_strwidth(text)))
end

---@param text string
---@param width integer
---@return string
local function rjust(text, width)
	return string.rep(" ", math.max(0, width - vim.api.nvim_strwidth(text))) .. text
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

---@class PullsCommitsRenderContext
---@field lines string[]
---@field spans table[]
---@field line_map table<integer, table>

---@param ctx PullsCommitsRenderContext
---@param parts { [1]: string, [2]: string|nil }[]
---@param entry table|nil
local function push_row(ctx, parts, entry)
	local row = #ctx.lines
	local line = ""
	for _, part in ipairs(parts) do
		if part[2] and part[1] ~= "" then
			table.insert(ctx.spans, { line = row, start_col = #line, end_col = #line + #part[1], hl_group = part[2] })
		end
		line = line .. part[1]
	end
	table.insert(ctx.lines, line)
	if entry then
		ctx.line_map[#ctx.lines] = entry
	end
end

---@param width integer
---@return string[], table[], table<integer, table>
local function render_commits(width)
	---@type PullsCommitsRenderContext
	local ctx = { lines = {}, spans = {}, line_map = {} }
	state.layout = nil

	if state.commits == nil then
		return ctx.lines, ctx.spans, ctx.line_map
	end
	if state.commits == "loading" then
		utils.push(ctx.lines, ctx.spans, spinner.with_text("Loading commits..."), "AtlasTextMuted", PADDING_X)
		return ctx.lines, ctx.spans, ctx.line_map
	end
	if type(state.commits) == "string" then
		utils.push(ctx.lines, ctx.spans, state.commits, "AtlasLogError", PADDING_X)
		return ctx.lines, ctx.spans, ctx.line_map
	end
	local entries = state.commits --[[@as PullsCommit[] ]]
	if #entries == 0 then
		utils.push(ctx.lines, ctx.spans, "No commits yet.", "AtlasTextMuted", PADDING_X)
		return ctx.lines, ctx.spans, ctx.line_map
	end

	-- Column widths from the data: type chip (" testing "), scope, author.
	local parsed, messages = {}, {}
	local chip_w, scope_w, author_w = 0, 0, 0
	for i, commit in ipairs(entries) do
		parsed[i] = model.parse(commit.message)
		-- Oldest first, so tally ties break by which type showed up first.
		messages[#entries - i + 1] = commit.message
		if parsed[i].type then
			chip_w = math.max(chip_w, vim.api.nvim_strwidth(parsed[i].type) + 2)
		end
		if parsed[i].scope then
			scope_w = math.max(scope_w, math.min(MAX_SCOPE_W, vim.api.nvim_strwidth(parsed[i].scope)))
		end
		author_w = math.max(author_w, math.min(MAX_AUTHOR_W, vim.api.nvim_strwidth(display_author(commit))))
	end

	local pad = string.rep(" ", PADDING_X)
	local gap = string.rep(" ", COL_GAP)
	local left_w = PADDING_X + 1 + COL_GAP + (chip_w > 0 and chip_w + COL_GAP or 0) + (scope_w > 0 and scope_w + COL_GAP or 0)
	local right_w = COL_GAP + TIME_W + COL_GAP + author_w + COL_GAP + HASH_W + 1
	local subject_w = math.max(8, width - left_w - right_w)
	state.layout = { node_col = PADDING_X, hint_end_col = left_w + subject_w }

	table.insert(ctx.lines, "")
	local index = 1
	while index <= #entries do
		-- One group per local day: avatar chips of that day's authors + date.
		local day = utils.local_day_key(entries[index].date)
		local last = index
		while last + 1 <= #entries and utils.local_day_key(entries[last + 1].date) == day do
			last = last + 1
		end
		if index > 1 then
			table.insert(ctx.lines, "")
		end
		local header, seen = { { pad } }, {}
		for i = index, last do
			local author = display_author(entries[i])
			if not seen[author] then
				seen[author] = true
				local chip, chip_hl = avatar.chip(author)
				table.insert(header, { chip, chip_hl })
				table.insert(header, { " " })
			end
		end
		local epoch = utils.iso_epoch(entries[index].date)
		table.insert(header, { epoch and os.date("%d.%m.%Y", epoch) or day, "AtlasTextBright" })
		push_row(ctx, header)

		for i = index, last do
			local commit, info = entries[i], parsed[i]
			local style = style_for(info.type)
			local parts = {
				{ pad },
				{ info.merge and "◇" or "○", style.node },
				{ gap },
			}
			if chip_w > 0 then
				if info.type then
					local chip = " " .. info.type .. " "
					table.insert(parts, { chip, style.chip })
					table.insert(parts, { string.rep(" ", chip_w - vim.api.nvim_strwidth(chip)) .. gap })
				else
					table.insert(parts, { string.rep(" ", chip_w) .. gap })
				end
			end
			if scope_w > 0 then
				table.insert(parts, { fit(info.scope or "", scope_w), "AtlasTextMuted" })
				table.insert(parts, { gap })
			end
			local author = display_author(commit)
			vim.list_extend(parts, {
				{ fit(info.subject, subject_w), info.merge and "AtlasTextMuted" or "AtlasTextBright" },
				{ gap },
				{ rjust(utils.local_time(commit.date), TIME_W), "AtlasTextMuted" },
				{ gap },
				{ fit(author, author_w), presentation.author_hl(author) },
				{ gap },
				{ tostring(commit.short_hash or commit.hash or ""):sub(1, HASH_W), "AtlasAccent" },
			})
			push_row(ctx, parts, { kind = "commit", commit = commit, merge = info.merge, node_hl = style.node })
		end
		index = last + 1
	end

	-- Per-type tally, right-aligned on the pane's last row when it fits.
	local tally = model.tally(messages)
	if #tally > 0 then
		local parts = {}
		local text_w = 0
		for i, entry in ipairs(tally) do
			if i > 1 then
				table.insert(parts, { " · ", "AtlasTextMuted" })
				text_w = text_w + 3
			end
			local text = string.format("%d %s", entry.count, entry.type)
			table.insert(parts, { text, style_for(entry.type).node })
			text_w = text_w + vim.api.nvim_strwidth(text)
		end
		local height = utils.window.valid(detail.win) and vim.api.nvim_win_get_height(detail.win) or 0
		table.insert(ctx.lines, "")
		while #ctx.lines < height - 1 do
			table.insert(ctx.lines, "")
		end
		table.insert(parts, 1, { string.rep(" ", math.max(0, width - 1 - text_w)) })
		push_row(ctx, parts)
	end

	return ctx.lines, ctx.spans, ctx.line_map
end

--- Fills the cursor row's node and shows its key hints, right-aligned at the
--- end of the subject column.
local function update_cursor()
	local buf, win = detail.buf, detail.win
	if not utils.buffer.valid(buf) then
		return
	end
	vim.api.nvim_buf_clear_namespace(buf, hint_ns, 0, -1)
	if not utils.window.valid(win) or vim.api.nvim_win_get_buf(win) ~= buf or state.layout == nil then
		return
	end
	local lnum = vim.api.nvim_win_get_cursor(win)[1]
	local entry = (detail.line_map or {})[lnum]
	if entry == nil or entry.kind ~= "commit" then
		return
	end
	pcall(vim.api.nvim_buf_set_extmark, buf, hint_ns, lnum - 1, 0, {
		virt_text = { { entry.merge and "◆" or "●", entry.node_hl } },
		virt_text_win_col = state.layout.node_col,
	})
	local chunks = keyhints.chunks({
		{ action_id = "ui.select", label = "diff" },
		{ action_id = "ui.copy_id", label = "sha" },
	}, { separator = " · ", label_hl = "AtlasTextMutedItalic", key_hl = "AtlasTextMutedItalic" })
	local hint_w = 0
	for _, chunk in ipairs(chunks) do
		hint_w = hint_w + vim.api.nvim_strwidth(chunk[1])
	end
	if #chunks > 0 then
		table.insert(chunks, 1, { " ", "AtlasTextMuted" })
		pcall(vim.api.nvim_buf_set_extmark, buf, hint_ns, lnum - 1, 0, {
			virt_text = chunks,
			virt_text_win_col = math.max(0, state.layout.hint_end_col - hint_w - 1),
		})
	end
end

---@param _pr PullRequest
---@param _details PullRequestDetails|nil
---@param width integer
---@return string[], table[], table<integer, table>|nil
function M.render(_pr, _details, width)
	local lines, spans, line_map = render_commits(width)
	-- Re-rendering rewrites every line; put the cursor-row overlay back once
	-- the new content (and line_map) is in place.
	vim.schedule(update_cursor)
	return lines, spans, line_map
end

---@param _lnum integer
---@param entry table
---@return boolean
function M.is_selectable_line(_lnum, entry)
	return entry.kind == "commit"
end

--- `⏎` on a commit: the MR's diff, same as `gd` (no per-commit diff yet).
---@param pr PullRequest
---@param entry table
---@return boolean
function M.on_enter(pr, entry)
	if entry.kind ~= "commit" or detail.provider == nil then
		return false
	end
	require("atlas.pulls.actions").run("open_diff", {
		provider = detail.provider,
		pr = pr,
		details = detail.current_details,
		buf = detail.buf,
		notify = function(level, message, duration)
			notify.show(level, message, { timeout = duration })
		end,
	})
	return true
end

---@return boolean
function M.is_loading()
	return state.commits == "loading"
end

---@return table[]
local function keymap_items()
	local items = {}
	utils.insert_if(
		items,
		resolver.item("ui.copy_id", {
			desc = "Copy commit SHA",
			hint = false,
			opts = { nowait = true, silent = true },
			callback = function()
				local win = detail.win
				local entry = utils.window.valid(win) and (detail.line_map or {})[vim.api.nvim_win_get_cursor(win)[1]]
				if not entry or entry.kind ~= "commit" then
					return
				end
				local sha = tostring(entry.commit.hash or entry.commit.short_hash or "")
				vim.fn.setreg("+", sha)
				vim.fn.setreg('"', sha)
				notify.success("Copied " .. sha:sub(1, HASH_W), { timeout = 1200 })
			end,
		})
	)
	return items
end

---@param buf integer
---@param _refresh fun()|nil
function M.activate(buf, _refresh)
	if not utils.buffer.valid(buf) then
		return
	end
	help.register("Detail", keymap_items(), { index = 212, buffer = buf })
	local group = vim.api.nvim_create_augroup("AtlasPullsCommitsCursor" .. tostring(buf), { clear = true })
	vim.api.nvim_create_autocmd("CursorMoved", { group = group, buffer = buf, callback = update_cursor })
end

---@param buf integer
function M.deactivate(buf)
	pcall(vim.api.nvim_del_augroup_by_name, "AtlasPullsCommitsCursor" .. tostring(buf))
	if utils.buffer.valid(buf) then
		vim.api.nvim_buf_clear_namespace(buf, hint_ns, 0, -1)
		local items = {}
		utils.insert_if(items, resolver.remove_item("ui.copy_id"))
		help.remove("Detail", items, { buffer = buf })
	end
	M.reset()
	notify.clear()
end

return M
