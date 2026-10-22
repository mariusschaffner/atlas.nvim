local M = {}

local help = require("atlas.ui.popups.help")
local resolver = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local keyhints = require("atlas.ui.components.keyhints")
local session_mod = require("atlas.ui.components.composer.session")
local dock = require("atlas.ui.components.composer.dock")
local inline_edit = require("atlas.ui.inline_edit")
local comment_threads = require("atlas.issues.ui.components.comment_threads")
local actions = require("atlas.issues.ui.detail.tabs.conversation.actions")
local detail = require("atlas.issues.ui.detail.state")
local state = require("atlas.issues.ui.detail.tabs.conversation.state")
local presentation = require("atlas.issues.ui.presentation")
local notify = require("atlas.core.notify")

local hint_ns = vim.api.nvim_create_namespace("atlas.issues.detail.conversation.hint")

local REPLY_PLACEHOLDER = "write a reply · markdown, @ to mention"
local DOCK_PLACEHOLDER = "write a comment · markdown, @ to mention, # to link an issue"

---@param issue Issue|nil
---@return boolean
local function guard_open(issue)
	if presentation.is_open(issue) then
		return true
	end
	notify.warn("Issue is closed")
	return false
end

local ACTIONS = {
	"issues.add_comment",
	"ui.comments.reply",
	"ui.comments.edit",
	"ui.delete",
	"ui.comments.react",
	"ui.comments.toggle_resolved",
	"issues.expand_activity",
	"ui.toggle_fold",
	"ui.toggle_all_folds",
}

---@return IssuesCommentsCapability|nil
local function comments_capability()
	return detail.provider and detail.provider.capabilities.comments or nil
end

---@return integer|nil win
local function content_win()
	local win = detail.win
	if win == nil or not vim.api.nvim_win_is_valid(win) then
		return nil
	end
	return win
end

--- The line_map entry under the cursor.
---@return table|nil
local function cursor_entry()
	local win = content_win()
	if win == nil then
		return nil
	end
	return detail.line_map and detail.line_map[vim.api.nvim_win_get_cursor(win)[1]] or nil
end

--- The comment (and its thread root) under the cursor, if any.
---@return IssueComment|nil comment, IssueComment|nil root
local function cursor_comment()
	local entry = cursor_entry()
	if entry == nil or entry.kind ~= "comment" then
		return nil, nil
	end
	return entry.comment, entry.root
end

---@param comment IssueComment
---@param root IssueComment
---@return AtlasKeyHintSegment[]
local function comment_hints(comment, root)
	local comments = comments_capability()
	local open = presentation.is_open(detail.current_issue)
	local own = actions.is_own_comment(comment)
	local hints = {}
	if comments and open then
		if comments.add_comment then
			table.insert(hints, { action_id = "ui.comments.reply", label = "reply" })
		end
		if own and comments.edit_comment then
			table.insert(hints, { action_id = "ui.comments.edit", label = "edit" })
		end
		if own and comments.delete_comment then
			table.insert(hints, { action_id = "ui.delete", label = "delete" })
		end
		if comments.add_reaction and #(comments.reaction_options or {}) > 0 then
			table.insert(hints, { action_id = "ui.comments.react", label = "react" })
		end
		if root.resolvable and comments.set_thread_resolved then
			table.insert(hints, {
				action_id = "ui.comments.toggle_resolved",
				label = root.resolved and "unresolve" or "resolve",
			})
		end
	end
	return hints
end

--- Right-aligned "gc reply · gE edit · …" on the cursor line while it is on
--- a comment (mirrors the Description tab's "x toggle" hint). On a comment's
--- header row -- where the time already sits on the right -- it goes on the
--- first body row instead.
function M.update_hint()
	local buf = detail.buf
	local win = content_win()
	if buf == nil or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	vim.api.nvim_buf_clear_namespace(buf, hint_ns, 0, -1)
	if win == nil or vim.api.nvim_win_get_buf(win) ~= buf or inline_edit.is_active(buf) then
		return
	end
	if state.session and state.session.is_open() then
		return
	end
	local lnum = vim.api.nvim_win_get_cursor(win)[1]
	local entry = detail.line_map and detail.line_map[lnum]
	if entry == nil or entry.kind ~= "comment" or entry.row_kind == "composer" then
		return
	end
	local target = lnum
	if entry.row_kind == "header" then
		local below = detail.line_map[lnum + 1]
		if below and below.kind == "comment" and below.comment_id == entry.comment_id and below.row_kind ~= "header" then
			target = lnum + 1
		end
	end
	local chunks = keyhints.chunks(comment_hints(entry.comment, entry.root), {
		separator = " · ",
		label_hl = "AtlasKeyHintLabel",
	})
	if #chunks == 0 or target > vim.api.nvim_buf_line_count(buf) then
		return
	end
	pcall(vim.api.nvim_buf_set_extmark, buf, hint_ns, target - 1, 0, {
		virt_text = chunks,
		virt_text_pos = "right_align",
	})
end

---@param refresh fun()
local function refresh_and_follow(refresh)
	refresh()
	local win = content_win()
	local id = state.follow_id
	state.follow_id = nil
	local region = id and state.regions["comment:" .. id]
	if win and region then
		pcall(vim.api.nvim_win_set_cursor, win, { region.row + 1, 0 })
	end
	M.update_hint()
end

--- Scrolls the content window so the composer's whole frame (text rows and
--- footer) is visible before the editing float is placed over it.
---@param region AtlasFieldBoxRegion
local function reveal(region)
	local win = content_win()
	if win == nil then
		return
	end
	local last = math.min(vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win)), region.row + region.height + 1)
	pcall(vim.api.nvim_win_set_cursor, win, { last, 0 })
	pcall(vim.api.nvim_win_set_cursor, win, { region.row + 1, 0 })
end

--- Scrolls the content window to its end so the "· NOW ·" marker sits right
--- above the expanded dock.
local function scroll_to_end()
	local win = content_win()
	if win == nil then
		return
	end
	local count = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
	pcall(vim.api.nvim_win_set_cursor, win, { count, 0 })
	vim.api.nvim_win_call(win, function()
		vim.cmd("normal! zb")
	end)
end

---@param buf integer
---@param refresh fun()
---@param kind "reply"|"edit"
---@param comment IssueComment Comment being edited, or the one replied to.
---@param root IssueComment Thread root.
---@param seed_text string
local function open_inline_composer(buf, refresh, kind, comment, root, seed_text)
	local issue = detail.current_issue
	local win = content_win()
	if issue == nil or win == nil then
		return
	end
	if state.session and state.session.is_open() then
		return
	end

	local function clear()
		state.editing_id = nil
		state.composing = nil
		state.session = nil
		state.composer = { height = 1, mode = "i", dirty = false }
	end

	local submit
	if kind == "reply" then
		state.composing = { kind = "reply", parent = root, seed_text = seed_text }
		submit = function(text, done)
			actions.reply(issue, root, text, done)
		end
	else
		state.editing_id = tostring(comment.id)
		submit = function(text, done)
			actions.edit(issue, comment, text, done)
		end
	end
	local _, seed_count = seed_text:gsub("\n", "")
	state.composer = { height = math.min(12, seed_count + 1), mode = "i", dirty = false }
	refresh()
	local region = state.regions.composer
	if region == nil then
		clear()
		refresh()
		return
	end
	reveal(region)

	local extra_keys = {}
	local resolve_keys = resolver.resolve("ui.comments.submit_resolve")
	local comments = comments_capability()
	if kind == "reply" and resolve_keys and root.resolvable and not root.resolved and comments and comments.set_thread_resolved then
		table.insert(extra_keys, {
			keys = resolve_keys,
			callback = function()
				local session = state.session
				if session == nil then
					return
				end
				local text = vim.trim(session.get_text())
				actions.reply(issue, root, text, function(ok, err)
					if not ok then
						if err then
							notify.error(tostring(err))
						end
						return
					end
					actions.set_resolved(issue, root, true, function()
						session.close()
					end)
				end)
			end,
		})
	end

	local session
	session = session_mod.start({
		anchor_win = win,
		region = region,
		seed_text = seed_text,
		placeholder = kind == "reply" and REPLY_PLACEHOLDER or nil,
		completion = actions.get_completion(issue),
		extra_keys = extra_keys,
		on_submit = submit,
		on_done = function()
			clear()
			refresh_and_follow(refresh)
		end,
		on_layout = function(height)
			if state.session ~= session then
				return
			end
			state.composer.height = height
			refresh()
			local new_region = state.regions.composer
			if new_region then
				session.move(new_region)
			end
		end,
		on_state = function(composer_state)
			if state.session ~= session then
				return
			end
			state.composer.mode = composer_state.mode
			state.composer.dirty = composer_state.dirty
			refresh()
		end,
	})
	state.session = session
	if session == nil then
		clear()
		refresh()
	end
end

---@param buf integer
---@param refresh fun()
local function start_reply(buf, refresh)
	local issue = detail.current_issue
	local comment, root = cursor_comment()
	local comments = comments_capability()
	if not issue or not comment or not root or not comments or not comments.add_comment then
		return
	end
	if not guard_open(issue) then
		return
	end

	local seed_text = ""
	if not actions.is_own_comment(comment) then
		local completion = actions.get_completion(issue)
		local mention = completion and completion.format_mention and completion.format_mention(comment.author) or ""
		seed_text = mention ~= "" and (mention .. " ") or ""
	end
	open_inline_composer(buf, refresh, "reply", comment, root, seed_text)
end

---@param buf integer
---@param refresh fun()
local function start_edit(buf, refresh)
	local issue = detail.current_issue
	local comment, root = cursor_comment()
	local comments = comments_capability()
	if not issue or not comment or not root or not comments or not comments.edit_comment then
		return
	end
	if not actions.is_own_comment(comment) or not guard_open(issue) then
		return
	end
	open_inline_composer(buf, refresh, "edit", comment, root, tostring(comment.body or ""))
end

---@param refresh fun()
local function do_delete(refresh)
	local issue = detail.current_issue
	local comment = cursor_comment()
	if not issue or not comment then
		return
	end
	if not actions.is_own_comment(comment) or not guard_open(issue) then
		return
	end
	actions.delete(issue, comment, function()
		refresh()
		M.update_hint()
	end)
end

---@param refresh fun()
local function do_react(refresh)
	local issue = detail.current_issue
	local comment = cursor_comment()
	if not issue or not comment or not guard_open(issue) then
		return
	end
	actions.react(issue, comment, function()
		refresh()
		M.update_hint()
	end)
end

---@param refresh fun()
local function toggle_resolved(refresh)
	local issue = detail.current_issue
	local _, root = cursor_comment()
	if not issue or not root or not root.resolvable or not guard_open(issue) then
		return
	end
	actions.set_resolved(issue, root, not root.resolved, function(ok)
		if ok then
			state.follow_id = tostring(root.id)
			refresh_and_follow(refresh)
		end
	end)
end

---@param refresh fun()
local function toggle_fold(refresh)
	local comment, root = cursor_comment()
	if not comment or not root then
		return
	end
	if state.toggle_comment(comment) then
		refresh()
		M.update_hint()
		return
	end
	for _, node in ipairs(comment_threads.group_comments(state.comments())) do
		if tostring(node.comment.id) == tostring(root.id) and #node.children > 0 then
			state.toggle(root.id)
			state.follow_id = tostring(root.id)
			refresh_and_follow(refresh)
			return
		end
	end
end

--- Expands a collapsed activity run ("⋯ N more changes"), or a collapsed
--- thread's "▸ N replies" row.
---@param refresh fun()
local function expand_under_cursor(refresh)
	local entry = cursor_entry()
	if entry == nil then
		return
	end
	if entry.kind == "activity_gap" and entry.run_id then
		state.toggle_run(entry.run_id)
		refresh()
		M.update_hint()
	elseif entry.kind == "comment" and entry.row_kind == "collapsed" then
		toggle_fold(refresh)
	end
end

--- Posts a new top-level comment from the dock.
---@param refresh fun()
---@return fun(text: string, done: fun(ok: boolean, err: string|nil))
local function dock_submit(refresh)
	return function(text, done)
		local issue = detail.current_issue
		if issue == nil then
			done(false, "No issue")
			return
		end
		actions.add(issue, text, function(ok, err)
			done(ok, err)
			if ok then
				vim.schedule(function()
					refresh_and_follow(refresh)
				end)
			end
		end)
	end
end

--- Attaches (or refreshes) the docked "write a new comment…" composer --
--- Activity tab only, and only while new comments can be added.
---@param buf integer
---@param refresh fun()
function M.attach_dock(buf, refresh)
	local issue = detail.current_issue
	local comments = comments_capability()
	if not issue or not comments or not comments.add_comment or not presentation.is_open(issue) then
		dock.detach()
		return
	end
	local user = require("atlas.issues.state").current_user
	dock.attach({
		author = user and user.display_name or nil,
		focus_hints = { { action_id = "issues.comment", label = "focus" } },
		hints = {
			{ action_id = "ui.submit", label = "post" },
		},
		placeholder = DOCK_PLACEHOLDER,
		completion = actions.get_completion(issue),
		on_submit = dock_submit(refresh),
		on_resize = function()
			refresh()
			if dock.is_expanded() then
				scroll_to_end()
			end
		end,
	})
end

--- Expands the dock and focuses it (`issues.add_comment` here, and the
--- detail view's global `issues.comment`).
---@param buf integer
---@param refresh fun()
---@param seed_text string|nil
function M.focus_dock(buf, refresh, seed_text)
	local issue = detail.current_issue
	if not issue or not guard_open(issue) then
		return
	end
	if state.session and state.session.is_open() then
		return
	end
	if not dock.is_attached() then
		M.attach_dock(buf, refresh)
	end
	vim.api.nvim_buf_clear_namespace(buf, hint_ns, 0, -1)
	dock.focus(seed_text)
end

--- Opens the Activity tab's comment composer. Exported so the detail view's
--- global `c` keymap (bound to `issues.comment`, reachable from any tab) can
--- reuse it after switching here.
---@param buf integer
---@param refresh fun()
function M.start_add(buf, refresh)
	M.focus_dock(buf, refresh)
end

---@param buf integer
---@param refresh fun()
function M.setup(buf, refresh)
	local comments = comments_capability()
	local items = {}

	---@param action_id string
	---@param desc string
	---@param callback fun()
	local function add(action_id, desc, callback)
		utils.insert_if(
			items,
			resolver.item(action_id, {
				desc = desc,
				hint = false,
				opts = { nowait = true, silent = true },
				callback = callback,
			})
		)
	end

	if comments and comments.add_comment then
		add("issues.add_comment", "Add comment", function()
			M.focus_dock(buf, refresh)
		end)
		add("ui.comments.reply", "Reply to comment", function()
			start_reply(buf, refresh)
		end)
	end
	if comments and comments.edit_comment then
		add("ui.comments.edit", "Edit comment", function()
			start_edit(buf, refresh)
		end)
	end
	if comments and comments.delete_comment then
		add("ui.delete", "Delete comment", function()
			do_delete(refresh)
		end)
	end
	if comments and comments.add_reaction and #(comments.reaction_options or {}) > 0 then
		add("ui.comments.react", "Add reaction", function()
			do_react(refresh)
		end)
	end
	if comments and comments.set_thread_resolved then
		add("ui.comments.toggle_resolved", "Resolve / unresolve thread", function()
			toggle_resolved(refresh)
		end)
	end
	add("issues.expand_activity", "Expand collapsed activity", function()
		expand_under_cursor(refresh)
	end)
	add("ui.toggle_fold", "Expand / collapse comment or thread", function()
		toggle_fold(refresh)
	end)
	add("ui.toggle_all_folds", "Expand / collapse all threads", function()
		if state.toggle_all_threads(comment_threads.group_comments(state.comments())) then
			refresh()
			M.update_hint()
		end
	end)

	help.register("Detail", items, { index = 212, buffer = buf })

	local group = vim.api.nvim_create_augroup("AtlasIssuesConversationHint" .. tostring(buf), { clear = true })
	vim.api.nvim_create_autocmd("CursorMoved", {
		group = group,
		buffer = buf,
		callback = function()
			M.update_hint()
		end,
	})

	M.attach_dock(buf, refresh)
end

---@param buf integer
function M.teardown(buf)
	local items = {}
	for _, action_id in ipairs(ACTIONS) do
		utils.insert_if(items, resolver.item(action_id, {}))
	end
	help.remove("Detail", items, { buffer = buf })
	pcall(vim.api.nvim_del_augroup_by_name, "AtlasIssuesConversationHint" .. tostring(buf))
	if vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_clear_namespace(buf, hint_ns, 0, -1)
	end
	if state.session and state.session.is_open() then
		state.session.close()
	end
	state.session = nil
	state.editing_id = nil
	state.composing = nil
	dock.detach()
end

return M
