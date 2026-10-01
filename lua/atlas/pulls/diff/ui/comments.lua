-- Renders review-comment threads in the diff view -- both the always-visible
-- thread shown as `virt_lines` under a code line, and the `gK`/ambiguous-
-- cursor fallback popup -- using the same per-comment bordered box
-- (`atlas.pulls.ui.components.comment_box`) and bottom-border action hints as
-- the pull detail panel's Activity/Review tabs, so a review comment looks and
-- behaves the same wherever it's shown. The two hosts differ only in how a
-- rendered box's geometry gets turned into inline-edit-overlay coordinates:
-- the popup is a real buffer/window (a plain row/col region, like the
-- Activity tab), while the inline virt_lines block has no addressable buffer
-- line, so its geometry is resolved through
-- `atlas.pulls.diff.ui.virt_line_anchor` instead. See `render_thread_list`.
local M = {}

local comment_box = require("atlas.pulls.ui.components.comment_box")
local inline_field_edit = require("atlas.ui.inline_field_edit")
local keymaps = require("atlas.core.keymaps")
local review_threads = require("atlas.pulls.ui.components.review_threads")
local statusline = require("atlas.ui.statusline")
local virtual_lines = require("atlas.ui.components.virtual_lines")

---@param win integer
---@param region AtlasFieldBoxRegion
---@param seed_text string
---@param on_save fun(text: string, done: fun(ok: boolean, err: string|nil))
---@param on_done fun()
local function inline_field_edit_start(win, region, seed_text, on_save, on_done)
	pcall(vim.api.nvim_win_set_cursor, win, { region.row + 1, 0 })
	inline_field_edit.start({
		anchor_win = win,
		row = region.row,
		col = region.col,
		width = region.width,
		height = region.height,
		seed_text = seed_text,
		on_save = on_save,
		on_cancel = function() end,
		on_done = on_done,
	})
end

local namespace = vim.api.nvim_create_namespace("atlas_diff_comments")
local popup_namespace = vim.api.nvim_create_namespace("atlas_diff_thread_popup")
local popup = { buf = nil, win = nil, owner = nil, editing_id = nil, composing = nil, nodes = nil, context = nil }

---@class AtlasCommentRendererContext
---@field threads AtlasReviewThreadNode[]
---@field expanded_threads table<string, boolean>
---@field old_path string
---@field new_path string
---@field reaction_options PullsReactionOption[]|nil
---@field comments_capability table|nil
---@field current_user PullsUser|nil
---@field reviewable boolean
---@field active_keys table<string, boolean>|nil `review_threads.comment_key`s of the root comment(s) at the current cursor position -- drives the "active" blue border + visible hints, mirroring the Activity tab's `state.active_id`. Only meaningful for the inline (virt_lines) path; the popup has no cursor-driven "active" concept of its own.
---@field session AtlasDiffSession|nil Only set for the inline (virt_lines) rendering path -- lets `M.thread_lines` read/write session-scoped editing/composing/region state. The popup keeps its own local state instead (see `popup` above) since it isn't tied to any one buffer line.

---@param buf integer
---@return integer
local function buffer_width(buf)
	local wins = vim.fn.win_findbuf(buf)
	return wins[1] and vim.api.nvim_win_get_width(wins[1]) or vim.o.columns
end

---@param current_user PullsUser|nil
---@param comment PullsComment
---@return boolean
local function is_own_comment(current_user, comment)
	if not current_user or not comment or not comment.author then
		return false
	end
	return tostring(current_user.id) == tostring(comment.author.id)
end

---@param context AtlasCommentRendererContext
---@param comment PullsComment
---@param is_root boolean
---@return string|nil text
---@return table[]|nil highlights
local function bottom_hint_for(context, comment, is_root)
	local capability = context.comments_capability
	if not capability or not context.reviewable then
		return nil, nil
	end
	local segments = {}
	if capability.add_comment then
		table.insert(segments, { action_id = "pulls.review.diff.add_comment", label = "Reply", hl = "AtlasFooterInfo" })
	end
	local own = is_own_comment(context.current_user, comment)
	if own and capability.edit_comment then
		table.insert(segments, { action_id = "ui.comments.edit", label = "Edit", hl = "AtlasFooterWarning" })
	end
	if own and capability.delete_comment then
		table.insert(segments, { action_id = "ui.delete", label = "Delete", hl = "AtlasFooterError" })
	end
	if is_root and capability.set_thread_resolved then
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

---@param node AtlasReviewThreadNode
---@return integer
local function descendant_count(node)
	local count = #node.children
	for _, child in ipairs(node.children) do
		count = count + descendant_count(child)
	end
	return count
end

---@class AtlasThreadListWalkOpts
---@field anchor_line integer|nil Real code-buffer line the rendered block will be attached to via `virt_lines` -- when set, `regions` entries are recorded in the `{anchor_line, above, block_row}` shape `virt_line_anchor.screen_row` expects. Left nil for the popup (a real buffer): entries there use a plain `{row, col, width, height}` shape instead.
---@field above boolean|nil
---@field regions table<string, table>|nil Filled with each rendered comment's geometry, keyed by `review_threads.comment_key`.
---@field line_map table<integer, table>|nil Filled with `{comment = ..., thread_root = ...}` per 1-indexed output line -- only meaningful for the popup's cursor-driven delete/toggle.
---@field editing_id string|nil `review_threads.comment_key` of the comment to render with the "editing" border + Save/Cancel hint instead of its normal one.
---@field composing { kind: "add"|"reply", parent: PullsComment|nil }|nil A pending composing box: "reply" renders it under the matching parent's node; "add" appends it after the whole list (a brand-new top-level thread).

---@param context AtlasCommentRendererContext
---@param width integer
---@param list AtlasReviewThreadNode[]
---@param opts AtlasThreadListWalkOpts
---@return string[] lines
---@return table[] spans
local function render_thread_list(context, width, list, opts)
	local lines, spans = {}, {}

	local function append_connector()
		if #lines > 0 then
			local line = "│"
			table.insert(lines, line)
			table.insert(spans, { line = #lines - 1, start_col = 0, end_col = #line, hl_group = "AtlasTextMuted" })
		end
	end

	---@param key string
	---@param base integer
	---@param region AtlasFieldBoxRegion
	local function record_region(key, base, region)
		if not opts.regions then
			return
		end
		if opts.anchor_line then
			opts.regions[key] = {
				anchor_line = opts.anchor_line,
				above = opts.above == true,
				block_row = base + region.row,
				col = region.col,
				width = region.width,
				height = region.height,
			}
		else
			opts.regions[key] = { row = base + region.row, col = region.col, width = region.width, height = region.height }
		end
	end

	local function render_composing(depth, root)
		local bottom_hint, bottom_hint_highlights = editing_hint()
		local box_lines, box_highlights, region = comment_box.render_composing({
			title = "New Comment",
			depth = depth,
			padding_x = 1,
			width = width,
			full_width = true,
			bottom_hint = bottom_hint,
			bottom_hint_highlights = bottom_hint_highlights,
		})
		local base = #lines
		record_region(root and ("composing:" .. review_threads.comment_key(root)) or "composing", base, region)
		for _, l in ipairs(box_lines) do
			table.insert(lines, l)
		end
		for _, s in ipairs(box_highlights) do
			table.insert(spans, { line = base + s.line, start_col = s.start_col, end_col = s.end_col, hl_group = s.hl_group })
		end
	end

	local function render_node(node, depth, root)
		local comment = node.comment
		root = root or comment
		append_connector()

		if comment.is_task then
			local base = #lines
			local task_lines, task_spans = review_threads.render_task_compact(node, width, {
				padding_x = 1,
				reaction_options = context.reaction_options,
			})
			for _, l in ipairs(task_lines) do
				table.insert(lines, l)
			end
			for _, s in ipairs(task_spans) do
				table.insert(spans, { line = base + s.line, start_col = s.start_col, end_col = s.end_col, hl_group = s.hl_group })
			end
			if opts.line_map then
				for i = 1, #task_lines do
					opts.line_map[base + i] = { comment = comment, thread_root = comment }
				end
			end
			return
		end

		local is_root = depth == 0
		local key = review_threads.comment_key(comment)
		local collapsed = is_root
			and #node.children > 0
			and not review_threads.is_thread_expanded(comment, context.expanded_threads)

		-- "Active" only ever applies to the root box: the cursor sits on a
		-- real code line, not on any one reply inside the thread, so that's
		-- the only granularity available here (interacting with a specific
		-- reply stays popup-only -- see the module doc).
		local is_editing = opts.editing_id == key
		local is_active = is_root and not is_editing and context.active_keys and context.active_keys[key] == true
		local border_hl = is_editing and "AtlasFieldBoxBorderEditing"
			or (is_active and "AtlasFieldBoxBorderEditable")
			or "AtlasFieldBoxBorder"
		local bottom_hint, bottom_hint_highlights
		if is_editing then
			bottom_hint, bottom_hint_highlights = editing_hint()
		elseif is_active then
			bottom_hint, bottom_hint_highlights = bottom_hint_for(context, comment, is_root)
		end
		local status_text, status_highlights
		if is_root then
			status_text, status_highlights = review_threads.status_line(comment)
		end

		local extra_lines, extra_highlights
		if collapsed then
			local count = descendant_count(node)
			local text = string.format("%d %s (za to expand)", count, count == 1 and "reply" or "replies")
			extra_lines = { text }
			extra_highlights = { { line = 0, start_col = 0, end_col = #text, hl_group = "AtlasLogInfo" } }
		end

		local box_lines, box_highlights, region = comment_box.render({
			comment = comment,
			depth = depth,
			padding_x = 1,
			width = width,
			full_width = true,
			reaction_options = context.reaction_options,
			border_hl = border_hl,
			bottom_hint = bottom_hint,
			bottom_hint_highlights = bottom_hint_highlights,
			status_text = status_text,
			status_highlights = status_highlights,
			extra_content_lines = extra_lines,
			extra_content_highlights = extra_highlights,
		})

		local base = #lines
		record_region(key, base, region)
		for _, l in ipairs(box_lines) do
			table.insert(lines, l)
		end
		for _, s in ipairs(box_highlights) do
			table.insert(spans, { line = base + s.line, start_col = s.start_col, end_col = s.end_col, hl_group = s.hl_group })
		end
		if opts.line_map then
			for i = 1, #box_lines do
				opts.line_map[base + i] = { comment = comment, thread_root = root }
			end
		end

		if not collapsed then
			for _, child in ipairs(node.children) do
				render_node(child, depth + 1, root)
			end
			local composing = opts.composing
			if composing and composing.kind == "reply" and composing.parent and tostring(composing.parent.id) == tostring(comment.id) then
				append_connector()
				render_composing(depth + 1, composing.parent)
			end
		end
	end

	for _, node in ipairs(list) do
		render_node(node, 0)
	end

	if opts.composing and opts.composing.kind == "add" then
		append_connector()
		render_composing(0, nil)
	end

	return lines, spans
end

---@param context AtlasCommentRendererContext
---@param buf integer
---@param list AtlasReviewThreadNode[]
---@param anchor_line integer|nil
---@param above boolean|nil
---@return [string, string][][]
function M.thread_lines(context, buf, list, anchor_line, above)
	local width = buffer_width(buf)
	local session = context.session
	local composing = session and session.diff_composing
	local matches_composing = composing
		and composing.buf == buf
		and composing.line == anchor_line
		and (composing.above == true) == (above == true)
	local lines, spans = render_thread_list(context, width, list, {
		anchor_line = anchor_line,
		above = above,
		regions = session and session.diff_regions,
		editing_id = session and session.diff_editing_id,
		composing = matches_composing and composing or nil,
	})
	return virtual_lines.render(lines, spans)
end

---@param context AtlasCommentRendererContext
---@param buf integer
---@param by_line table<integer, AtlasReviewThreadNode[]>
---@param above_lines table<integer, boolean>
---@return table<integer, integer>
function M.render_comments(context, buf, by_line, above_lines)
	if not vim.api.nvim_buf_is_valid(buf) then
		return {}
	end
	vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)

	local session = context.session
	local composing = session and session.diff_composing
	if composing and composing.kind == "add" and composing.buf == buf and by_line[composing.line] == nil then
		by_line = vim.tbl_extend("force", {}, by_line)
		above_lines = vim.tbl_extend("force", {}, above_lines)
		by_line[composing.line] = {}
		above_lines[composing.line] = composing.above == true
	end

	local sizes = {}
	local line_count = vim.api.nvim_buf_line_count(buf)
	for line, list in pairs(by_line) do
		if line >= 1 and line <= line_count then
			local marked = {}
			for _, node in ipairs(list) do
				local inline = node.comment.inline
				local start_line = inline and (inline.to and inline.start_to or inline.start_from)
				for range_line = start_line or line, line - 1 do
					if range_line >= 1 and not marked[range_line] then
						marked[range_line] = true
						vim.api.nvim_buf_set_extmark(buf, namespace, range_line - 1, 0, {
							number_hl_group = "CursorLineNr",
							sign_text = "┃",
							sign_hl_group = "AtlasLogInfo",
							priority = 1100,
						})
					end
				end
			end
			local above = above_lines[line] == true
			local rendered_lines = M.thread_lines(context, buf, list, line, above)
			sizes[line] = #rendered_lines
			vim.api.nvim_buf_set_extmark(buf, namespace, line - 1, 0, {
				virt_lines = rendered_lines,
				virt_lines_above = above,
				virt_lines_leftcol = true,
				number_hl_group = "CursorLineNr",
				sign_text = "┃",
				sign_hl_group = "AtlasLogInfo",
				priority = 1100,
			})
		end
	end
	return sizes
end

---@param context AtlasCommentRendererContext
---@param buf integer
---@param list AtlasReviewThreadNode[]
---@return integer
function M.render_file_comments(context, buf, list)
	if #list == 0 or not vim.api.nvim_buf_is_valid(buf) then
		return 0
	end
	local rendered_lines = M.thread_lines(context, buf, list, 1, true)
	vim.api.nvim_buf_set_extmark(buf, namespace, 0, 0, {
		virt_lines = rendered_lines,
		virt_lines_above = true,
		virt_lines_leftcol = true,
		priority = 1100,
	})
	-- Reveal virtual lines placed above the first buffer line.
	vim.schedule(function()
		for _, win in ipairs(vim.fn.win_findbuf(buf)) do
			local view = vim.api.nvim_win_call(win, vim.fn.winsaveview)
			if view.topline == 1 then
				view.topfill = #rendered_lines
				vim.api.nvim_win_call(win, function()
					vim.fn.winrestview(view)
				end)
			end
		end
	end)
	return #rendered_lines
end

---@param buf integer
---@param line integer
---@param count integer
---@param above boolean
function M.pad(buf, line, count, above)
	if count <= 0 then
		return
	end
	local padding_lines = {}
	for _ = 1, count do
		padding_lines[#padding_lines + 1] = { { "", "Normal" } }
	end
	vim.api.nvim_buf_set_extmark(buf, namespace, line - 1, 0, {
		virt_lines = padding_lines,
		virt_lines_above = above,
		virt_lines_leftcol = true,
		priority = 1090,
	})
end

---@param current AtlasDiffCurrent
function M.clear(current)
	for _, side in ipairs({ current.left, current.right }) do
		if vim.api.nvim_buf_is_valid(side.buf) then
			vim.api.nvim_buf_clear_namespace(side.buf, namespace, 0, -1)
		end
	end
end

---@param owner string|nil
function M.close_popup(owner)
	if owner and popup.owner ~= owner then
		return
	end
	local win, buf = popup.win, popup.buf
	popup = { buf = nil, win = nil, owner = nil, editing_id = nil, composing = nil, nodes = nil, context = nil }
	if win and vim.api.nvim_win_is_valid(win) then
		vim.api.nvim_win_close(win, true)
	end
	if buf and vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_delete(buf, { force = true })
	end
end

---@param owner string
---@return boolean
function M.popup_is_open(owner)
	return popup.owner == owner and popup.win ~= nil and vim.api.nvim_win_is_valid(popup.win)
end

---@class AtlasDiffThreadPopupOptions
---@field nodes AtlasReviewThreadNode[]
---@field owner string
---@field title string|nil
---@field context AtlasCommentRendererContext
---@field on_action fun(action: AtlasReviewThreadAction, comment: PullsComment, close: fun())
---@field on_reply fun(parent: PullsComment, text: string, done: fun(ok: boolean, err: string|nil))
---@field on_edit fun(comment: PullsComment, text: string, done: fun(ok: boolean, err: string|nil))

---@type { buf: integer, win: integer, opts: AtlasDiffThreadPopupOptions, line_map: table<integer, table> }|nil
local popup_render_state = nil

---@param opts AtlasDiffThreadPopupOptions
local function refresh_popup(opts)
	local width = math.min(100, math.max(1, vim.o.columns - 4))
	local line_map = {}
	local lines, spans = render_thread_list(opts.context, math.max(1, width - 2), opts.nodes, {
		regions = nil,
		line_map = line_map,
		editing_id = popup.editing_id,
		composing = popup.composing,
	})
	if #lines == 0 then
		lines = { "No comments." }
	end
	local buf = popup.buf
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_clear_namespace(buf, popup_namespace, 0, -1)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	for _, span in ipairs(spans) do
		vim.api.nvim_buf_set_extmark(buf, popup_namespace, span.line, span.start_col, {
			end_col = span.end_col,
			hl_group = span.hl_group,
		})
	end
	vim.bo[buf].modifiable = false
	popup_render_state = { buf = buf, win = popup.win, opts = opts, line_map = line_map }
end

---@param opts AtlasDiffThreadPopupOptions
function M.open_popup(opts)
	M.close_popup()
	local source_win = vim.api.nvim_get_current_win()
	local width = math.min(100, math.max(1, vim.o.columns - 4))
	local height = math.min(math.max(1, vim.o.lines - 6), math.max(10, vim.o.lines - 10))

	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = "atlas.review-thread"
	vim.bo[buf].syntax = "OFF"
	pcall(vim.treesitter.stop, buf)

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
		col = math.max(0, math.floor((vim.o.columns - width) / 2)),
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = opts.title or " Review thread ",
		title_pos = "center",
		zindex = 40,
	})
	vim.wo[win].cursorline = true
	vim.wo[win].wrap = false
	statusline.inherit(win, source_win)
	popup = { buf = buf, win = win, owner = opts.owner, editing_id = nil, composing = nil, nodes = opts.nodes, context = opts.context }

	refresh_popup(opts)

	local function close()
		M.close_popup(opts.owner)
	end

	---@return table|nil
	local function entry_at_cursor()
		if not vim.api.nvim_win_is_valid(win) then
			return nil
		end
		local lnum = vim.api.nvim_win_get_cursor(win)[1]
		return popup_render_state and popup_render_state.line_map[lnum]
	end

	local function refresh()
		refresh_popup(opts)
	end

	-- The popup's `regions` bookkeeping (unlike the inline virt_lines path,
	-- which persists it on `session.diff_regions` across renders) is only
	-- ever needed immediately after a `refresh()` -- rebuilding it with a
	-- second, region-collecting pass right here is cheaper than threading a
	-- persistent table through `refresh_popup`.
	---@return table<string, table>
	local function current_regions()
		local regions = {}
		render_thread_list(opts.context, math.max(1, vim.api.nvim_win_get_width(win) - 2), opts.nodes, {
			regions = regions,
			editing_id = popup.editing_id,
			composing = popup.composing,
		})
		return regions
	end

	local function start_reply()
		local entry = entry_at_cursor()
		if not entry or not entry.comment or entry.comment.is_task then
			return
		end
		local parent = entry.thread_root or entry.comment
		popup.composing = { kind = "reply", parent = parent }
		refresh()
		local region = current_regions()["composing:" .. review_threads.comment_key(parent)]
		if not region then
			popup.composing = nil
			refresh()
			return
		end
		-- `on_done` fires on both success and cancel with no way to tell them
		-- apart directly -- track it here so a successful reply closes the
		-- whole popup (`opts.nodes` is a point-in-time snapshot from when the
		-- popup opened, so refreshing it in place would show stale data;
		-- matches the pre-redesign behavior of closing after the old
		-- editor-popup reply flow completed) while a cancel just drops the
		-- composing box and stays open.
		local succeeded = false
		inline_field_edit_start(win, region, "", function(text, done)
			opts.on_reply(parent, text, function(ok, err)
				succeeded = ok == true
				done(ok, err)
			end)
		end, function()
			popup.composing = nil
			if succeeded then
				close()
			else
				refresh()
			end
		end)
	end

	local function start_edit()
		local entry = entry_at_cursor()
		if not entry or not entry.comment or entry.comment.is_task then
			return
		end
		local key = review_threads.comment_key(entry.comment)
		popup.editing_id = key
		refresh()
		local region = current_regions()[key]
		if not region then
			popup.editing_id = nil
			refresh()
			return
		end
		-- Same "close on success, refresh in place on cancel" reasoning as
		-- `start_reply` above -- `opts.nodes` is a snapshot and won't reflect
		-- the provider's updated comment.
		local succeeded = false
		inline_field_edit_start(win, region, tostring(entry.comment.content_raw or ""), function(text, done)
			opts.on_edit(entry.comment, text, function(ok, err)
				succeeded = ok == true
				done(ok, err)
			end)
		end, function()
			popup.editing_id = nil
			if succeeded then
				close()
			else
				refresh()
			end
		end)
	end

	local function action(name)
		return function()
			local entry = entry_at_cursor()
			if entry and entry.comment then
				opts.on_action(name, entry.comment, close)
			end
		end
	end

	local map_opts = { buffer = buf, nowait = true, silent = true }
	local function map(action_id, callback)
		for _, key in ipairs(keymaps.resolve(action_id) or {}) do
			vim.keymap.set("n", key, callback, map_opts)
		end
	end
	map("ui.close", close)
	vim.keymap.set("n", "<Esc>", close, map_opts)
	map("pulls.review.diff.add_comment", start_reply)
	map("ui.comments.edit", start_edit)
	map("ui.delete", action("delete"))
	map("pulls.review.diff.toggle_resolved", function()
		local entry = entry_at_cursor()
		if not entry or not entry.comment then
			return
		end
		local name = entry.comment.is_task and "toggle_task" or "toggle_resolved"
		local target = name == "toggle_resolved" and entry.thread_root or entry.comment
		opts.on_action(name, target, close)
	end)
	vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(win),
		once = true,
		callback = function()
			if popup.win == win then
				popup = { buf = nil, win = nil, owner = nil, editing_id = nil, composing = nil, nodes = nil, context = nil }
				popup_render_state = nil
			end
		end,
	})
end

return M
