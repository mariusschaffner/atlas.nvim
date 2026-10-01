local M = {}

local actions = require("atlas.pulls.actions.review")
local code_preview = require("atlas.ui.components.code_preview")
local inline_field_edit = require("atlas.ui.inline_field_edit")
local position = require("atlas.pulls.diff.position")
local presentation = require("atlas.pulls.ui.presentation")
local review = require("atlas.pulls.diff.review")
local review_threads = require("atlas.pulls.ui.components.review_threads")
local ui = require("atlas.pulls.diff.ui.comments")
local virt_line_anchor = require("atlas.pulls.diff.ui.virt_line_anchor")

local ACTIONS = {
	add_comment = function(context, comment, on_done)
		return actions.add_comment(context, { parent = comment, pending = true }, on_done)
	end,
	edit = actions.edit_comment,
	delete = actions.delete_comment,
	toggle_task = actions.toggle_task,
	toggle_resolved = actions.toggle_resolved,
}

---@param session AtlasDiffSession
---@param level "loading"|"success"|"warn"|"error"|"info"
---@param message string
---@param duration integer|nil
local function notify(session, level, message, duration)
	-- Lazy require: atlas.pulls.diff.session requires this module, so this
	-- can't be a top-level require.
	require("atlas.pulls.diff.session").notify(session, level, message, duration)
end

---@param node AtlasReviewThreadNode
---@param id any
---@return PullsComment|nil
local function find_in_thread(node, id)
	if tostring(node.comment.id) == tostring(id) then
		return node.comment
	end
	for _, child in ipairs(node.children) do
		local found = find_in_thread(child, id)
		if found then
			return found
		end
	end
	return nil
end

--- The specific comment (root or a reply) within `node`'s thread that
--- `]c`/`[c` has navigated to via `session.diff_selected_comment_id` -- or
--- the root when unset, not a task, or it belongs to a different thread
--- than `node` (cursor moved elsewhere since it was set).
---@param session AtlasDiffSession
---@param node AtlasReviewThreadNode
---@return PullsComment
local function selected_comment(session, node)
	local selected_id = session.diff_selected_comment_id
	if selected_id == nil then
		return node.comment
	end
	return find_in_thread(node, selected_id) or node.comment
end

--- Root + every non-task reply, depth-first, in the same order they render
--- in -- what `]c`/`[c` cycles `session.diff_selected_comment_id` through
--- once the cursor is already on a thread's line.
---@param node AtlasReviewThreadNode
---@return PullsComment[]
local function flatten_thread(node)
	local out = { node.comment }
	for _, child in ipairs(node.children) do
		if not child.comment.is_task then
			vim.list_extend(out, flatten_thread(child))
		end
	end
	return out
end

-- Forward-declared: assigned further down, after `visible_threads` --
-- `active_keys` calls `at_cursor`, which itself calls `render_context`, so
-- `render_context` must NOT compute `active_keys` itself (that would recurse
-- forever); callers that need it call `active_keys(session)` separately and
-- merge it in (see `M.render`/`M.open_at_cursor`).
local at_cursor
local active_keys

---@param session AtlasDiffSession
---@return AtlasCommentRendererContext|nil
local function render_context(session)
	local current = session.current
	local current_review = session.review
	if not current or not current_review then
		return nil
	end
	local capability = current_review.provider.capabilities.comments
	return {
		threads = review_threads.group_comments(current_review.data.comments, current_review.data.tasks),
		expanded_threads = session.expanded_threads,
		old_path = current.document.old.path,
		new_path = current.document.new.path,
		reaction_options = capability and capability.reaction_options,
		comments_capability = capability,
		current_user = current_review.current_user,
		reviewable = presentation.is_open_or_draft(current_review.pr),
		session = session,
	}
end

---@param session AtlasDiffSession
---@param context AtlasCommentRendererContext
---@param path string
---@param side AtlasDiffSide
---@return table<integer, AtlasReviewThreadNode[]>, AtlasReviewThreadNode[]
local function threads_by_line(session, context, path, side)
	local document = session.current.document
	local lines = side == "LEFT" and document.old.lines or document.new.lines
	local result, file_threads = {}, {}
	for _, node in ipairs(context.threads) do
		local comment = node.comment
		local target = comment.file or comment.inline
		local comment_side, line = position.comment(document, comment)
		local matches = target and target.path == path
		if target and not matches and (path == context.old_path or path == context.new_path) then
			matches = target.path == context.old_path or target.path == context.new_path
		end
		if matches and comment_side == side and (comment.file or (comment.outdated == true and line == nil)) then
			file_threads[#file_threads + 1] = node
		elseif matches and comment_side == side and line and line >= 1 and #lines > 0 then
			line = math.min(line, math.max(1, #lines))
			result[line] = result[line] or {}
			result[line][#result[line] + 1] = node
		end
	end
	return result, file_threads
end

---@param session AtlasDiffSession
---@param side AtlasDiffSide
---@param line integer
---@return integer, boolean
local function opposite_line(session, side, line)
	local current = session.current
	local target = side == "LEFT" and current.right.buf or current.left.buf
	return position.opposite_line(current.document, side, line, vim.api.nvim_buf_line_count(target))
end

---@param session AtlasDiffSession
---@param context AtlasCommentRendererContext
---@param path string
---@param side AtlasDiffSide
---@return table<integer, AtlasReviewThreadNode[]>, table<integer, boolean>, AtlasReviewThreadNode[]
local function visible_threads(session, context, path, side)
	local result, file_threads = threads_by_line(session, context, path, side)
	local above = {}
	if session.current.layout ~= "inline" or side ~= "RIGHT" then
		return result, above, file_threads
	end
	local old_by_line, old_file_threads = threads_by_line(session, context, context.old_path, "LEFT")
	for old_line, old_threads in pairs(old_by_line) do
		local line, is_above = opposite_line(session, "LEFT", old_line)
		result[line] = result[line] or {}
		vim.list_extend(result[line], old_threads)
		above[line] = is_above or nil
	end
	vim.list_extend(file_threads, old_file_threads)
	return result, above, file_threads
end

---@param session AtlasDiffSession
---@return table<string, { comments: boolean }>
function M.annotated_paths(session)
	local paths = {}
	local current_review = session.review
	for _, comment in ipairs(current_review and current_review.data.comments or {}) do
		local target = comment.file or comment.inline
		if target then
			paths[target.path] = paths[target.path] or { comments = false }
			paths[target.path].comments = true
		end
	end
	return paths
end

---@param session AtlasDiffSession
---@param context AtlasCommentRendererContext
---@param inline_deleted_lines boolean
---@return table
local function placed_threads(session, context, inline_deleted_lines)
	local current = session.current
	local placed = {
		right = {},
		right_above = {},
		right_file = {},
		left = {},
		left_above = {},
		left_file = {},
		deleted = {},
	}
	if inline_deleted_lines and current.layout == "inline" then
		placed.right, placed.right_file = threads_by_line(session, context, context.new_path, "RIGHT")
		local old_by_line, old_file_threads = threads_by_line(session, context, context.old_path, "LEFT")
		for old_line, list in pairs(old_by_line) do
			if position.is_changed(current.document, "LEFT", old_line) then
				placed.deleted[old_line] = list
			else
				local line, above = opposite_line(session, "LEFT", old_line)
				placed.right[line] = placed.right[line] or {}
				vim.list_extend(placed.right[line], list)
				placed.right_above[line] = above or nil
			end
		end
		vim.list_extend(placed.right_file, old_file_threads)
	else
		placed.right, placed.right_above, placed.right_file =
			visible_threads(session, context, context.new_path, "RIGHT")
	end
	if current.layout == "side-by-side" then
		placed.left, placed.left_above, placed.left_file = visible_threads(session, context, context.old_path, "LEFT")
	end
	return placed
end

---@param target AtlasDiffHint[]
---@param buf integer
---@param line integer
---@param list AtlasReviewThreadNode[]
local function add_line_hints(target, buf, line, list)
	for _, node in ipairs(list) do
		target[#target + 1] = {
			buf = buf,
			line = line,
			kind = "comment",
			text = node.comment.content_display or node.comment.content_raw,
		}
	end
end

---@param target AtlasDiffHint[]
---@param buf integer
---@param by_line table<integer, AtlasReviewThreadNode[]>
local function add_hints(target, buf, by_line)
	for line, list in pairs(by_line) do
		add_line_hints(target, buf, line, list)
	end
end

---@param session AtlasDiffSession
---@param inline_deleted_lines boolean
---@return AtlasDiffHint[], table<integer, AtlasDiffHint[]>
function M.hints(session, inline_deleted_lines)
	local current = session.current
	local context = render_context(session)
	if not current or not context then
		return {}, {}
	end
	local placed = placed_threads(session, context, inline_deleted_lines)
	local items = {}
	add_hints(items, current.right.buf, placed.right)
	add_hints(items, current.left.buf, placed.left)
	add_line_hints(items, current.right.buf, 1, placed.right_file)
	add_line_hints(items, current.left.buf, 1, placed.left_file)
	local deleted_hints = {}
	for line, list in pairs(placed.deleted) do
		deleted_hints[line] = {}
		add_line_hints(deleted_hints[line], current.right.buf, line, list)
	end
	return items, deleted_hints
end

---@param session AtlasDiffSession
---@param inline_deleted_lines boolean
---@return table<integer, [string, string][][]>
function M.render(session, inline_deleted_lines)
	local current = session.current
	local context = render_context(session)
	if not current or not context then
		return {}
	end
	context.active_keys = active_keys(session)
	local placed = placed_threads(session, context, inline_deleted_lines)
	local deleted = {}
	for line, list in pairs(placed.deleted) do
		deleted[line] = ui.thread_lines(context, current.right.buf, list)
	end
	local right = ui.render_comments(context, current.right.buf, placed.right, placed.right_above)
	local right_file_size = ui.render_file_comments(context, current.right.buf, placed.right_file)
	if current.layout ~= "side-by-side" then
		if vim.api.nvim_buf_is_valid(current.left.buf) then
			vim.api.nvim_buf_clear_namespace(
				current.left.buf,
				vim.api.nvim_create_namespace("atlas_diff_comments"),
				0,
				-1
			)
		end
		return deleted
	end
	local left = ui.render_comments(context, current.left.buf, placed.left, placed.left_above)
	local left_file_size = ui.render_file_comments(context, current.left.buf, placed.left_file)
	for line, count in pairs(left) do
		local target, above = opposite_line(session, "LEFT", line)
		ui.pad(current.right.buf, target, count, placed.left_above[line] or above)
	end
	for line, count in pairs(right) do
		local target, above = opposite_line(session, "RIGHT", line)
		ui.pad(current.left.buf, target, count, placed.right_above[line] or above)
	end
	if left_file_size > 0 then
		ui.pad(current.right.buf, 1, left_file_size, true)
	end
	if right_file_size > 0 then
		ui.pad(current.left.buf, 1, right_file_size, true)
	end
	return deleted
end

---@param session AtlasDiffSession
---@param buf integer
---@return string|nil, AtlasDiffSide|nil
local function buffer_context(session, buf)
	local current = session.current
	if not current then
		return nil, nil
	end
	if buf == current.left.buf then
		return current.document.old.path, "LEFT"
	end
	if buf == current.right.buf then
		return current.document.new.path, "RIGHT"
	end
	return nil, nil
end

---@param session AtlasDiffSession
---@param buf integer
---@return integer|nil
local function window_for_buf(session, buf)
	local current = session.current
	if not current then
		return nil
	end
	if buf == current.left.buf then
		return current.left.win
	end
	if buf == current.right.buf then
		return current.right.win
	end
	return nil
end

---@param session AtlasDiffSession
---@param comment PullsComment
---@return boolean
local function is_own_comment(session, comment)
	local current_user = session.review and session.review.current_user
	if not current_user or not comment or not comment.author then
		return false
	end
	return tostring(current_user.id) == tostring(comment.author.id)
end

---@param start_line integer|nil
---@param end_line integer|nil
---@return integer, integer
local function selected_range(start_line, end_line)
	local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
	start_line = start_line or cursor_line
	end_line = end_line or cursor_line
	return math.min(start_line, end_line), math.max(start_line, end_line)
end

---@param session AtlasDiffSession
---@param buf integer
---@param start_line integer
---@param end_line integer
---@return PullsInlineCommentPosition|nil, string|nil
local function inline_position(session, buf, start_line, end_line)
	local current = session.current
	local _, side = buffer_context(session, buf)
	if not current or not side then
		return nil, "This buffer is not part of the diff"
	end
	local inline, err = position.from_range(current.document, side, start_line, end_line)
	if inline then
		inline.commit_hash = session.source.head_revision
	end
	return inline, err
end

---@param session AtlasDiffSession
---@param buf integer
---@param selected_start integer
---@param selected_end integer
---@return AtlasMarkdownEditorPreview|nil
local function inline_preview(session, buf, selected_start, selected_end)
	local current = session.current
	local _, side = buffer_context(session, buf)
	if not current or not side or current.document.binary then
		return nil
	end
	local source = side == "LEFT" and current.document.old or current.document.new
	local first = math.max(1, selected_start - 2)
	local lines = {}
	for index = first, math.min(#source.lines, selected_end + 2) do
		lines[#lines + 1] = source.lines[index]
	end
	return code_preview.render({
		file_path = source.path,
		lines = lines,
		start_line = first,
		anchor_start = selected_start,
		anchor_line = selected_end,
	})
end

---@param session AtlasDiffSession
---@param action AtlasReviewThreadAction
---@param comment PullsComment
---@param on_done fun()|nil
---@return boolean
function M.run_action(session, action, comment, on_done)
	local context = review.action_context(session, comment)
	local handler = ACTIONS[action]
	if not context or not handler then
		return false
	end
	return handler(context, comment, function(result, err)
		if result and not err then
			session:render()
			if on_done then
				on_done()
			end
		end
	end)
end

---@param session AtlasDiffSession
---@param buf integer
---@return AtlasReviewThreadNode[]
at_cursor = function(session, buf)
	local path, side = buffer_context(session, buf)
	local context = render_context(session)
	if not path or not side or not context then
		return {}
	end
	local line = vim.api.nvim_win_get_cursor(0)[1]
	local by_line, _, file_threads = visible_threads(session, context, path, side)
	local nodes = vim.list_extend({}, by_line[line] or {})
	if line == 1 then
		vim.list_extend(nodes, file_threads)
	end
	return nodes
end

---@param session AtlasDiffSession
---@param buf integer
---@return boolean
function M.has_at_cursor(session, buf)
	return #at_cursor(session, buf) > 0
end

--- The comment(s) (root, or the `]c`/`[c`-selected reply within it) whose
--- thread is anchored at the CURRENT window's cursor position -- drives the
--- "active" highlight (`AtlasCommentRendererContext.active_keys`).
--- Deliberately separate from `render_context`: this calls `at_cursor`, which
--- itself calls `render_context`, so `render_context` must never compute this
--- on its own (infinite recursion) -- callers that render (currently just
--- `M.render` and `M.open_at_cursor`) fetch it explicitly and merge it in.
---@param session AtlasDiffSession
---@return table<string, boolean>
active_keys = function(session)
	local win = vim.api.nvim_get_current_win()
	if not vim.api.nvim_win_is_valid(win) then
		return {}
	end
	local buf = vim.api.nvim_win_get_buf(win)
	local keys = {}
	for _, node in ipairs(at_cursor(session, buf)) do
		keys[review_threads.comment_key(selected_comment(session, node))] = true
	end
	return keys
end

--- A stable, sorted signature of `active_keys(session)` -- cheap to compare
--- across cursor moves so callers (the `CursorMoved` autocmd in
--- `pulls/diff/keymaps.lua`) can skip re-rendering when the active thread(s)
--- haven't actually changed.
---@param session AtlasDiffSession
---@return string
function M.active_signature(session)
	local list = {}
	for key in pairs(active_keys(session)) do
		table.insert(list, key)
	end
	table.sort(list)
	return table.concat(list, ",")
end

--- Scrolls the active thread's anchor line to the TOP of the window the
--- moment the cursor reaches it (see the `CursorMoved` autocmd in
--- `pulls/diff/keymaps.lua`) -- proactively, before any reply/edit is ever
--- requested, so there's always room below for the inline overlay when the
--- user does press `c`/`gE`. Doing this on arrival rather than at
--- open-the-overlay time also sidesteps a real failure mode that reactive
--- scrolling had: scrolling the window exactly as the overlay opens can fire
--- a `WinScrolled` event the overlay's own `close_on_win_event` autocmd
--- (registered moments earlier) reacts to, closing the overlay it was just
--- about to show. Scrolling here means the window is typically already
--- correctly positioned by the time an overlay opens, so `open_inline_overlay`'s
--- own `ensure_visible` call is a no-op (no scroll, no event, nothing to
--- race against).
---@param session AtlasDiffSession
---@param buf integer
function M.ensure_comment_visible(session, buf)
	local nodes = at_cursor(session, buf)
	if #nodes == 0 then
		return
	end
	local win = window_for_buf(session, buf)
	if not win then
		return
	end
	local comment = selected_comment(session, nodes[1])
	local region = session.diff_regions[review_threads.comment_key(comment)]
	if not region or not region.anchor_line then
		return
	end
	-- `'scrolloff'` fights pinning the anchor flush against the window edge
	-- (Vim insists on leaving that many lines of padding instead), and a
	-- redraw re-applies that constraint continuously -- not just once, at
	-- the moment of the scroll -- so the override has to stay in place for
	-- as long as the cursor stays parked here, or the very next redraw
	-- (cursor blink, an unrelated UI update, anything) silently un-does it
	-- before the user ever gets to press `c`/`gE`. Restored by
	-- `M.restore_scroll_behavior` once the cursor actually leaves.
	if session.diff_scrolloff_overrides[win] == nil then
		session.diff_scrolloff_overrides[win] = vim.wo[win].scrolloff
		vim.wo[win].scrolloff = 0
	end
	virt_line_anchor.ensure_visible(win, region.anchor_line, region.above)
end

--- Restores `'scrolloff'` on any window `M.ensure_comment_visible` zeroed
--- out, once the cursor has moved off of every active comment (the
--- `CursorMoved` autocmd calls this when `active_signature` goes back to
--- `""`). Safe to call unconditionally -- a no-op when nothing is overridden.
---@param session AtlasDiffSession
function M.restore_scroll_behavior(session)
	for win, original in pairs(session.diff_scrolloff_overrides) do
		if vim.api.nvim_win_is_valid(win) then
			vim.wo[win].scrolloff = original
		end
	end
	session.diff_scrolloff_overrides = {}
end

---@param nodes AtlasReviewThreadNode[]
---@return string
local function popup_title(nodes)
	local path, side, line, file_comment
	for _, node in ipairs(nodes) do
		local comment = node.comment
		local target = comment.file or comment.inline
		if target then
			local node_side, node_line = "RIGHT", 1
			if comment.inline then
				node_side, node_line = position.location(comment.inline)
			end
			if path and (path ~= target.path or side ~= node_side or line ~= node_line) then
				return " Review threads "
			end
			path, side, line, file_comment = target.path, node_side, node_line, comment.file ~= nil
		end
	end
	if file_comment and path then
		return string.format(" %s ", path)
	end
	return path and side and line and string.format(" %s:%d (%s) ", path, line, side) or " Review thread "
end

---@param session AtlasDiffSession
---@param buf integer
---@return boolean
function M.open_at_cursor(session, buf)
	local nodes = at_cursor(session, buf)
	if #nodes == 0 then
		return false
	end
	local owner = session.id
	local context = render_context(session)
	if not context then
		return false
	end
	context.active_keys = active_keys(session)
	ui.open_popup({
		nodes = nodes,
		owner = owner,
		title = popup_title(nodes),
		context = context,
		on_action = function(action, comment, close)
			M.run_action(session, action, comment, function()
				close()
			end)
		end,
		on_reply = function(parent, text, done)
			local action_context = review.action_context(session, parent)
			if not action_context then
				done(false, "No context")
				return
			end
			actions.add_comment_inline(action_context, { parent = parent, pending = true }, text, function(ok, err)
				if ok then
					session:render()
				end
				done(ok, err)
			end)
		end,
		on_edit = function(comment, text, done)
			local action_context = review.action_context(session, comment)
			if not action_context then
				done(false, "No context")
				return
			end
			actions.edit_comment_inline(action_context, comment, text, function(ok, err)
				if ok then
					session:render()
				end
				done(ok, err)
			end)
		end,
	})
	return true
end

---@param session AtlasDiffSession
---@param buf integer
---@return boolean
function M.toggle_at_cursor(session, buf)
	local nodes = at_cursor(session, buf)
	if not review_threads.toggle_all_threads(nodes, session.expanded_threads) then
		return false
	end
	session:render()
	return true
end

---@param session AtlasDiffSession
---@return boolean
function M.toggle_all(session)
	local context = render_context(session)
	if not context or not review_threads.toggle_all_threads(context.threads, session.expanded_threads) then
		return false
	end
	session:render()
	return true
end

--- If the cursor is on a single, unambiguous (non-task) thread with more
--- than one comment, moves `session.diff_selected_comment_id` to the
--- next/previous comment in it (root first, then each reply in order) and
--- re-renders. This is the only way to select a specific reply for
--- edit/reply/delete/toggle-resolved: virt_lines aren't individually
--- cursor-addressable, so there's no other way to move "into" a thread.
--- Bound to plain `j`/`k` (see `pulls/diff/keymaps.lua`) so replies read as
--- "part of" the comment you're already on; falls through (returns `false`,
--- doing nothing itself) once past either end, or when there's nothing to
--- cycle into, so the caller's native `j`/`k` can take over moving the
--- cursor to the next real line.
---@param session AtlasDiffSession
---@param buf integer
---@param direction 1|-1
---@return boolean consumed
function M.cycle_reply(session, buf, direction)
	local nodes = at_cursor(session, buf)
	if #nodes ~= 1 or nodes[1].comment.is_task then
		session.diff_selected_comment_id = nil
		return false
	end
	local flat = flatten_thread(nodes[1])
	if #flat <= 1 then
		return false
	end
	local selected_id = session.diff_selected_comment_id
	local current_index = 1
	if selected_id ~= nil then
		for i, c in ipairs(flat) do
			if tostring(c.id) == tostring(selected_id) then
				current_index = i
				break
			end
		end
	end
	local next_index = current_index + direction
	if next_index < 1 or next_index > #flat then
		return false
	end
	-- NOT `next_index == 1 and nil or flat[next_index].id`: with `nil`
	-- (falsy) as the "then" value, that idiom always falls through to the
	-- "or" branch regardless of the condition.
	if next_index == 1 then
		session.diff_selected_comment_id = nil
	else
		session.diff_selected_comment_id = flat[next_index].id
	end
	session:render()
	return true
end

---@param session AtlasDiffSession
---@param buf integer
---@param direction 1|-1
function M.jump(session, buf, direction)
	session.diff_selected_comment_id = nil

	local _, current_side = buffer_context(session, buf)
	local context = render_context(session)
	if not current_side or not context then
		return
	end
	local locations = {}
	local sides = session.current.layout == "inline" and { "RIGHT" } or { "LEFT", "RIGHT" }
	for _, side in ipairs(sides) do
		local path = side == "LEFT" and context.old_path or context.new_path
		local by_line, _, file_threads = visible_threads(session, context, path, side)
		for line in pairs(by_line) do
			locations[#locations + 1] = {
				side = side,
				line = line,
				display = side == current_side and line or opposite_line(session, side, line),
			}
		end
		if #file_threads > 0 and by_line[1] == nil then
			locations[#locations + 1] = { side = side, line = 1, display = 1 }
		end
	end
	if #locations == 0 then
		return
	end
	table.sort(locations, function(a, b)
		return a.display == b.display and a.side < b.side or a.display < b.display
	end)
	local cursor = vim.api.nvim_win_get_cursor(0)[1]
	local target = direction > 0 and locations[1] or locations[#locations]
	if direction > 0 then
		for _, location in ipairs(locations) do
			if location.display > cursor or (location.display == cursor and location.side > current_side) then
				target = location
				break
			end
		end
	else
		for index = #locations, 1, -1 do
			local location = locations[index]
			if location.display < cursor or (location.display == cursor and location.side < current_side) then
				target = location
				break
			end
		end
	end
	local win = target.side == "LEFT" and session.current.left.win or session.current.right.win
	if win and vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_set_current_win(win)
		vim.api.nvim_win_set_cursor(win, { target.line, 0 })
		local folded = vim.fn.foldclosed(target.line) ~= -1
		vim.cmd.normal({ args = { "zv" }, bang = true })
		if folded and session.current.layout == "side-by-side" then
			local other = target.side == "LEFT" and session.current.right.win or session.current.left.win
			if other and vim.api.nvim_win_is_valid(other) then
				local line = opposite_line(session, target.side, target.line)
				vim.api.nvim_win_call(other, function()
					local previous = vim.api.nvim_win_get_cursor(other)
					vim.api.nvim_win_set_cursor(other, { line, 0 })
					vim.cmd.normal({ args = { "zv" }, bang = true })
					vim.api.nvim_win_set_cursor(other, previous)
				end)
			end
		end
	end
end

---@param session AtlasDiffSession
---@param buf integer
---@param pending boolean
---@param start_line integer|nil
---@param end_line integer|nil
---@param suggestion boolean
local function add(session, buf, pending, start_line, end_line, suggestion)
	local context = review.action_context(session)
	local current = session.current
	if not context or not current then
		return
	end
	if suggestion and buf ~= current.right.buf then
		notify(session, "info", "Suggestions are only available on the new side of the diff")
		return
	end
	start_line, end_line = selected_range(start_line, end_line)
	local inline, err = inline_position(session, buf, start_line, end_line)
	if not inline then
		notify(session, "info", err or "Cannot comment on this line")
		return
	end
	local opts = {
		inline = inline,
		pending = pending,
		preview = inline_preview(session, buf, start_line, end_line),
	}
	if suggestion then
		local lines = {}
		for line = start_line, end_line do
			lines[#lines + 1] = current.document.new.lines[line]
		end
		local fence = "suggestion"
		if context.provider.id == "gitlab" then
			fence = string.format("suggestion:-%d+0", #lines - 1)
		end
		opts.initial_text = string.format("\n```%s\n%s\n```", fence, table.concat(lines, "\n"))
		opts.kind = "suggestion"
	end
	actions.add_comment(context, opts, function(result, action_err)
		if result and not action_err then
			session:render()
		end
	end)
end

---@param session AtlasDiffSession
---@param file PullsFileCommentPosition
---@param pending boolean
function M.add_to_file(session, file, pending)
	local context = review.action_context(session)
	if not context then
		return
	end
	file.commit_hash = session.source.head_revision
	actions.add_comment(context, { file = file, pending = pending }, function(result, action_err)
		if result and not action_err then
			session:render()
		end
	end)
end

---@param win integer
---@param region table `session.diff_regions`/`session.diff_regions.composing`-shaped geometry (anchor_line/above/block_row/col/width/height).
---@param seed_text string
---@param on_save fun(text: string, done: fun(ok: boolean, err: string|nil))
---@param on_done fun()
---@return boolean opened
local function open_inline_overlay(win, region, seed_text, on_save, on_done)
	-- `'scrolloff'` fights `ensure_visible`'s `zt`/`zb`: with it set (a very
	-- common user config), Vim refuses to put the anchor line flush against
	-- the window edge and leaves `scrolloff` lines of padding instead --
	-- which is exactly the room `zt`/`zb` exist to reclaim for the comment
	-- box. That shows up as "it scrolls, but not quite enough." Override it
	-- window-locally to 0 for as long as the overlay is open (restored in
	-- `on_done`/on failure below) so the anchor can actually reach the edge;
	-- harmless since the user's attention is on the floating overlay, not
	-- scrolling the content window, while it's up.
	local saved_scrolloff = vim.wo[win].scrolloff
	vim.wo[win].scrolloff = 0
	virt_line_anchor.ensure_visible(win, region.anchor_line, region.above)
	local screen_row = virt_line_anchor.screen_row(win, {
		anchor_line = region.anchor_line,
		above = region.above,
		block_row = region.block_row,
	})
	if not screen_row then
		if vim.api.nvim_win_is_valid(win) then
			vim.wo[win].scrolloff = saved_scrolloff
		end
		return false
	end
	inline_field_edit.start({
		anchor_win = win,
		screen_row = screen_row,
		col = region.col,
		width = region.width,
		height = region.height,
		seed_text = seed_text,
		close_on_win_event = true,
		on_save = on_save,
		on_cancel = function() end,
		on_done = function()
			if vim.api.nvim_win_is_valid(win) then
				vim.wo[win].scrolloff = saved_scrolloff
			end
			on_done()
		end,
	})
	return true
end

--- `open_inline_overlay`, with one scheduled retry if the first attempt
--- can't resolve a screen position. `virt_line_anchor.ensure_visible` already
--- scrolls to give the comment box the most room it can get (pinned to
--- whichever window edge its virt_lines actually grow away from), so the
--- retry here is only for a second, narrower failure mode: the first
--- attempt reads window/fold state (`virt_line_anchor.screen_row`)
--- immediately after `session:render()` added the very extmark it needs to
--- measure against, which can occasionally still be unsettled in a real
--- (non-headless) session. A single `vim.schedule` + `redraw` tick covers
--- that; `region_fn` re-reads `session.diff_regions` for the retry rather
--- than reusing the first attempt's (possibly stale) table. Between the
--- scroll-to-fit and this retry, `on_fail` should only ever fire for a
--- comment box that's taller than the entire window -- genuinely nothing
--- left to automatically fix, so it just quietly drops back to read-only
--- (no popup, no notification).
---@param win integer
---@param region_fn fun(): table|nil
---@param seed_text string
---@param on_save fun(text: string, done: fun(ok: boolean, err: string|nil))
---@param on_done fun()
---@param on_fail fun() Called only if the retry also fails.
local function open_inline_overlay_resilient(win, region_fn, seed_text, on_save, on_done, on_fail)
	local region = region_fn()
	if region and open_inline_overlay(win, region, seed_text, on_save, on_done) then
		return
	end
	vim.schedule(function()
		if not vim.api.nvim_win_is_valid(win) then
			on_fail()
			return
		end
		vim.cmd("redraw")
		local retry_region = region_fn()
		if not (retry_region and open_inline_overlay(win, retry_region, seed_text, on_save, on_done)) then
			on_fail()
		end
	end)
end

--- Reply/edit/add-new-thread for a plain comment, driven directly through
--- the inline overlay (`atlas.ui.inline_field_edit`), matching the Activity
--- tab. Tasks and suggestions are out of scope (kept on the pre-existing
--- popup-editor flow: `M.add_suggestion`, and edit/delete for tasks via
--- `M.run_action`) -- see the module doc in `atlas/pulls/diff/ui/comments.lua`.

---@param session AtlasDiffSession
---@param buf integer
function M.edit_at_cursor(session, buf)
	local nodes = at_cursor(session, buf)
	if #nodes > 1 then
		M.open_at_cursor(session, buf)
		return
	end
	if #nodes == 0 then
		return
	end
	local comment = selected_comment(session, nodes[1])
	if comment.is_task or not is_own_comment(session, comment) then
		return
	end
	local context = review.action_context(session, comment)
	local win = window_for_buf(session, buf)
	if not context or not win then
		return
	end
	local key = review_threads.comment_key(comment)
	session.diff_editing_id = key
	-- Editing needs the full bordered box on screen (with the "editing"
	-- border baked in and `session.diff_regions` populated) -- the compact
	-- "hints" display mode (`session.expanded_overlays == false`, the
	-- default) never renders comment boxes or their regions at all, which
	-- would otherwise make every inline edit/reply/add silently fail to find
	-- a region.
	session.expanded_overlays = true
	session:render()
	open_inline_overlay_resilient(win, function()
		local region = session.diff_regions[key]
		-- `region.anchor_line` is absent for comments rendered through the
		-- "deleted lines" virt-text path (`inline_deleted_lines` mode) --
		-- those aren't addressable by `virt_line_anchor` at all, retry or not.
		return region and region.anchor_line and region or nil
	end, tostring(comment.content_raw or ""), function(text, done)
		actions.edit_comment_inline(context, comment, text, done)
	end, function()
		session.diff_editing_id = nil
		session:render()
	end, function()
		session.diff_editing_id = nil
		session:render()
	end)
end

---@param session AtlasDiffSession
---@param buf integer
---@param pending boolean|nil
function M.reply_at_cursor(session, buf, pending)
	local nodes = at_cursor(session, buf)
	if #nodes > 1 then
		M.open_at_cursor(session, buf)
		return
	end
	if #nodes == 0 then
		return
	end
	local comment = selected_comment(session, nodes[1])
	if comment.is_task then
		return
	end
	local context = review.action_context(session, comment)
	local win = window_for_buf(session, buf)
	if not context or not win then
		return
	end
	-- Same "compact display mode never populates regions" reasoning as
	-- `edit_at_cursor` -- force expanded and render once before reading the
	-- parent's region, or `session.diff_regions` may still be empty.
	session.expanded_overlays = true
	session:render()
	local parent_key = review_threads.comment_key(comment)
	local parent_region = session.diff_regions[parent_key]
	if not parent_region or not parent_region.anchor_line then
		-- Same "deleted lines" caveat as `edit_at_cursor` -- no addressable
		-- inline anchor for this comment, so fall back to the popup.
		M.open_at_cursor(session, buf)
		return
	end
	session.diff_composing = {
		kind = "reply",
		buf = buf,
		line = parent_region.anchor_line,
		above = parent_region.above,
		parent = comment,
	}
	session:render()
	local composing_key = "composing:" .. parent_key
	open_inline_overlay_resilient(win, function()
		return session.diff_regions[composing_key]
	end, "", function(text, done)
		actions.add_comment_inline(context, { parent = comment, pending = pending }, text, done)
	end, function()
		session.diff_composing = nil
		session:render()
	end, function()
		session.diff_composing = nil
		session:render()
	end)
end

---@param session AtlasDiffSession
---@param buf integer
---@param pending boolean
---@param start_line integer|nil
---@param end_line integer|nil
function M.add_at_cursor(session, buf, pending, start_line, end_line)
	local context = review.action_context(session)
	local win = window_for_buf(session, buf)
	if not context or not win then
		return
	end
	start_line, end_line = selected_range(start_line, end_line)
	local inline, err = inline_position(session, buf, start_line, end_line)
	if not inline then
		notify(session, "info", err or "Cannot comment on this line")
		return
	end
	session.diff_composing = { kind = "add", buf = buf, line = end_line, above = false }
	-- Same "compact display mode never populates regions" reasoning as
	-- `edit_at_cursor`.
	session.expanded_overlays = true
	session:render()
	open_inline_overlay_resilient(win, function()
		return session.diff_regions.composing
	end, "", function(text, done)
		actions.add_comment_inline(context, { inline = inline, pending = pending }, text, done)
	end, function()
		session.diff_composing = nil
		session:render()
	end, function()
		session.diff_composing = nil
		session:render()
	end)
end

--- `c`/`C` on a single existing (non-task) thread replies to it inline;
--- ambiguous (multiple threads at this spot) falls back to the popup, same
--- escape hatch `delete_at_cursor`/`toggle_resolved_at_cursor` already use;
--- otherwise it's a brand-new top-level thread. Only ever called for a plain
--- comment -- see `M.add_suggestion` for the suggestion (`s`/`S`) flow, which
--- stays on the editor-popup path since it needs the fenced ```suggestion
--- block this inline overlay doesn't support.
---@param session AtlasDiffSession
---@param buf integer
---@param pending boolean
---@param start_line integer|nil
---@param end_line integer|nil
function M.add_comment(session, buf, pending, start_line, end_line)
	if start_line == nil and end_line == nil then
		local nodes = at_cursor(session, buf)
		if #nodes > 1 then
			M.open_at_cursor(session, buf)
			return
		elseif #nodes == 1 and not nodes[1].comment.is_task then
			M.reply_at_cursor(session, buf, pending)
			return
		end
	end
	M.add_at_cursor(session, buf, pending, start_line, end_line)
end

---@param session AtlasDiffSession
---@param buf integer
---@param pending boolean
---@param start_line integer|nil
---@param end_line integer|nil
function M.add_suggestion(session, buf, pending, start_line, end_line)
	add(session, buf, pending, start_line, end_line, true)
end

---@param session AtlasDiffSession
---@param buf integer
function M.delete_at_cursor(session, buf)
	local nodes = at_cursor(session, buf)
	if #nodes == 1 then
		M.run_action(session, "delete", selected_comment(session, nodes[1]))
	elseif #nodes > 1 then
		M.open_at_cursor(session, buf)
	end
end

---@param session AtlasDiffSession
---@param buf integer
function M.toggle_resolved_at_cursor(session, buf)
	local nodes = at_cursor(session, buf)
	if #nodes == 1 then
		local comment = selected_comment(session, nodes[1])
		M.run_action(session, comment.is_task and "toggle_task" or "toggle_resolved", comment)
	elseif #nodes > 1 then
		M.open_at_cursor(session, buf)
	end
end

---@param session AtlasDiffSession
---@param buf integer
function M.open_in_browser(session, buf)
	for _, node in ipairs(at_cursor(session, buf)) do
		local url = tostring(node.comment.html_url or node.comment.url or "")
		if url ~= "" then
			vim.ui.open(url)
			return
		end
	end
	local current_review = session.review
	if current_review and current_review.pr.link and current_review.pr.link.html then
		vim.ui.open(current_review.pr.link.html)
	end
end

return M
