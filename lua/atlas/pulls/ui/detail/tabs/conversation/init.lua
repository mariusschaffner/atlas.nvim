-- The MR detail view's Activity tab (DESIGN-merge-request-view.md §6): the
-- issue view's Activity timeline (`atlas.ui.detail_tabs.activity`), hosted by
-- the MR detail state. The pulls comments capability speaks PullsComment /
-- PullsConversationItem; the adapter below maps those onto the issue-shaped
-- comments/activity entries the shared tab renders, and back for writes.
local detail = require("atlas.pulls.ui.detail.state")
local presentation = require("atlas.pulls.ui.presentation")

---@param author PullsAuthor|PullsUser|nil
---@return AtlasActivityUser|nil
local function to_user(author)
	if author == nil then
		return nil
	end
	local name = tostring(author.name or "")
	return {
		id = author.id ~= nil and tostring(author.id) or nil,
		account_id = author.username,
		display_name = name ~= "" and name or presentation.user_handle(author),
	}
end

---@param comment PullsComment
---@return string|nil
local function context_of(comment)
	local inline = comment.inline
	if inline and inline.path then
		local line = inline.to or inline.from
		return "⎇ " .. inline.path .. (line and (":" .. tostring(line)) or "")
	end
	if comment.file and comment.file.path then
		return "⎇ " .. comment.file.path
	end
	return nil
end

---@return PullsCommentsCapability|nil
local function pulls_comments()
	return detail.provider and detail.provider.capabilities.comments or nil
end

---@param comment PullsComment
---@return AtlasActivityComment
local function to_comment(comment)
	local is_root = comment.parent_id == nil
	local capability = pulls_comments()
	return {
		id = tostring(comment.id),
		author = to_user(comment.author),
		body = comment.content_raw,
		created = comment.created_on,
		parent_id = comment.parent_id ~= nil and tostring(comment.parent_id) or nil,
		deleted = comment.state == "DELETED",
		-- Only real threads: a plain comment (e.g. the one posted with an
		-- approval) isn't resolvable. Providers that don't say fall back to
		-- "diff threads are, general comments aren't".
		resolvable = is_root
				and capability ~= nil
				and capability.set_thread_resolved ~= nil
				and (comment.resolvable == true or (comment.resolvable == nil and (comment.inline or comment.file) ~= nil))
			or nil,
		resolved = is_root and comment.state == "RESOLVED" or nil,
		resolved_by = to_user(comment.resolved_by),
		context = is_root and context_of(comment) or nil,
		_source = comment,
	}
end

-- System notes the GitLab mapper leaves without text.
local ACTIVITY_LABELS = {
	approval = "approved this merge request",
	changes_requested = "requested changes",
	unapproval = "unapproved this merge request",
}

local REVIEW_LABELS = {
	approved = "approved this merge request",
	changes_requested = "requested changes",
	commented = "reviewed",
	dismissed = "dismissed a review",
	reviewed = "reviewed",
	unapproved = "unapproved this merge request",
}

---@param items PullsConversationItem[]
---@return IssueConversationItem[]
local function to_items(items)
	local out = {}
	for _, item in ipairs(items or {}) do
		if item.kind == "comment" then
			---@type PullsComment
			local comment = item.entity
			if not comment.is_task then
				table.insert(out, { id = item.id, kind = "comment", created_at = item.created_on, entity = to_comment(comment) })
			end
		elseif item.kind == "review" then
			---@type PullsReviewHistoryEntry
			local review = item.entity
			table.insert(out, {
				id = item.id,
				kind = "activity",
				created_at = item.created_on,
				entity = {
					kind = "review",
					actor = to_user(review.author),
					date = review.submitted_on,
					label = REVIEW_LABELS[review.state] or review.state,
				},
			})
		else
			---@type PullsActivityEntry
			local activity = item.entity
			table.insert(out, {
				id = item.id,
				kind = "activity",
				created_at = item.created_on,
				entity = {
					kind = activity.kind,
					actor = to_user(activity.actor),
					date = activity.date,
					label = activity.label or ACTIVITY_LABELS[activity.kind],
					body = activity.body,
					deleted = activity.deleted,
				},
			})
		end
	end
	return out
end

---@param on_done fun(comment: IssueComment|nil, err: string|nil)
---@return fun(comment: PullsComment|nil, err: string|nil)
local function mapped(on_done)
	return function(comment, err)
		on_done(comment and to_comment(comment) or nil, err)
	end
end

--- The pulls comments capability, in the shape the shared Activity tab
--- calls (`AtlasActivityComments`).
---@return AtlasActivityComments|nil
local function comments()
	local capability = pulls_comments()
	if capability == nil then
		return nil
	end
	---@type AtlasActivityComments
	local adapted = {}
	if capability.fetch_conversation then
		adapted.fetch_conversation = function(pr, opts, on_done)
			return capability.fetch_conversation(pr, opts, function(items, err)
				on_done(items and to_items(items) or nil, err)
			end)
		end
	end
	if capability.add_comment then
		adapted.add_comment = function(pr, text, on_done)
			return capability.add_comment(pr, text, nil, mapped(on_done))
		end
		adapted.reply_comment = function(pr, parent, text, on_done)
			local source = parent._source
			return capability.add_comment(pr, text, {
				parent = source,
				pending = source and source.state == "PENDING" or nil,
			}, mapped(on_done))
		end
	end
	if capability.edit_comment then
		adapted.edit_comment = function(pr, comment, text, on_done)
			local desired = vim.tbl_extend("force", {}, comment._source or {}, { content_raw = text })
			return capability.edit_comment(pr, desired, mapped(on_done))
		end
	end
	if capability.delete_comment then
		adapted.delete_comment = function(pr, comment, on_done)
			return capability.delete_comment(pr, comment._source, on_done)
		end
	end
	if capability.set_thread_resolved then
		adapted.set_thread_resolved = function(pr, root, resolved, on_done)
			return capability.set_thread_resolved(pr, root._source, resolved, on_done)
		end
	end
	return adapted
end

---@param pr PullRequest
---@return string
local function pr_key(pr)
	return string.format("%s!%s", tostring(pr.repo_full_name or ""), tostring(pr.id or ""))
end

---@type AtlasActivityHost
local host = {
	name = "PullsConversation",
	add_action_id = "ui.comments.add",
	expand_action_id = "issues.expand_activity",
	closed_message = "PR is not open",
	subject = function()
		return detail.current_pr
	end,
	subject_key = pr_key,
	subject_label = function(pr)
		return "!" .. tostring(pr.id or "")
	end,
	is_open = function(pr)
		return presentation.is_open_or_draft(pr)
	end,
	win = function()
		return detail.win
	end,
	buf = function()
		return detail.buf
	end,
	line_map = function()
		return detail.line_map or {}
	end,
	is_active = function()
		return detail.current_tab == "conversation"
	end,
	comments = comments,
	current_user = function()
		return to_user(require("atlas.pulls.state").current_user)
	end,
	completion = function(pr, activity_comments)
		local capability = pulls_comments()
		if not capability or not capability.comment_completion then
			return nil
		end
		local sources = {}
		for _, comment in ipairs(activity_comments) do
			table.insert(sources, comment._source)
		end
		local reviewers = detail.reviewers
		return capability.comment_completion({
			pr = pr,
			details = detail.current_details,
			comments = sources,
			tasks = {},
			reviewers = type(reviewers) == "table" and reviewers or nil,
			conversation = sources,
		})
	end,
	on_comment_count = function(pr, delta)
		pr.comments_count = math.max(0, (tonumber(pr.comments_count) or 0) + delta)
		if detail.on_update then
			detail.on_update(pr, nil)
		end
	end,
	person_hl = function(name)
		return presentation.author_hl(name)
	end,
}

host.fetch_current_user = function(on_done)
	local core = detail.provider and detail.provider.capabilities.core
	if not core or not core.fetch_user then
		on_done(nil)
		return nil
	end
	return core.fetch_user(function(user)
		local pulls_state = require("atlas.pulls.state")
		if user ~= nil and pulls_state.current_user == nil then
			pulls_state.current_user = user
		end
		on_done(to_user(user))
	end)
end

local M = require("atlas.ui.detail_tabs.activity").new(host)

return M
