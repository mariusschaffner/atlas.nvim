local request_scope = require("atlas.core.requests")
local utils = require("atlas.ui.shared.utils")

local MAX_COMMENT_LINES = 8

---@class PullsConversationComposing
---@field kind "add"|"reply"
---@field parent PullsComment|nil
---@field seed_text string

---@class PullsConversationNavigableEntry
---@field id string
---@field kind "comment"|"task"|"review"
---@field entity PullsComment|PullsReviewHistoryEntry

---@class PullsConversationState
---@field items PullsConversationItem[]|"loading"|nil
---@field error string|nil
---@field collapsed table<string, boolean>
---@field expanded_comments table<string, boolean>
---@field expanded_runs table<string, boolean>
---@field requests AtlasRequestScope
---@field current_pr PullRequest|nil
---@field active_id string|nil Currently active/selected entry id (not cursor-bound).
---@field editing_id string|nil Comment id currently being inline-edited, if any.
---@field composing PullsConversationComposing|nil In-progress inline add/reply, if any.
---@field regions table<string, AtlasFieldBoxRegion> Interior regions from the last render, keyed by navigable id (or "composing").
---@field navigable PullsConversationNavigableEntry[] Flattened, in-order list of every visible entry from the last render.
local M = {
	items = nil,
	error = nil,
	collapsed = {},
	expanded_comments = {},
	expanded_runs = {},
	requests = request_scope.new(),
	current_pr = nil,
	active_id = nil,
	editing_id = nil,
	composing = nil,
	regions = {},
	navigable = {},
}

function M.reset()
	M.current_pr = nil
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

---@param pr PullRequest
function M.activate(pr)
	M.reset()
	M.current_pr = pr
end

function M.deactivate()
	M.current_pr = nil
	M.requests.cancel()
	M.requests = request_scope.new()
end

---@return PullsConversationNavigableEntry|nil
function M.active_entry()
	for _, entry in ipairs(M.navigable) do
		if entry.id == M.active_id then
			return entry
		end
	end
	return nil
end

--- Rebuilds the navigable list from the last render, and defaults `active_id`
--- to the first entry whenever it's unset or no longer present (first render
--- after data loads, or after the active entry was deleted).
---@param navigable PullsConversationNavigableEntry[]
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

--- Moves the active entry by `step` (1 = next, -1 = previous), clamped at
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

---@param pr PullRequest
---@return boolean
function M.is_current(pr)
	return M.current_pr ~= nil
		and tostring(M.current_pr.id or "") == tostring(pr.id or "")
		and tostring(M.current_pr.repo_full_name or "") == tostring(pr.repo_full_name or "")
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

---@param is_task boolean
---@return PullsComment[]
function M.comments(is_task)
	local result = {}
	if type(M.items) ~= "table" then
		return result
	end
	for _, item in ipairs(M.items) do
		if item.kind == "comment" then
			---@type PullsComment
			local comment = item.entity
			if (comment.is_task == true) == is_task then
				table.insert(result, comment)
			end
		end
	end
	return result
end

---@param comment PullsComment
function M.upsert_comment(comment)
	if type(M.items) ~= "table" then
		return
	end
	local id = (comment.is_task and "task:" or "comment:") .. tostring(comment.id)
	for index, item in ipairs(M.items) do
		if item.id == id then
			M.items[index] = { id = id, kind = "comment", created_on = comment.created_on or "", entity = comment }
			return
		end
	end
	table.insert(M.items, { id = id, kind = "comment", created_on = comment.created_on or "", entity = comment })
end

---@param comment PullsComment
function M.remove_comment(comment)
	if type(M.items) ~= "table" then
		return
	end
	local id = (comment.is_task and "task:" or "comment:") .. tostring(comment.id)
	for index = #M.items, 1, -1 do
		if M.items[index].id == id then
			table.remove(M.items, index)
			return
		end
	end
end

---@param comment PullsComment
---@return string
local function comment_key(comment)
	return (comment.is_task and "task:" or "comment:") .. tostring(comment.id)
end

---@param comment PullsComment
---@return boolean
local function is_comment_long(comment)
	if comment.is_task or comment.state == "DELETED" then
		return false
	end
	local content = utils.strip_markup(comment.content_display or comment.content_raw or "")
	local lines = utils.sanitize_lines(content)
	while #lines > 0 and vim.trim(lines[#lines]) == "" do
		table.remove(lines)
	end
	return #lines > MAX_COMMENT_LINES
end

---@param comment PullsComment
---@return boolean
local function is_comment_expanded(comment)
	return M.expanded_comments[comment_key(comment)] == true
end

---@param comment PullsComment
---@return integer|nil
function M.comment_max_lines(comment)
	if is_comment_long(comment) and not is_comment_expanded(comment) then
		return MAX_COMMENT_LINES
	end
	return nil
end

---@param comment PullsComment
---@return boolean toggled
function M.toggle_comment(comment)
	if not is_comment_long(comment) then
		return false
	end
	local key = comment_key(comment)
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

---@param threads AtlasReviewThreadNode[]
---@return boolean
function M.toggle_all_threads(threads)
	local roots = {}
	local expand = false
	for _, thread in ipairs(threads) do
		if not thread.comment.is_task and #thread.children > 0 then
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
