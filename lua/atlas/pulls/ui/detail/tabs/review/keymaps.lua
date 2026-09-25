local M = {}

local help = require("atlas.ui.popups.help")
local resolver = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local inline_field_edit = require("atlas.ui.inline_field_edit")
local notify = require("atlas.core.notify")
local presentation = require("atlas.pulls.ui.presentation")
local detail = require("atlas.pulls.ui.detail.state")
local state = require("atlas.pulls.ui.detail.tabs.review.state")

---@param pr PullRequest|nil
---@return boolean
local function guard_open(pr)
	if presentation.is_open_or_draft(pr) then
		return true
	end
	notify.warn("PR is not open")
	return false
end

---@param comment PullsComment
---@return boolean
local function is_own_comment(comment)
	local current_user = require("atlas.pulls.state").current_user
	if not current_user or not comment or not comment.author then
		return false
	end
	return tostring(current_user.id) == tostring(comment.author.id)
end

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
	-- The tab's own footer/border is driven by inline_field_edit.is_active(),
	-- which only flips true once start() above returns -- refresh again so
	-- it picks that up.
	refresh()
end

---@param buf integer
---@param refresh fun()
local function start_reply(buf, refresh)
	local pr = detail.current_pr
	local entry = state.active_entry()
	if not pr or not entry or entry.kind ~= "comment" then
		return
	end
	local comment = entry.comment
	if comment.is_task then
		return
	end
	local comments = detail.provider and detail.provider.capabilities.comments
	if not comments or not comments.add_comment then
		return
	end
	if not guard_open(pr) then
		return
	end

	local root = entry.root or comment
	state.composing = { parent = root }
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
			local tab = require("atlas.pulls.ui.detail.tabs.review")
			tab.reply_comment(pr, root, text, done)
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

	if entry.kind == "task" then
		local tab = require("atlas.pulls.ui.detail.tabs.review")
		tab.edit_task(pr, entry.comment, refresh)
		return
	end
	if entry.kind ~= "comment" then
		return
	end

	local comment = entry.comment
	local comments = detail.provider and detail.provider.capabilities.comments
	if not comments or not comments.edit_comment or not is_own_comment(comment) then
		return
	end
	if not guard_open(pr) then
		return
	end

	local region = state.regions[entry.id]
	if not region then
		return
	end
	state.editing_id = entry.id
	refresh()
	move_cursor_to(region)
	start_inline_edit(buf, refresh, {
		region = region,
		seed_text = tostring(comment.content_raw or ""),
		on_save = function(text, done)
			local tab = require("atlas.pulls.ui.detail.tabs.review")
			tab.edit_comment(pr, comment, text, done)
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
	if not pr or not entry or entry.kind == "block" then
		return
	end
	if not guard_open(pr) then
		return
	end
	local tab = require("atlas.pulls.ui.detail.tabs.review")
	tab.delete_comment(pr, { comment = entry.comment }, refresh)
end

---@param refresh fun()
local function do_toggle_resolved(refresh)
	local pr = detail.current_pr
	local entry = state.active_entry()
	if not pr or not entry or entry.kind == "block" then
		return
	end
	if not guard_open(pr) then
		return
	end
	local tab = require("atlas.pulls.ui.detail.tabs.review")
	tab.toggle_resolved(pr, { comment = entry.comment, thread_root = entry.root }, refresh)
end

---@param refresh fun()
local function do_toggle_fold(refresh)
	local entry = state.active_entry()
	if entry == nil then
		return
	end
	if entry.kind == "block" then
		state.toggle_file_collapsed(entry.path)
		refresh()
		return
	end
	if entry.kind == "comment" and entry.root then
		if state.toggle_threads({ entry.root }) then
			refresh()
		end
	end
end

---@param buf integer
---@param refresh fun()
function M.setup(buf, refresh)
	local tab = require("atlas.pulls.ui.detail.tabs.review")
	local provider = detail.provider
	local tasks = provider and provider.capabilities.tasks
	local edit_description = tasks and tasks.edit_task and "Edit comment / task" or "Edit comment"
	local delete_description = tasks and tasks.delete_task and "Delete comment / task" or "Delete comment"

	local items = {}
	utils.insert_if(
		items,
		resolver.item("ui.next_item", {
			desc = "Next review block / comment",
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
			desc = "Previous review block / comment",
			hint = false,
			opts = { nowait = true, silent = true },
			callback = function()
				state.move_active(-1)
				refresh_and_follow(refresh)
			end,
		})
	)
	utils.insert_if(
		items,
		resolver.item("ui.comments.reply", {
			desc = "Reply to comment",
			hint = false, -- shown on the active comment/composing box's own bottom border instead
			opts = { nowait = true, silent = true },
			callback = function()
				start_reply(buf, refresh)
			end,
		})
	)
	utils.insert_if(
		items,
		resolver.item("ui.comments.edit", {
			desc = edit_description,
			hint = false, -- shown on the active comment box's own bottom border instead
			opts = { nowait = true, silent = true },
			callback = function()
				start_edit(buf, refresh)
			end,
		})
	)
	if tasks and tasks.add_task then
		utils.insert_if(
			items,
			resolver.item("pulls.review.add_task", {
				desc = "Add task",
				hint = false,
				opts = { nowait = true, silent = true },
				callback = function()
					local pr = detail.current_pr
					if pr then
						tab.add_task(pr, refresh)
					end
				end,
			})
		)
	end
	utils.insert_if(
		items,
		resolver.item("ui.delete", {
			desc = delete_description,
			hint = false, -- shown on the active comment box's own bottom border instead
			opts = { nowait = true, silent = true },
			callback = function()
				do_delete(refresh)
			end,
		})
	)
	utils.insert_if(
		items,
		resolver.item("pulls.review.diff.toggle_resolved", {
			desc = "Toggle resolved",
			hint = false, -- shown on the active comment box's own bottom border instead
			opts = { nowait = true, silent = true },
			callback = function()
				do_toggle_resolved(refresh)
			end,
		})
	)
	utils.insert_if(
		items,
		resolver.item("ui.toggle_fold", {
			desc = "Toggle review block / thread fold",
			hint = false, -- shown on the active block/comment box's own bottom border instead
			opts = { nowait = true, silent = true },
			callback = function()
				do_toggle_fold(refresh)
			end,
		})
	)
	utils.insert_if(
		items,
		resolver.item("ui.toggle_all_folds", {
			desc = "Toggle all thread folds",
			hint = false,
			opts = { nowait = true, silent = true },
			callback = function()
				local data = state.data
				if not data then
					return
				end
				if state.toggle_all_folds(data.comments) then
					refresh()
				end
			end,
		})
	)
	utils.insert_if(
		items,
		resolver.item("pulls.review.diff.next_hunk", {
			desc = "Next hunk",
			hint = false,
			opts = { nowait = true, silent = true },
			callback = function()
				local win = detail.win
				if win == nil or not vim.api.nvim_win_is_valid(win) then
					return
				end
				local map = detail.line_map
				local lnum = vim.api.nvim_win_get_cursor(win)[1]
				local last = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
				for ln = lnum + 1, last do
					local e = map[ln]
					if e and e.hunk_start then
						pcall(vim.api.nvim_win_set_cursor, win, { ln, 0 })
						return
					end
				end
			end,
		})
	)
	utils.insert_if(
		items,
		resolver.item("pulls.review.diff.previous_hunk", {
			desc = "Previous hunk",
			hint = false,
			opts = { nowait = true, silent = true },
			callback = function()
				local win = detail.win
				if win == nil or not vim.api.nvim_win_is_valid(win) then
					return
				end
				local map = detail.line_map
				local lnum = vim.api.nvim_win_get_cursor(win)[1]
				for ln = lnum - 1, 1, -1 do
					local e = map[ln]
					if e and e.hunk_start then
						pcall(vim.api.nvim_win_set_cursor, win, { ln, 0 })
						return
					end
				end
			end,
		})
	)

	help.register("Detail", items, { index = 212, buffer = buf })
end

---@param buf integer
function M.teardown(buf)
	local items = {}
	utils.insert_if(items, resolver.remove_item("ui.next_item"))
	utils.insert_if(items, resolver.remove_item("ui.previous_item"))
	utils.insert_if(items, resolver.remove_item("ui.comments.reply"))
	utils.insert_if(items, resolver.remove_item("ui.comments.edit"))
	utils.insert_if(items, resolver.remove_item("pulls.review.add_task"))
	utils.insert_if(items, resolver.remove_item("ui.delete"))
	utils.insert_if(items, resolver.remove_item("pulls.review.diff.toggle_resolved"))
	utils.insert_if(items, resolver.remove_item("ui.toggle_fold"))
	utils.insert_if(items, resolver.remove_item("ui.toggle_all_folds"))
	utils.insert_if(items, resolver.remove_item("pulls.review.diff.next_hunk"))
	utils.insert_if(items, resolver.remove_item("pulls.review.diff.previous_hunk"))
	help.remove("Detail", items, { buffer = buf })
end

return M
