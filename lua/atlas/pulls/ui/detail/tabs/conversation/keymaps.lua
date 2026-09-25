local M = {}

local help = require("atlas.ui.popups.help")
local resolver = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local review_threads = require("atlas.pulls.ui.components.review_threads")
local inline_field_edit = require("atlas.ui.inline_field_edit")
local actions = require("atlas.pulls.ui.detail.tabs.conversation.actions")
local detail = require("atlas.pulls.ui.detail.state")
local state = require("atlas.pulls.ui.detail.tabs.conversation.state")
local presentation = require("atlas.pulls.ui.presentation")
local notify = require("atlas.core.notify")

---@param pr PullRequest|nil
---@return boolean
local function guard_open(pr)
	if presentation.is_open_or_draft(pr) then
		return true
	end
	notify.warn("PR is not open")
	return false
end

local ACTIONS = {
	"ui.comments.add",
	"ui.comments.reply",
	"ui.comments.edit",
	"ui.delete",
	"ui.comments.react",
	"ui.next_item",
	"ui.previous_item",
}

---@param region AtlasFieldBoxRegion
local function move_cursor_to(region)
	local win = detail.win
	if win == nil or not vim.api.nvim_win_is_valid(win) then
		return
	end
	pcall(vim.api.nvim_win_set_cursor, win, { region.row + 1, 0 })
end

---@param refresh fun()
local function refresh_and_follow(refresh)
	refresh()
	local id = state.active_id
	local region = id and state.regions[id]
	if region then
		move_cursor_to(region)
	end
end

---@param buf integer
---@param refresh fun()
---@param opts { region: AtlasFieldBoxRegion, seed_text: string, on_save: fun(text: string, done: fun(ok: boolean, err: string|nil)), on_done: fun() }
local function start_inline_edit(buf, refresh, opts)
	local win = detail.win
	if win == nil or not vim.api.nvim_win_is_valid(win) then
		return
	end
	inline_field_edit.start({
		anchor_win = win,
		row = opts.region.row,
		col = opts.region.col,
		width = opts.region.width,
		height = opts.region.height,
		seed_text = opts.seed_text,
		on_save = opts.on_save,
		on_cancel = function() end,
		on_done = opts.on_done,
	})
	-- The detail view's own footer ("[i] - Add") is driven by
	-- inline_field_edit.is_active(), which only flips true once start() above
	-- returns -- refresh again so it picks that up.
	refresh()
end

---@param refresh fun()
local function start_add(buf, refresh)
	local pr = detail.current_pr
	local comments = detail.provider and detail.provider.capabilities.comments
	if not pr or not comments or not comments.add_comment then
		return
	end
	if not guard_open(pr) then
		return
	end
	state.composing = { kind = "add", seed_text = "" }
	refresh()
	local region = state.regions.composing
	if not region then
		state.composing = nil
		return
	end
	move_cursor_to(region)
	start_inline_edit(buf, refresh, {
		region = region,
		seed_text = "",
		on_save = function(text, done)
			actions.add(pr, text, done)
		end,
		on_done = function()
			state.composing = nil
			refresh_and_follow(refresh)
		end,
	})
end

---@param comment PullsComment
---@return PullsComment thread_root
local function find_thread_root(comment)
	local thread_root = comment
	for _, node in ipairs(review_threads.group_comments(state.comments(false))) do
		local function find(n)
			if tostring(n.comment.id) == tostring(comment.id) then
				return n.comment
			end
			for _, child in ipairs(n.children) do
				local found = find(child)
				if found then
					return n.comment
				end
			end
			return nil
		end
		local found_root = find(node)
		if found_root then
			thread_root = found_root
			break
		end
	end
	return thread_root
end

---@param buf integer
---@param refresh fun()
local function start_reply(buf, refresh)
	local pr = detail.current_pr
	local entry = state.active_entry()
	local comments = detail.provider and detail.provider.capabilities.comments
	if not pr or not entry or entry.kind ~= "comment" or not comments or not comments.add_comment then
		return
	end
	if not guard_open(pr) then
		return
	end
	---@type PullsComment
	local comment = entry.entity
	if comment.is_task then
		return
	end

	local thread_root = find_thread_root(comment)

	local completion = actions.get_completion(pr)
	local mention = ""
	if completion and completion.format_mention then
		mention = completion.format_mention(comment.author) or ""
	end
	local seed_text = mention ~= "" and (mention .. " ") or ""

	state.composing = { kind = "reply", parent = thread_root, seed_text = seed_text }
	refresh()
	local region = state.regions.composing
	if not region then
		state.composing = nil
		return
	end
	-- The composing box always renders at the end of the thread, which can
	-- be well past the reply being answered and outside the current
	-- viewport; `relative="win"` floats don't auto-scroll for that.
	move_cursor_to(region)
	start_inline_edit(buf, refresh, {
		region = region,
		seed_text = seed_text,
		on_save = function(text, done)
			actions.reply(pr, thread_root, text, done)
		end,
		on_done = function()
			state.composing = nil
			refresh_and_follow(refresh)
		end,
	})
end

---@param buf integer
---@param refresh fun()
local function start_edit(buf, refresh)
	local pr = detail.current_pr
	local entry = state.active_entry()
	if not pr or not entry then
		return
	end
	if not guard_open(pr) then
		return
	end

	if entry.kind == "review" then
		actions.edit_review(pr, entry.entity, refresh)
		return
	end
	if entry.kind == "task" then
		actions.edit_task(pr, entry.entity, refresh)
		return
	end

	---@type PullsComment
	local comment = entry.entity
	local comments = detail.provider and detail.provider.capabilities.comments
	if not comments or not comments.edit_comment or not actions.is_own_comment(comment) then
		return
	end

	state.editing_id = tostring(comment.id)
	refresh()
	local region = state.regions["comment:" .. tostring(comment.id)]
	if not region then
		state.editing_id = nil
		return
	end
	move_cursor_to(region)
	start_inline_edit(buf, refresh, {
		region = region,
		seed_text = tostring(comment.content_raw or ""),
		on_save = function(text, done)
			actions.edit_comment(pr, comment, text, done)
		end,
		on_done = function()
			state.editing_id = nil
			refresh_and_follow(refresh)
		end,
	})
end

---@param refresh fun()
local function do_delete(refresh)
	local pr = detail.current_pr
	local entry = state.active_entry()
	if not pr or not entry or entry.kind == "review" then
		return
	end
	if not guard_open(pr) then
		return
	end
	---@type PullsComment
	local comment = entry.entity
	if entry.kind == "comment" and not actions.is_own_comment(comment) then
		return
	end
	actions.delete(pr, comment, refresh)
end

---@param refresh fun()
local function do_react(refresh)
	local pr = detail.current_pr
	local entry = state.active_entry()
	if not pr or not entry or entry.kind ~= "comment" then
		return
	end
	if not guard_open(pr) then
		return
	end
	actions.react(pr, entry.entity, refresh)
end

---@param refresh fun()
local function do_toggle_task(refresh)
	local pr = detail.current_pr
	local entry = state.active_entry()
	if not pr or not entry or entry.kind ~= "task" then
		return
	end
	if not guard_open(pr) then
		return
	end
	actions.toggle_task(pr, entry.entity, refresh)
end

---@param refresh fun()
local function toggle_fold(refresh)
	local entry = state.active_entry()
	if not entry then
		return
	end
	if entry.kind == "task" then
		if state.toggle_comment(entry.entity) then
			refresh()
		end
		return
	end
	if entry.kind ~= "comment" then
		return
	end
	---@type PullsComment
	local comment = entry.entity
	if state.toggle_comment(comment) then
		refresh()
		return
	end
	for _, node in ipairs(review_threads.group_comments(state.comments(false))) do
		if tostring(node.comment.id) == tostring(comment.id) and #node.children > 0 then
			state.toggle(node.comment.id)
			refresh()
			return
		end
	end
end

---@param buf integer
---@param refresh fun()
function M.setup(buf, refresh)
	local provider = detail.provider
	local tasks = provider and provider.capabilities.tasks
	local has_tasks = tasks and tasks.edit_task ~= nil
	local items = {}
	utils.insert_if(
		items,
		resolver.item("ui.comments.add", {
			desc = "Add comment",
			hint = false,
			opts = { nowait = true, silent = true },
			callback = function()
				start_add(buf, refresh)
			end,
		})
	)
	utils.insert_if(
		items,
		resolver.item("ui.comments.reply", {
			desc = "Reply to comment",
			hint = false,
			opts = { nowait = true, silent = true },
			callback = function()
				start_reply(buf, refresh)
			end,
		})
	)
	utils.insert_if(
		items,
		resolver.item("ui.comments.edit", {
			desc = has_tasks and "Edit comment / task / review" or "Edit comment",
			hint = false,
			opts = { nowait = true, silent = true },
			callback = function()
				start_edit(buf, refresh)
			end,
		})
	)
	utils.insert_if(
		items,
		resolver.item("ui.delete", {
			desc = has_tasks and "Delete comment / task" or "Delete comment",
			hint = false,
			opts = { nowait = true, silent = true },
			callback = function()
				do_delete(refresh)
			end,
		})
	)
	utils.insert_if(
		items,
		resolver.item("ui.comments.react", {
			desc = "Add reaction",
			hint = false,
			opts = { nowait = true, silent = true },
			callback = function()
				do_react(refresh)
			end,
		})
	)
	utils.insert_if(
		items,
		resolver.item("ui.next_item", {
			desc = "Next item",
			hint = false,
			opts = { nowait = true, silent = true },
			callback = function()
				state.move_active(1)
				refresh_and_follow(refresh)
			end,
		})
	)
	utils.insert_if(
		items,
		resolver.item("ui.previous_item", {
			desc = "Previous item",
			hint = false,
			opts = { nowait = true, silent = true },
			callback = function()
				state.move_active(-1)
				refresh_and_follow(refresh)
			end,
		})
	)
	if has_tasks then
		local toggle_task = resolver.item("pulls.review.diff.toggle_resolved", {
			desc = "Toggle task",
			hint = false,
			opts = { nowait = true, silent = true },
			callback = function()
				do_toggle_task(refresh)
			end,
		})
		if toggle_task then
			table.insert(items, toggle_task)
		end
	end
	local fold_keys = resolver.resolve("ui.toggle_fold")
	if fold_keys ~= nil then
		table.insert(items, {
			key = fold_keys,
			desc = "Expand / collapse comment or thread",
			hint = false,
			opts = { nowait = true, silent = true },
			callback = function()
				toggle_fold(refresh)
			end,
		})
	end
	local toggle_all = resolver.item("ui.toggle_all_folds", {
		desc = "Expand / collapse all threads",
		hint = false,
		opts = { nowait = true, silent = true },
		callback = function()
			local comments = state.comments(false)
			local task_comments = state.comments(true)
			if state.toggle_all_threads(review_threads.group_comments(comments, task_comments)) then
				refresh()
			end
		end,
	})
	if toggle_all then
		table.insert(items, toggle_all)
	end
	help.register("Detail", items, { index = 212, buffer = buf })
end

---@param buf integer
function M.teardown(buf)
	local items = {}
	for _, action_id in ipairs(ACTIONS) do
		utils.insert_if(items, resolver.item(action_id, {}))
	end
	local fold_keys = resolver.resolve("ui.toggle_fold")
	if fold_keys ~= nil then
		table.insert(items, { key = fold_keys })
	end
	local toggle_all_keys = resolver.resolve("ui.toggle_all_folds")
	if toggle_all_keys ~= nil then
		table.insert(items, { key = #toggle_all_keys == 1 and toggle_all_keys[1] or toggle_all_keys })
	end
	local provider = detail.provider
	local tasks = provider and provider.capabilities.tasks
	if tasks and tasks.edit_task then
		local toggle_task_keys = resolver.resolve("pulls.review.diff.toggle_resolved")
		if toggle_task_keys ~= nil then
			table.insert(items, { key = #toggle_task_keys == 1 and toggle_task_keys[1] or toggle_task_keys })
		end
	end
	help.remove("Detail", items, { buffer = buf })
end

return M
