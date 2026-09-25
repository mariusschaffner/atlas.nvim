local M = {}

local utils = require("atlas.ui.shared.utils")
local spinner = require("atlas.ui.components.spinner")
local bordered_box = require("atlas.ui.components.bordered_box")
local comment_box = require("atlas.pulls.ui.components.comment_box")
local diff = require("atlas.ui.components.diff_hunks")
local review_threads = require("atlas.pulls.ui.components.review_threads")
local presentation = require("atlas.pulls.ui.presentation")
local state = require("atlas.pulls.ui.detail.tabs.review.state")
local detail = require("atlas.pulls.ui.detail.state")

local PADDING_X = 1

---@param tasks PullsComment[]
---@return string
local function task_heading(tasks)
	local label = vim.trim(tostring(tasks[1] and tasks[1].task_label or "Task"))
	if label == "" then
		label = "Task"
	end
	return label:sub(-1):lower() == "s" and label or (label .. "s")
end

--- Tasks aren't part of the active-comment/inline-editing redesign (same
--- scoping as the Activity tab: tasks keep their existing popup-based
--- editor). They're still registered as navigable so j/k can pass through
--- them rather than stranding the whole task section, with a plain
--- CursorLine highlight -- no border/hint -- marking the active one.
---@param lines string[]
---@param spans table[]
---@param line_map table<integer, table>
---@param task PullsComment
---@param width integer
local function emit_task(lines, spans, line_map, task, width)
	local id = "task:" .. tostring(task.id)
	table.insert(state.navigable, { id = id, kind = "task", comment = task })

	local task_lines, task_spans, task_map = review_threads.render_task_compact(
		{ comment = task, children = {} },
		width,
		{
			padding_x = PADDING_X,
			show_task_label = false,
		}
	)
	local offset = #lines
	state.regions[id] =
		{ row = offset, col = PADDING_X, width = math.max(1, width - PADDING_X * 2), height = math.max(1, #task_lines) }
	utils.append_block(lines, spans, { lines = task_lines, highlights = task_spans })
	for line, entry in pairs(task_map) do
		line_map[offset + line] = entry
	end
	if state.active_id == id then
		for i = 0, #task_lines - 1 do
			table.insert(spans, { line = offset + i, line_hl_group = "CursorLine" })
		end
	end
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

--- Same box style, content layout, and bottom-hint convention as the
--- Activity tab's own comment boxes (`comment_box.lua`) -- only the set of
--- available actions differs, reflecting this tab's own keymaps (reply /
--- edit / delete / toggle-resolved) rather than Activity's (reply / edit /
--- delete). Always grey (`AtlasFieldBoxBorder`): unlike Activity, this tab
--- has no "currently active comment" concept to turn a border blue for.
---@param comment PullsComment
---@param is_root boolean
---@return string|nil text
---@return table[]|nil highlights
local function bottom_hint_for(comment, is_root)
	local provider = detail.provider
	local comments = provider and provider.capabilities.comments
	if not comments or not presentation.is_open_or_draft(detail.current_pr) then
		return nil, nil
	end

	local segments = {}
	if comments.add_comment then
		table.insert(segments, { action_id = "ui.comments.reply", label = "Reply", hl = "AtlasFooterInfo" })
	end
	local own = is_own_comment(comment)
	if own and comments.edit_comment then
		table.insert(segments, { action_id = "ui.comments.edit", label = "Edit", hl = "AtlasFooterWarning" })
	end
	if own and comments.delete_comment then
		table.insert(segments, { action_id = "ui.delete", label = "Delete", hl = "AtlasFooterError" })
	end
	if is_root then
		table.insert(segments, {
			action_id = "pulls.review.diff.toggle_resolved",
			label = comment.state == "RESOLVED" and "Reopen" or "Resolve",
			hl = "AtlasFooterInfo",
		})
	end
	return comment_box.build_hint(segments)
end

---@return string text
---@return table[] highlights
local function editing_hint()
	local hl = "AtlasFieldBoxBorderEditing"
	return comment_box.build_hint({
		{ action_id = "ui.submit", label = "Save", hl = hl },
		{ action_id = "ui.field_edit.close", label = "Cancel", hl = hl },
	})
end

---@param lines string[]
---@param spans table[]
---@param indent integer
local function append_connector(lines, spans, indent)
	local connector_line = string.rep(" ", indent) .. "│"
	table.insert(lines, connector_line)
	table.insert(spans, { line = #lines - 1, start_col = indent, end_col = indent + 1, hl_group = "AtlasTextMuted" })
end

---@param node AtlasReviewThreadNode
---@return integer
local function descendant_count(node)
	local count = #node.children
	for _, child in ipairs(node.children) do
		count = count + descendant_count(child)
	end
	return count
end

---@param width integer
---@param depth integer
---@param lines string[]
---@param spans table[]
local function render_composing_box(width, depth, lines, spans)
	local composing = state.composing
	if not composing then
		return
	end

	local title = "New Comment"
	local title_highlights = nil
	local current_user = require("atlas.pulls.state").current_user
	if current_user and current_user.name and current_user.name ~= "" then
		title = current_user.name
		title_highlights = { { start_col = 0, end_col = #title, hl_group = presentation.author_hl(title) } }
	end

	local bottom_hint, bottom_hint_highlights = editing_hint()
	local box_lines, box_highlights, region = comment_box.render_composing({
		title = title,
		title_highlights = title_highlights,
		depth = depth,
		padding_x = PADDING_X,
		width = width,
		bottom_hint = bottom_hint,
		bottom_hint_highlights = bottom_hint_highlights,
	})

	local base = #lines
	state.regions.composing = { row = base + region.row, col = region.col, width = region.width, height = region.height }

	for _, line in ipairs(box_lines) do
		table.insert(lines, line)
	end
	for _, span in ipairs(box_highlights) do
		table.insert(spans, {
			line = base + span.line,
			start_col = span.start_col,
			end_col = span.end_col,
			hl_group = span.hl_group,
		})
	end
end

---@param node AtlasReviewThreadNode
---@param root PullsComment
---@param depth integer
---@param width integer
---@param lines string[]
---@param spans table[]
---@param line_map table<integer, table>
local function render_comment_tree(node, root, depth, width, lines, spans, line_map)
	local comment = node.comment

	if comment.is_task then
		if #lines > 0 then
			append_connector(lines, spans, PADDING_X)
		end
		emit_task(lines, spans, line_map, comment, width)
		return
	end

	local id = "comment:" .. tostring(comment.id)
	local is_root = depth == 0
	local has_children = #node.children > 0
	local collapsed = is_root and has_children and not state.is_thread_expanded(comment)

	table.insert(state.navigable, { id = id, kind = "comment", comment = comment, root = root })

	local extra_lines, extra_highlights
	if collapsed then
		local count = descendant_count(node)
		local text = string.format("%d %s", count, count == 1 and "Reply" or "Replies")
		extra_lines = { text }
		extra_highlights = { { line = 0, start_col = 0, end_col = #text, hl_group = "AtlasTextMuted" } }
	end

	if depth > 0 then
		append_connector(lines, spans, PADDING_X + depth * 2)
	end

	local is_editing = state.editing_id == id
	local is_active = state.composing == nil and state.active_id == id
	local border_hl = is_editing and "AtlasFieldBoxBorderEditing"
		or (is_active and "AtlasFieldBoxBorderEditable")
		or "AtlasFieldBoxBorder"

	local bottom_hint, bottom_hint_highlights
	if is_editing then
		bottom_hint, bottom_hint_highlights = editing_hint()
	elseif is_active then
		bottom_hint, bottom_hint_highlights = bottom_hint_for(comment, is_root)
	end

	local provider = detail.provider
	local comments_capability = provider and provider.capabilities.comments
	local reaction_options = comments_capability and comments_capability.reaction_options
	local box_lines, box_highlights, region = comment_box.render({
		comment = comment,
		depth = depth,
		padding_x = PADDING_X,
		width = width,
		reaction_options = reaction_options,
		border_hl = border_hl,
		bottom_hint = bottom_hint,
		bottom_hint_highlights = bottom_hint_highlights,
		extra_content_lines = extra_lines,
		extra_content_highlights = extra_highlights,
	})

	local base = #lines
	state.regions[id] = { row = base + region.row, col = region.col, width = region.width, height = region.height }

	for _, line in ipairs(box_lines) do
		table.insert(lines, line)
	end
	for _, span in ipairs(box_highlights) do
		table.insert(spans, {
			line = base + span.line,
			start_col = span.start_col,
			end_col = span.end_col,
			hl_group = span.hl_group,
		})
	end
	for i = 1, #box_lines do
		line_map[base + i] = {
			kind = depth > 0 and "thread_content" or "content",
			comment = comment,
			entity_kind = "comment",
			thread_root = root,
			thread_has_replies = has_children,
		}
	end

	if not collapsed then
		for _, child in ipairs(node.children) do
			render_comment_tree(child, root, depth + 1, width, lines, spans, line_map)
		end

		local composing = state.composing
		if composing and composing.parent and tostring(composing.parent.id) == tostring(comment.id) then
			append_connector(lines, spans, PADDING_X + (depth + 1) * 2)
			render_composing_box(width, depth + 1, lines, spans)
		end
	end
end

---@param lines string[]
---@param spans table[]
---@param line_map table<integer, table>
---@param nodes AtlasReviewThreadNode[]
---@param width integer
local function emit_thread_box(lines, spans, line_map, nodes, width)
	for _, node in ipairs(nodes) do
		if #lines > 0 then
			append_connector(lines, spans, PADDING_X)
		end
		render_comment_tree(node, node.comment, 0, width, lines, spans, line_map)
	end
end

---@class CommentsHunkBucket
---@field hunk DiffHunk
---@field threads_by_anchor table<string, { threads: AtlasReviewThreadNode[] }>

---@class CommentsFileBucket
---@field path string
---@field threads AtlasReviewThreadNode[]
---@field hunks table<string, CommentsHunkBucket>
---@field hunk_order string[]

---@param hunk DiffHunk
---@return string
local function hunk_key(hunk)
	return string.format("%s|%s", tostring(hunk.new_start or 0), tostring(hunk.old_start or 0))
end

---@param width integer
---@param file_path string
---@param file_threads AtlasReviewThreadNode[]
---@param buckets CommentsHunkBucket[]
---@return string[] lines
---@return table[] spans
---@return table<integer, table> line_map
local function render_file_body(width, file_path, file_threads, buckets)
	local lines, spans, line_map = {}, {}, {}

	local file = { path = file_path, status = "modified", hunks = {} }
	local buckets_by_key = {}
	for _, bucket in ipairs(buckets) do
		table.insert(file.hunks, bucket.hunk)
		buckets_by_key[diff.hunk_key(file, bucket.hunk)] = bucket
	end

	local cb_lines, cb_spans, cb_map = diff.hunks({ file }, {
		max_width = width,
		padding_x = PADDING_X,
		show_line_numbers = false,
		show_file_header = false,
	})

	---@type table<integer, table[]>
	local spans_by_cb_line = {}
	for _, s in ipairs(cb_spans) do
		local list = spans_by_cb_line[s.line]
		if list == nil then
			list = {}
			spans_by_cb_line[s.line] = list
		end
		table.insert(list, s)
	end

	local current_bucket
	for i, text in ipairs(cb_lines) do
		table.insert(lines, text)
		local out_line = #lines - 1
		for _, s in ipairs(spans_by_cb_line[i - 1] or {}) do
			s.line = out_line
			table.insert(spans, s)
		end
		local entry = cb_map and cb_map[i] or nil
		if entry then
			line_map[#lines] = entry
		end

		if entry and entry.hunk_start then
			current_bucket = buckets_by_key[entry.hunk_key]
		end
		if entry and entry.kind == "hunk_line" and entry.path == file_path and entry.line ~= nil then
			local anchor_key = string.format("%s:%s", entry.side or "new", tostring(entry.line))
			local anchor = current_bucket and current_bucket.threads_by_anchor[anchor_key]
			if anchor then
				entry.thread_roots = {}
				for _, thread in ipairs(anchor.threads) do
					table.insert(entry.thread_roots, thread.comment)
				end
				emit_thread_box(lines, spans, line_map, anchor.threads, width)
				current_bucket.threads_by_anchor[anchor_key] = nil
			end
		end
		if i == 1 and #file_threads > 0 then
			emit_thread_box(lines, spans, line_map, file_threads, width)
			if #file.hunks > 0 then
				table.insert(lines, "")
			end
		end
	end

	for _, bucket in ipairs(buckets) do
		for _, anchor in pairs(bucket.threads_by_anchor) do
			emit_thread_box(lines, spans, line_map, anchor.threads, width)
		end
	end

	return lines, spans, line_map
end

--- Wraps a file's diff hunks + inline comment boxes in one outer bordered
--- box, titled with the file path -- 80% width like every comment box
--- (`comment_box.box_width`), and active/inactive styled the same way too:
--- blue border + a "[za] - Toggle" hint while this block is the active
--- navigable entry, grey (`AtlasFieldBoxBorder`) otherwise. "Toggle"
--- collapses the whole block down to just its title bar.
---@param lines string[]
---@param spans table[]
---@param line_map table<integer, table>
---@param width integer
---@param file_path string
---@param file_threads AtlasReviewThreadNode[]
---@param buckets CommentsHunkBucket[]
local function emit_file_with_comments(lines, spans, line_map, width, file_path, file_threads, buckets)
	local block_id = "block:" .. file_path
	table.insert(state.navigable, { id = block_id, kind = "block", path = file_path })

	local is_active = state.active_id == block_id
	local border_hl = is_active and "AtlasFieldBoxBorderEditable" or "AtlasFieldBoxBorder"
	local bottom_hint, bottom_hint_highlights
	if is_active then
		bottom_hint, bottom_hint_highlights =
			comment_box.build_hint({ { action_id = "ui.toggle_fold", label = "Toggle", hl = "AtlasFooterInfo" } })
	end

	local available = math.max(1, width - PADDING_X)
	local box_width = comment_box.box_width(available)
	local body_lines, body_spans, body_line_map = {}, {}, {}
	if not state.is_file_collapsed(file_path) then
		local interior_width = math.max(1, box_width - 2)
		body_lines, body_spans, body_line_map = render_file_body(interior_width, file_path, file_threads, buckets)
	end

	local box_lines, box_highlights = bordered_box.render({
		width = box_width,
		box_width = box_width,
		title = file_path,
		content_lines = body_lines,
		content_highlights = body_spans,
		border_hl = border_hl,
		bottom_hint = bottom_hint,
		bottom_hint_highlights = bottom_hint_highlights,
	})

	-- Left-indent the whole block by PADDING_X, matching the comment boxes'
	-- own left margin.
	local pad = string.rep(" ", PADDING_X)
	for i, line in ipairs(box_lines) do
		box_lines[i] = pad .. line
	end
	for _, span in ipairs(box_highlights) do
		span.start_col = span.start_col + PADDING_X
		span.end_col = span.end_col + PADDING_X
	end

	local base = #lines
	state.regions[block_id] = { row = base, col = 1 + PADDING_X, width = box_width - 2, height = 1 }

	for _, line in ipairs(box_lines) do
		table.insert(lines, line)
	end
	for _, span in ipairs(box_highlights) do
		table.insert(spans, {
			line = base + span.line,
			start_col = span.start_col,
			end_col = span.end_col,
			hl_group = span.hl_group,
		})
	end
	-- +1 for the box's own top border row.
	for lnum, entry in pairs(body_line_map) do
		line_map[base + 1 + lnum] = entry
	end
end

---@param width integer
---@param comments PullsComment[]|"loading"|string|nil
---@param tasks PullsComment[]|"loading"|string|nil
---@param hunks_by_comment table<string, { hunk: DiffHunk, anchor: integer }>|nil
---@return string[], table[], table<integer, table>
function M.render(width, comments, tasks, hunks_by_comment)
	local lines = {}
	local spans = {}
	local line_map = {}
	local max_width = math.max(1, width)
	hunks_by_comment = hunks_by_comment or {}
	state.navigable = {}
	state.regions = {}

	if tasks == "loading" then
		utils.push(lines, spans, spinner.with_text("Loading tasks..."), "AtlasTextMuted", PADDING_X)
		table.insert(lines, "")
	elseif type(tasks) == "string" then
		utils.push(lines, spans, tasks, "AtlasLogError", PADDING_X)
		table.insert(lines, "")
	elseif type(tasks) == "table" and #tasks > 0 then
		---@cast tasks PullsComment[]
		local sorted_tasks = vim.list_extend({}, tasks)
		table.sort(sorted_tasks, function(left, right)
			local left_date = tostring(left.created_on or "")
			local right_date = tostring(right.created_on or "")
			return left_date == right_date and tostring(left.id) < tostring(right.id) or left_date < right_date
		end)
		utils.push(lines, spans, task_heading(sorted_tasks), "AtlasColumnHeader", PADDING_X)
		for _, task in ipairs(sorted_tasks) do
			emit_task(lines, spans, line_map, task, max_width)
		end
		table.insert(lines, "")
	end

	if comments == nil then
		return lines, spans, line_map
	end

	if comments == "loading" then
		utils.push(lines, spans, spinner.with_text("Loading comments..."), "AtlasTextMuted", PADDING_X)
		return lines, spans, line_map
	end

	if type(comments) == "string" then
		utils.push(lines, spans, comments, "AtlasLogError", PADDING_X)
		return lines, spans, line_map
	end

	---@cast comments PullsComment[]
	if #comments == 0 then
		utils.push(lines, spans, "No comments yet.", "AtlasTextMuted", PADDING_X)
		return lines, spans, line_map
	end

	local roots = review_threads.group_comments(comments, type(tasks) == "table" and tasks or nil)

	local general_roots = {}
	---@type table<string, CommentsFileBucket>
	local file_buckets = {}
	---@type string[]
	local file_order = {}

	for _, thread in ipairs(roots) do
		local c = thread.comment
		local path = c.file and c.file.path or (c.inline and c.inline.path)
		local context = hunks_by_comment[tostring(c.id)]
		if path then
			local file = file_buckets[path]
			if file == nil then
				file = { path = path, threads = {}, hunks = {}, hunk_order = {} }
				file_buckets[path] = file
				table.insert(file_order, path)
			end
			if context == nil then
				table.insert(file.threads, thread)
			else
				local hkey = hunk_key(context.hunk)
				local hb = file.hunks[hkey]
				if hb == nil then
					hb = { hunk = context.hunk, threads_by_anchor = {} }
					file.hunks[hkey] = hb
					table.insert(file.hunk_order, hkey)
				end
				local side = c.inline.to ~= nil and "new" or "old"
				local akey = string.format("%s:%s", side, tostring(context.anchor))
				local anchor = hb.threads_by_anchor[akey]
				if anchor == nil then
					anchor = { threads = {} }
					hb.threads_by_anchor[akey] = anchor
				end
				table.insert(anchor.threads, thread)
			end
		else
			table.insert(general_roots, thread)
		end
	end

	if #general_roots > 0 then
		utils.push(lines, spans, "Conversation", "AtlasColumnHeader", PADDING_X)
		table.insert(lines, "")
		emit_thread_box(lines, spans, line_map, general_roots, max_width)
		table.insert(lines, "")
	end

	if #file_order > 0 then
		for _, path in ipairs(file_order) do
			local file = file_buckets[path]
			local buckets = {}
			for _, hkey in ipairs(file.hunk_order) do
				table.insert(buckets, file.hunks[hkey])
			end
			emit_file_with_comments(lines, spans, line_map, max_width, path, file.threads, buckets)
			table.insert(lines, "")
		end
	end

	return lines, spans, line_map
end

return M
