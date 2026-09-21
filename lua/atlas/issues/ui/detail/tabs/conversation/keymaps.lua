local M = {}

local help = require("atlas.ui.popups.help")
local resolver = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local comment_threads = require("atlas.issues.ui.components.comment_threads")
local inline_field_edit = require("atlas.ui.inline_field_edit")
local actions = require("atlas.issues.ui.detail.tabs.conversation.actions")
local detail = require("atlas.issues.ui.detail.state")
local state = require("atlas.issues.ui.detail.tabs.conversation.state")

local ACTIONS = {
	"issues.add_comment",
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
	local region = id and state.regions["comment:" .. id]
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
	-- returns -- refresh again so it picks that up (the refresh() the caller
	-- already did happened before the overlay existed).
	refresh()
end

---@param refresh fun()
local function start_add(buf, refresh)
	local issue = detail.current_issue
	local comments = detail.provider and detail.provider.capabilities.comments
	if not issue or not comments or not comments.add_comment then
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
			actions.add(issue, text, done)
		end,
		on_done = function()
			state.composing = nil
			refresh_and_follow(refresh)
		end,
	})
end

---@param buf integer
---@param refresh fun()
local function start_reply(buf, refresh)
	local issue = detail.current_issue
	local comment = state.active_comment()
	local comments = detail.provider and detail.provider.capabilities.comments
	if not issue or not comment or not comments or not comments.add_comment then
		return
	end

	local thread_root = comment
	for _, node in ipairs(comment_threads.group_comments(state.comments())) do
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

	local completion = actions.get_completion(issue)
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
	-- The composing box always renders at the end of the thread (see
	-- render_thread_node), which can be well past the reply being answered
	-- and thus outside the window's current viewport. `relative="win"`
	-- floats use absolute buffer coordinates and Neovim does not auto-scroll
	-- the host window to keep them visible, so without this the overlay
	-- could open off-screen while the visible cursor stays on the comment
	-- that was replied to.
	move_cursor_to(region)
	start_inline_edit(buf, refresh, {
		region = region,
		seed_text = seed_text,
		on_save = function(text, done)
			actions.reply(issue, thread_root, text, done)
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
	local issue = detail.current_issue
	local comment = state.active_comment()
	local comments = detail.provider and detail.provider.capabilities.comments
	if not issue or not comment or not comments or not comments.edit_comment then
		return
	end
	if not actions.is_own_comment(comment) then
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
		seed_text = tostring(comment.body or ""),
		on_save = function(text, done)
			actions.edit(issue, comment, text, done)
		end,
		on_done = function()
			state.editing_id = nil
			refresh_and_follow(refresh)
		end,
	})
end

---@param refresh fun()
local function do_delete(refresh)
	local issue = detail.current_issue
	local comment = state.active_comment()
	if not issue or not comment then
		return
	end
	if not actions.is_own_comment(comment) then
		return
	end
	actions.delete(issue, comment, refresh)
end

---@param refresh fun()
local function do_react(refresh)
	local issue = detail.current_issue
	local comment = state.active_comment()
	if not issue or not comment then
		return
	end
	actions.react(issue, comment, refresh)
end

---@param refresh fun()
local function toggle_fold(refresh)
	local comment = state.active_comment()
	if not comment then
		return
	end
	if state.toggle_comment(comment) then
		refresh()
		return
	end
	for _, node in ipairs(comment_threads.group_comments(state.comments())) do
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
	local comments = provider and provider.capabilities.comments
	local items = {}

	if comments and comments.add_comment then
		utils.insert_if(
			items,
			resolver.item("issues.add_comment", {
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
	end
	if comments and comments.edit_comment then
		utils.insert_if(
			items,
			resolver.item("ui.comments.edit", {
				desc = "Edit comment",
				hint = false,
				opts = { nowait = true, silent = true },
				callback = function()
					start_edit(buf, refresh)
				end,
			})
		)
	end
	if comments and comments.delete_comment then
		utils.insert_if(
			items,
			resolver.item("ui.delete", {
				desc = "Delete comment",
				hint = false,
				opts = { nowait = true, silent = true },
				callback = function()
					do_delete(refresh)
				end,
			})
		)
	end
	if comments and comments.add_reaction and #(comments.reaction_options or {}) > 0 then
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
	end

	utils.insert_if(
		items,
		resolver.item("ui.next_item", {
			desc = "Next comment",
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
			desc = "Previous comment",
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
		resolver.item("ui.toggle_fold", {
			desc = "Expand / collapse comment or thread",
			hint = false,
			opts = { nowait = true, silent = true },
			callback = function()
				toggle_fold(refresh)
			end,
		})
	)
	utils.insert_if(
		items,
		resolver.item("ui.toggle_all_folds", {
			desc = "Expand / collapse all threads",
			hint = false,
			opts = { nowait = true, silent = true },
			callback = function()
				if state.toggle_all_threads(comment_threads.group_comments(state.comments())) then
					refresh()
				end
			end,
		})
	)

	help.register("Detail", items, { index = 212, buffer = buf })
end

---@param buf integer
function M.teardown(buf)
	local items = {}
	for _, action_id in ipairs(ACTIONS) do
		utils.insert_if(items, resolver.item(action_id, {}))
	end
	utils.insert_if(items, resolver.item("ui.toggle_fold", {}))
	utils.insert_if(items, resolver.item("ui.toggle_all_folds", {}))
	help.remove("Detail", items, { buffer = buf })
end

return M
