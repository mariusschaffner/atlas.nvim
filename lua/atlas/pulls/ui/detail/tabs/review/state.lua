local request_scope = require("atlas.core.requests")

---@class PullsReviewComposing
---@field parent PullsComment
---@field seed_text string

---@class PullsReviewNavigableEntry
---@field id string "block:<path>" or "comment:<id>"
---@field kind "block"|"comment"
---@field path string|nil Only set for kind == "block".
---@field comment PullsComment|nil Only set for kind == "comment".
---@field root PullsComment|nil Thread root; only set for kind == "comment".

---@class PullsReviewState
---@field data PullsReviewData|nil
---@field status string|nil
---@field hunks_by_comment table<string, { hunk: DiffHunk, anchor: integer }>
---@field expanded_threads table<string, boolean>
---@field collapsed_files table<string, boolean>
---@field requests AtlasRequestScope
---@field current_pr PullRequest|nil
---@field active_id string|nil Currently active/selected entry id (not cursor-bound).
---@field editing_id string|nil Comment id currently being inline-edited, if any.
---@field composing PullsReviewComposing|nil In-progress inline reply, if any.
---@field regions table<string, AtlasFieldBoxRegion> Interior regions from the last render, keyed by
--- navigable id (or "composing").
---@field navigable PullsReviewNavigableEntry[] Flattened, in-order list of every visible entry from the last render.
local M = {
	data = nil,
	status = nil,
	hunks_by_comment = {},
	expanded_threads = {},
	collapsed_files = {},
	requests = request_scope.new(),
	current_pr = nil,
	active_id = nil,
	editing_id = nil,
	composing = nil,
	regions = {},
	navigable = {},
}

function M.reset()
	M.data = nil
	M.status = nil
	M.hunks_by_comment = {}
	M.expanded_threads = {}
	M.collapsed_files = {}
	M.requests.cancel()
	M.requests = request_scope.new()
	M.current_pr = nil
	M.active_id = nil
	M.editing_id = nil
	M.composing = nil
	M.regions = {}
	M.navigable = {}
end

---@return PullsReviewNavigableEntry|nil
function M.active_entry()
	for _, entry in ipairs(M.navigable) do
		if entry.id == M.active_id then
			return entry
		end
	end
	return nil
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

---@param path string
---@return boolean
function M.is_file_collapsed(path)
	return M.collapsed_files[path] == true
end

---@param path string
function M.toggle_file_collapsed(path)
	M.collapsed_files[path] = not M.is_file_collapsed(path) or nil
end

---@param root PullsComment
---@return boolean
function M.is_thread_expanded(root)
	return M.expanded_threads[tostring(root.id)] == true
end

---@param root PullsComment
---@param expanded boolean
local function set_expanded(root, expanded)
	M.expanded_threads[tostring(root.id)] = expanded and true or nil
end

---@param roots PullsComment[]
---@return boolean
function M.toggle_threads(roots)
	if #roots == 0 then
		return false
	end
	local expand = false
	for _, root in ipairs(roots) do
		if not M.is_thread_expanded(root) then
			expand = true
			break
		end
	end
	for _, root in ipairs(roots) do
		set_expanded(root, expand)
	end
	return true
end

---@param comments PullsComment[]
---@return PullsComment[]
local function thread_roots(comments)
	local ids = {}
	for _, comment in ipairs(comments) do
		ids[tostring(comment.id)] = true
	end
	local roots = {}
	for _, comment in ipairs(comments) do
		if comment.parent_id == nil or not ids[tostring(comment.parent_id)] then
			table.insert(roots, comment)
		end
	end
	return roots
end

---@param comments PullsComment[]
---@return boolean
function M.toggle_all_folds(comments)
	local roots = thread_roots(comments)
	if #roots == 0 then
		return false
	end

	local expand = false
	for _, root in ipairs(roots) do
		if not M.is_thread_expanded(root) then
			expand = true
			break
		end
	end

	for _, root in ipairs(roots) do
		set_expanded(root, expand)
	end
	return true
end

return M
