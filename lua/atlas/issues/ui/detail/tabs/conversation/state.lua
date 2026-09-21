local request_scope = require("atlas.core.requests")
local utils = require("atlas.ui.shared.utils")

local MAX_COMMENT_LINES = 8

---@class IssuesConversationComposing
---@field kind "add"|"reply"
---@field parent IssueComment|nil
---@field seed_text string

---@class IssuesConversationNavigableEntry
---@field id string
---@field comment IssueComment

---@class IssuesConversationState
---@field items IssueConversationItem[]|"loading"|nil
---@field error string|nil
---@field collapsed table<string, boolean>
---@field expanded_comments table<string, boolean>
---@field expanded_runs table<string, boolean>
---@field requests AtlasRequestScope
---@field current_issue Issue|nil
---@field active_id string|nil Currently active/selected comment id (not cursor-bound).
---@field editing_id string|nil Comment id currently being inline-edited, if any.
---@field composing IssuesConversationComposing|nil In-progress inline add/reply, if any.
---@field regions table<string, AtlasFieldBoxRegion> Comment box interior regions from the last render, keyed "comment:"..id (or "composing" for the in-progress add/reply box).
---@field navigable IssuesConversationNavigableEntry[] Flattened, in-order list of every visible comment from the last render.
local M = {
	items = nil,
	error = nil,
	collapsed = {},
	expanded_comments = {},
	expanded_runs = {},
	requests = request_scope.new(),
	current_issue = nil,
	active_id = nil,
	editing_id = nil,
	composing = nil,
	regions = {},
	navigable = {},
}

function M.reset()
	M.current_issue = nil
	M.requests.cancel()
	M.requests = request_scope.new()
	M.items = nil
	M.error = nil
	M.collapsed = {}
	M.expanded_comments = {}
	M.expanded_runs = {}
	M.active_id = nil
	M.editing_id = nil
	M.composing = nil
	M.regions = {}
	M.navigable = {}
end

---@param issue Issue
function M.activate(issue)
	M.reset()
	M.current_issue = issue
end

function M.deactivate()
	M.current_issue = nil
	M.requests.cancel()
	M.requests = request_scope.new()
end

---@return IssueComment|nil
function M.active_comment()
	for _, entry in ipairs(M.navigable) do
		if entry.id == M.active_id then
			return entry.comment
		end
	end
	return nil
end

--- Rebuilds the navigable list from the last render, and defaults `active_id`
--- to the first entry whenever it's unset or no longer present (first render
--- after data loads, or after the active comment was deleted).
---@param navigable IssuesConversationNavigableEntry[]
function M.set_navigable(navigable)
	M.navigable = navigable
	if M.active_id ~= nil then
		for _, entry in ipairs(navigable) do
			if entry.id == M.active_id then
				return
			end
		end
	end
	M.active_id = navigable[1] and navigable[1].id or nil
end

--- Moves the active comment by `step` (1 = next, -1 = previous), clamped at
--- the ends of the navigable list (no wraparound, matching plain j/k).
---@param step 1|-1
function M.move_active(step)
	if #M.navigable == 0 then
		return
	end
	local index = 1
	for i, entry in ipairs(M.navigable) do
		if entry.id == M.active_id then
			index = i
			break
		end
	end
	index = math.max(1, math.min(#M.navigable, index + step))
	M.active_id = M.navigable[index].id
end

---@param issue Issue
---@return boolean
function M.is_current(issue)
	return M.current_issue ~= nil and tostring(M.current_issue.key or "") == tostring(issue.key or "")
end

---@param run_id any
function M.toggle_run(run_id)
	local key = tostring(run_id)
	M.expanded_runs[key] = not M.expanded_runs[key]
end

---@param run_id any
---@return boolean
function M.is_run_expanded(run_id)
	return M.expanded_runs[tostring(run_id)] == true
end

---@return boolean
function M.is_loading()
	return M.items == "loading"
end

---@return IssueComment[]
function M.comments()
	local result = {}
	if type(M.items) ~= "table" then
		return result
	end
	for _, item in ipairs(M.items) do
		if item.kind == "comment" then
			---@type IssueComment
			local comment = item.entity
			table.insert(result, comment)
		end
	end
	return result
end

---@param comment IssueComment
function M.upsert_comment(comment)
	if type(M.items) ~= "table" then
		return
	end
	local id = "comment:" .. tostring(comment.id)
	local item = { id = id, kind = "comment", created_at = comment.created or "", entity = comment }
	for index, current in ipairs(M.items) do
		if current.id == id then
			M.items[index] = item
			return
		end
	end
	table.insert(M.items, item)
end

---@param comment IssueComment
function M.remove_comment(comment)
	if type(M.items) ~= "table" then
		return
	end
	for _, item in ipairs(M.items) do
		if item.kind == "comment" then
			---@type IssueComment
			local current = item.entity
			if tostring(current.parent_id or "") == tostring(comment.id) then
				comment.body = nil
				comment.deleted = true
				return
			end
		end
	end
	local id = "comment:" .. tostring(comment.id)
	for index = #M.items, 1, -1 do
		if M.items[index].id == id then
			table.remove(M.items, index)
			return
		end
	end
end

---@param comment IssueComment
---@return boolean
local function is_comment_long(comment)
	if comment.deleted then
		return false
	end
	local lines = utils.sanitize_lines(utils.strip_markup(comment.body or ""))
	while #lines > 0 and vim.trim(lines[#lines]) == "" do
		table.remove(lines)
	end
	return #lines > MAX_COMMENT_LINES
end

---@param comment IssueComment
---@return integer|nil
function M.comment_max_lines(comment)
	if is_comment_long(comment) and M.expanded_comments[tostring(comment.id)] ~= true then
		return MAX_COMMENT_LINES
	end
end

---@param comment IssueComment
---@return boolean
function M.toggle_comment(comment)
	if not is_comment_long(comment) then
		return false
	end
	local key = tostring(comment.id)
	M.expanded_comments[key] = not M.expanded_comments[key]
	return true
end

---@param root_id any
---@return boolean
function M.is_collapsed(root_id)
	return M.collapsed[tostring(root_id)] == true
end

---@param root_id any
function M.toggle(root_id)
	local key = tostring(root_id)
	M.collapsed[key] = not M.collapsed[key]
end

---@param threads IssuesCommentThreadNode[]
---@return boolean
function M.toggle_all_threads(threads)
	local roots = {}
	local expand = false
	for _, thread in ipairs(threads) do
		if #thread.children > 0 then
			table.insert(roots, thread.comment)
			if M.is_collapsed(thread.comment.id) then
				expand = true
			end
		end
	end
	for _, root in ipairs(roots) do
		M.collapsed[tostring(root.id)] = not expand
	end
	return #roots > 0
end

return M
