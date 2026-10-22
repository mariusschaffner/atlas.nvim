-- The issue detail view's Activity tab: the shared `atlas.ui.detail_tabs.activity`
-- timeline, hosted by the issue detail state and the issue provider's comments.
local detail = require("atlas.issues.ui.detail.state")
local presentation = require("atlas.issues.ui.presentation")

---@type AtlasActivityHost
local host = {
	name = "IssuesConversation",
	add_action_id = "issues.add_comment",
	expand_action_id = "issues.expand_activity",
	closed_message = "Issue is closed",
	subject = function()
		return detail.current_issue
	end,
	subject_key = function(issue)
		return tostring(issue.key or "")
	end,
	subject_label = function(issue)
		return tostring(issue.key or "")
	end,
	is_open = function(issue)
		return presentation.is_open(issue)
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
	comments = function()
		return detail.provider and detail.provider.capabilities.comments or nil
	end,
	current_user = function()
		return require("atlas.issues.state").current_user
	end,
	completion = function(issue, comments)
		local capability = detail.provider and detail.provider.capabilities.comments
		if capability and capability.comment_completion then
			return capability.comment_completion({
				issue = issue,
				details = detail.current_details,
				comments = comments,
			})
		end
		return nil
	end,
	on_comment_count = function(issue, delta)
		if issue.comment_count == nil then
			return
		end
		issue.comment_count = math.max(0, (tonumber(issue.comment_count) or 0) + delta)
		if detail.on_update then
			detail.on_update(issue, nil)
		end
	end,
	person_hl = function(name)
		return presentation.person_hl(name)
	end,
}

host.fetch_current_user = function(on_done)
	local core = detail.provider and detail.provider.capabilities.core
	if not core or not core.fetch_user then
		on_done(nil)
		return nil
	end
	return core.fetch_user(function(user)
		local issues_state = require("atlas.issues.state")
		if user ~= nil and issues_state.current_user == nil then
			issues_state.current_user = user
		end
		on_done(user)
	end)
end

local M = require("atlas.ui.detail_tabs.activity").new(host)

return M
