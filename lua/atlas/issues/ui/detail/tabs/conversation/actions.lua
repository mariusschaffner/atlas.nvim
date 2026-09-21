local M = {}

local picker = require("atlas.ui.picker")
local notify = require("atlas.core.notify")
local state = require("atlas.issues.ui.detail.tabs.conversation.state")
local detail = require("atlas.issues.ui.detail.state")

---@return IssuesCommentsCapability|nil
local function get_comments()
	local provider = detail.provider
	return provider and provider.capabilities.comments or nil
end

---@param issue Issue
---@return AtlasMarkdownCompletionProvider|nil
local function get_completion(issue)
	local comments = get_comments()
	if comments and comments.comment_completion then
		return comments.comment_completion({
			issue = issue,
			details = detail.current_details,
			comments = state.comments(),
		})
	end
	return nil
end
M.get_completion = get_completion

---@param issue Issue
---@param amount integer
local function adjust_comment_count(issue, amount)
	if issue.comment_count == nil then
		return
	end
	issue.comment_count = math.max(0, (tonumber(issue.comment_count) or 0) + amount)
	local on_update = detail.on_update
	if on_update then
		on_update(issue, nil)
	end
end

--- Whether `comment` was authored by the currently signed-in user, used to
--- gate the Edit/Delete bottom-border hints to your own comments. Compares
--- `id` first, falling back to `account_id` -- the dashboard-level
--- `current_user` (populated by `fetch_current_user()` on every dashboard
--- load, so it's reliably available by the time a detail view is open).
---@param comment IssueComment|nil
---@return boolean
function M.is_own_comment(comment)
	local user = require("atlas.issues.state").current_user
	local author = comment and comment.author
	if user == nil or author == nil then
		return false
	end
	if user.id ~= nil and author.id ~= nil then
		return user.id == author.id
	end
	if user.account_id ~= nil and user.account_id ~= "" and author.account_id ~= nil and author.account_id ~= "" then
		return user.account_id == author.account_id
	end
	return false
end

---@param issue Issue
---@param text string
---@param done fun(ok: boolean, err: string|nil)
function M.add(issue, text, done)
	if not text or vim.trim(text) == "" then
		done(false, "Comment is empty")
		return
	end
	local comments = get_comments()
	if not comments or not comments.add_comment then
		done(false, "Not supported")
		return
	end
	notify.loading("Adding comment...")
	comments.add_comment(issue, text, function(created, err)
		if not state.is_current(issue) then
			done(true)
			return
		end
		if err then
			notify.error("Add comment failed: " .. err)
			done(false, err)
			return
		end
		if created then
			state.upsert_comment(created)
			adjust_comment_count(issue, 1)
			state.active_id = tostring(created.id)
		end
		notify.success("Comment added", { timeout = 1200 })
		done(true)
	end)
end

---@param issue Issue
---@param parent IssueComment
---@param text string
---@param done fun(ok: boolean, err: string|nil)
function M.reply(issue, parent, text, done)
	if not text or vim.trim(text) == "" then
		done(false, "Reply is empty")
		return
	end
	local comments = get_comments()
	if not comments or not comments.add_comment then
		done(false, "Not supported")
		return
	end
	notify.loading("Sending reply...")
	local function on_result(created, err)
		if not state.is_current(issue) then
			done(true)
			return
		end
		if err then
			notify.error("Reply failed: " .. err)
			done(false, err)
			return
		end
		if created then
			state.upsert_comment(created)
			adjust_comment_count(issue, 1)
			state.active_id = tostring(created.id)
		end
		notify.success("Reply added", { timeout = 1200 })
		done(true)
	end
	if comments.reply_comment then
		comments.reply_comment(issue, parent, text, on_result)
	else
		comments.add_comment(issue, text, on_result)
	end
end

---@param issue Issue
---@param comment IssueComment
---@param text string
---@param done fun(ok: boolean, err: string|nil)
function M.edit(issue, comment, text, done)
	if not text or vim.trim(text) == "" then
		done(false, "Comment is empty")
		return
	end
	local comments = get_comments()
	if not comments or not comments.edit_comment then
		done(false, "Not supported")
		return
	end
	notify.loading("Editing comment...")
	comments.edit_comment(issue, comment, text, function(updated, err)
		if not state.is_current(issue) then
			done(true)
			return
		end
		if err then
			notify.error("Edit failed: " .. err)
			done(false, err)
			return
		end
		if updated then
			updated.parent_id = updated.parent_id or comment.parent_id
			updated._raw = vim.tbl_extend("keep", updated._raw or {}, comment._raw or {})
			state.upsert_comment(updated)
		else
			comment.body = text
		end
		notify.success("Comment updated", { timeout = 1200 })
		done(true)
	end)
end

---@param issue Issue
---@param comment IssueComment
---@param refresh fun()
function M.delete(issue, comment, refresh)
	local comments = get_comments()
	if not comments or not comments.delete_comment then
		return
	end

	vim.ui.input({ prompt = "Delete comment? [y/N]: " }, function(input)
		local confirmed = input and vim.trim(input):lower()
		if confirmed ~= "y" and confirmed ~= "yes" then
			return
		end
		notify.loading("Deleting comment...")
		comments.delete_comment(issue, comment, function(_, err)
			if not state.is_current(issue) then
				return
			end
			if err then
				notify.error("Delete failed: " .. err)
				return
			end
			state.remove_comment(comment)
			adjust_comment_count(issue, -1)
			notify.success("Comment deleted", { timeout = 1200 })
			refresh()
		end)
	end)
end

---@param issue Issue
---@param comment IssueComment
---@param refresh fun()
function M.react(issue, comment, refresh)
	local comments = get_comments()
	if not comments or not comments.add_reaction then
		notify.warn("Provider does not support reactions")
		return
	end
	local options = comments.reaction_options or {}
	if #options == 0 then
		notify.warn("No reactions available for this provider")
		return
	end
	local choices = {}
	for _, opt in ipairs(options) do
		table.insert(choices, {
			key = opt.key,
			label = string.format("%s  %s", opt.emoji or opt.key, opt.label or opt.key),
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
			comments.add_reaction(issue, { kind = "comment", entity = comment }, selected.key, function(ok, err)
				if not state.is_current(issue) then
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

return M
