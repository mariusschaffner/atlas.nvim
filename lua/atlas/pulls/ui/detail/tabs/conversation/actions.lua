local M = {}

local picker = require("atlas.ui.picker")
local notify = require("atlas.core.notify")
local review = require("atlas.pulls.actions.review")
local state = require("atlas.pulls.ui.detail.tabs.conversation.state")
local detail = require("atlas.pulls.ui.detail.state")

---@param pr PullRequest
---@return AtlasMarkdownCompletionProvider|nil
local function author_completion(pr)
	local provider = detail.provider
	local comments_capability = provider and provider.capabilities.comments
	if not comments_capability or not comments_capability.comment_completion then
		return nil
	end
	local reviewers = detail.reviewers
	local conversation = state.comments(false)
	return comments_capability.comment_completion({
		pr = pr,
		details = detail.current_details,
		comments = conversation,
		tasks = state.comments(true),
		reviewers = type(reviewers) == "table" and reviewers or nil,
		conversation = conversation,
	})
end

---@param pr PullRequest
---@return AtlasMarkdownCompletionProvider|nil
function M.get_completion(pr)
	return author_completion(pr)
end

---@param pr PullRequest
---@param comment PullsComment|nil
---@return AtlasReviewActionContext|nil
local function action_context(pr, comment)
	local provider = detail.provider
	if not provider then
		return nil
	end
	local items = state.comments(comment and comment.is_task == true or false)
	return {
		provider = provider,
		pr = pr,
		items = items,
		completion = author_completion(pr),
		upsert_comment = function(created)
			if state.is_current(pr) then
				state.upsert_comment(created)
			end
		end,
		remove_comment = function(removed)
			if state.is_current(pr) then
				state.remove_comment(removed)
			end
		end,
		notify = function(level, message, duration)
			if state.is_current(pr) then
				notify.show(level, message, { timeout = duration })
			end
		end,
	}
end

---@param pr PullRequest
---@param on_update (fun(pr: PullRequest, result: PullsActionResult|nil))|nil
---@param result PullsActionResult
local function complete_action(pr, on_update, result)
	if on_update then
		on_update(pr, result)
	else
		require("atlas.pulls.ui.detail").refresh()
	end
end

---@param pr PullRequest
---@param refresh fun()
---@return fun(result: PullsActionResult|nil, err: string|nil)
local function on_done(pr, refresh)
	local on_update = detail.on_update
	return function(result, err)
		if not result or err then
			return
		end
		if result.changed_pr then
			complete_action(pr, on_update, result)
		elseif state.is_current(pr) then
			refresh()
		end
	end
end

---@param comment PullsComment
---@return string
local function comment_key(comment)
	return (comment.is_task and "task:" or "comment:") .. tostring(comment.id)
end

---@param comment PullsComment
---@return PullsConversationItem|nil
local function find_conversation_item(comment)
	if type(state.items) ~= "table" then
		return nil
	end
	local id = comment_key(comment)
	for _, item in ipairs(state.items) do
		if item.id == id then
			return item
		end
	end
	return nil
end

---@param comment PullsComment
---@return boolean
function M.is_own_comment(comment)
	local current_user = require("atlas.pulls.state").current_user
	if not current_user or not comment or not comment.author then
		return false
	end
	return tostring(current_user.id) == tostring(comment.author.id)
end

-- Inline (no-popup) text flow for regular comments: add / reply / edit.
-- Tasks and reviews keep going through `atlas.pulls.actions.review`'s
-- existing popup-based editors below -- they're out of scope for the inline
-- box redesign (read-mostly per this session's design decision).

---@param pr PullRequest
---@param text string
---@param done fun(ok: boolean, err: string|nil)
function M.add(pr, text, done)
	if vim.trim(text) == "" then
		done(false, "Empty comment")
		return
	end
	local context = action_context(pr, nil)
	if not context then
		done(false, "No context")
		return
	end
	local comments = context.provider.capabilities.comments
	local add = comments and comments.add_comment
	if not add then
		notify.error("Provider does not support comments")
		done(false, "Provider does not support comments")
		return
	end
	notify.loading("Adding comment...")
	add(pr, text, {}, function(created, err)
		if err then
			notify.error("Add comment failed: " .. tostring(err))
			done(false, err)
			return
		end
		if created then
			context.upsert_comment(created)
		end
		notify.success("Comment added", { timeout = 1200 })
		done(true, nil)
	end)
end

---@param pr PullRequest
---@param parent PullsComment
---@param text string
---@param done fun(ok: boolean, err: string|nil)
function M.reply(pr, parent, text, done)
	if vim.trim(text) == "" then
		done(false, "Empty comment")
		return
	end
	if parent.is_task then
		done(false, "Tasks do not support replies")
		return
	end
	local context = action_context(pr, parent)
	if not context then
		done(false, "No context")
		return
	end
	local comments = context.provider.capabilities.comments
	local add = comments and comments.add_comment
	if not add then
		notify.error("Provider does not support comments")
		done(false, "Provider does not support comments")
		return
	end
	local pending = parent.state == "PENDING"
	notify.loading("Sending reply...")
	add(pr, text, { parent = parent, pending = pending }, function(created, err)
		if err then
			notify.error("Reply failed: " .. tostring(err))
			done(false, err)
			return
		end
		if created then
			context.upsert_comment(created)
		end
		notify.success("Reply added", { timeout = 1200 })
		done(true, nil)
	end)
end

---@param pr PullRequest
---@param comment PullsComment
---@param text string
---@param done fun(ok: boolean, err: string|nil)
function M.edit_comment(pr, comment, text, done)
	if vim.trim(text) == "" then
		done(false, "Empty comment")
		return
	end
	local context = action_context(pr, comment)
	if not context then
		done(false, "No context")
		return
	end
	local comments = context.provider.capabilities.comments
	local update = comments and comments.edit_comment
	if not update then
		notify.error("Provider does not support editing this item")
		done(false, "Provider does not support editing this item")
		return
	end
	notify.loading("Editing comment...")
	local desired = vim.tbl_extend("force", {}, comment, { content_raw = text })
	update(pr, desired, function(updated, err)
		if err then
			notify.error("Edit failed: " .. tostring(err))
			done(false, err)
			return
		end
		if updated then
			context.upsert_comment(updated)
		end
		notify.success("Comment updated", { timeout = 1200 })
		done(true, nil)
	end)
end

-- Task / review editing: kept exactly as before (popup-based, via
-- atlas.pulls.actions.review), just dispatched off the active entry instead
-- of the cursor line.

---@param pr PullRequest
---@param comment PullsComment
---@param refresh fun()
function M.edit_task(pr, comment, refresh)
	local context = action_context(pr, comment)
	if context then
		review.edit_comment(context, comment, on_done(pr, refresh))
	end
end

---@param pr PullRequest
---@param entry PullsReviewHistoryEntry
---@param refresh fun()
function M.edit_review(pr, entry, refresh)
	local context = action_context(pr, nil)
	if context then
		review.edit_review(context, entry, on_done(pr, refresh))
	end
end

---@param pr PullRequest
---@param comment PullsComment
---@param refresh fun()
function M.delete(pr, comment, refresh)
	local context = action_context(pr, comment)
	if context then
		review.delete_comment(context, comment, on_done(pr, refresh))
	end
end

---@param pr PullRequest
---@param comment PullsComment
---@param refresh fun()
function M.react(pr, comment, refresh)
	local provider = detail.provider
	local comments = provider and provider.capabilities.comments
	if not comments or not comments.add_reaction then
		return
	end
	local options = comments.reaction_options or {}
	if #options == 0 then
		notify.warn("No reactions available for this provider")
		return
	end
	local item = find_conversation_item(comment)
	if not item then
		return
	end
	local choices = {}
	for _, option in ipairs(options) do
		table.insert(choices, {
			key = option.key,
			label = string.format("%s  %s", option.emoji or option.key, option.label or option.key),
		})
	end
	picker.select({
		title = "Add reaction",
		items = choices,
		format_item = function(choice)
			return choice.label
		end,
		on_select = function(selected)
			if selected == nil then
				return
			end
			notify.loading("Adding reaction...")
			comments.add_reaction(pr, item, selected.key, function(ok, err)
				if not state.is_current(pr) then
					return
				end
				if err then
					notify.error("Reaction failed: " .. tostring(err))
					return
				end
				if ok then
					comment.reactions = comment.reactions or {}
					comment.reactions[selected.key] = (tonumber(comment.reactions[selected.key]) or 0) + 1
				end
				notify.success("Reaction added", { timeout = 1200 })
				refresh()
			end)
		end,
	})
end

---@param pr PullRequest
---@param comment PullsComment
---@param refresh fun()
function M.toggle_task(pr, comment, refresh)
	local context = action_context(pr, comment)
	if context then
		review.toggle_task(context, comment, on_done(pr, refresh))
	end
end

return M
