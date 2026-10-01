local M = {}

local comments = require("atlas.pulls.diff.comments")
local config = require("atlas.config")
local keymaps = require("atlas.core.keymaps")
local notify = require("atlas.core.notify")
local hints = require("atlas.pulls.diff.ui.hints")
local position = require("atlas.pulls.diff.position")
local review_keymaps = require("atlas.pulls.diff.keymaps")
local review_panel = require("atlas.pulls.diff.ui.review_panel")
local session_api = require("atlas.pulls.diff.session")
local ui_comments = require("atlas.pulls.diff.ui.comments")
local adapter_helpers = require("atlas.pulls.diff.adapter_helpers")

-- `diff1_inline` (a single-pane unified-diff layout some Diffview forks/
-- configs add alongside the stock `diff2_*`/`diff1_plain` set) has no
-- real old-side window or buffer at all: the old content is rendered as
-- `inline_diff`'s own virt_lines directly inside the new-side buffer. Atlas's
-- `AtlasDiffWindow` shape wants a `buf` either way, so `current.left` gets
-- this sentinel instead of a real handle -- always invalid, so every
-- existing `vim.api.nvim_buf_is_valid(side.buf)` guard (clear/hints/etc.)
-- already treats it as "nothing there," and `placed.left` is never
-- populated for a non-"side-by-side" layout, so it's never dereferenced.
local NO_LEFT_BUFFER = -1

--- Lazy, defensive: only forks/configs that actually ship the `diff1_inline`
--- layout have this module at all (stock diffview.nvim doesn't), so this
--- must never be a top-level `require` -- that would break the whole
--- integration (even plain side-by-side) for anyone without it.
---@return table|nil
local function get_inline_diff()
	local ok, mod = pcall(require, "diffview.scene.inline_diff")
	return ok and mod or nil
end

---@type table<string, DiffFileStatus>
local FILE_STATUSES = {
	["?"] = "added",
	A = "added",
	C = "renamed",
	D = "deleted",
	M = "modified",
	R = "renamed",
	T = "type_changed",
}

---@class AtlasDiffviewState
---@field view table
---@field group integer
---@field sync_scheduled boolean
---@field suspended boolean
---@field auto_open_panel boolean
---@field pending_jump { path: string, comment: PullsComment|nil, focus_diff: boolean }|nil
---@field additions integer
---@field deletions integer
---@field closed boolean
---@field reloading boolean
---@field reload_view (fun())|nil

---@param value string|nil
---@return string
local function clean_path(value)
	local path = tostring(value or "")
	return (path:gsub("\\", "/"):gsub("^%./", ""):gsub("/+$", ""))
end

---@param root string
---@param path string|nil
---@return string
local function relative_path(root, path)
	path = clean_path(path)
	root = clean_path(root)
	local prefix = root ~= "" and root .. "/" or ""
	if prefix ~= "" and path:sub(1, #prefix) == prefix then
		return path:sub(#prefix + 1)
	end
	return path
end

---@param window table
---@return string[]
local function buffer_lines(window)
	if window.file.nulled or window.file.binary then
		return {}
	end
	return vim.api.nvim_buf_get_lines(window.file.bufnr, 0, -1, false)
end

---@param lines string[]
---@return string
local function content(lines)
	return #lines == 0 and "" or table.concat(lines, "\n") .. "\n"
end

---@param old_lines string[]
---@param new_lines string[]
---@return AtlasDiffLineChange[]
local function line_changes(old_lines, new_lines)
	local result = {}
	local changes = vim.diff(content(old_lines), content(new_lines), {
		algorithm = "histogram",
		result_type = "indices",
	})
	for _, change in ipairs(changes) do
		local old_start, old_count, new_start, new_count = unpack(change)
		result[#result + 1] = {
			old_start = old_start,
			old_count = old_count,
			new_start = new_start,
			new_count = new_count,
		}
	end
	return result
end

---@param session AtlasDiffSession
---@param focus boolean
---@return boolean opened
local function open_review_panel(session, focus)
	local state = session.viewer_state --[[@as AtlasDiffviewState]]
	if state.closed then
		return false
	end
	local layout = state.view and state.view.cur_layout or nil
	local anchor = layout and layout.b and layout.b.id or nil
	if not anchor or not vim.api.nvim_win_is_valid(anchor) then
		anchor = layout and layout.a and layout.a.id or nil
	end
	if not anchor or not session.review_panel then
		return false
	end
	local win = review_panel.open(session.review_panel, anchor, focus)
	if win then
		session.statusline:attach(win)
	end
	return win ~= nil
end

---@param session AtlasDiffSession
---@param focus boolean|nil
local function toggle_review_panel(session, focus)
	local panel = session.review_panel
	if not panel then
		return
	end
	if panel.win and vim.api.nvim_win_is_valid(panel.win) then
		review_panel.close(panel)
		return
	end
	open_review_panel(session, focus ~= false)
end

---@param session AtlasDiffSession
local function finish_pending_jump(session)
	local state = session.viewer_state --[[@as AtlasDiffviewState]]
	local pending = state.pending_jump
	local current = session.current
	local document = current and current.document or nil
	if
		not pending
		or not current
		or not document
		or (document.old.path ~= pending.path and document.new.path ~= pending.path)
	then
		return
	end
	state.pending_jump = nil

	local side, line = position.comment(document, pending.comment)

	local target = side == "LEFT" and current.left or current.right
	if side == "LEFT" and current.layout == "inline" and type(line) == "number" then
		-- No real old-side window to land in (see `NO_LEFT_BUFFER`) -- same
		-- remap the native `atlas` backend's own `focus_item` does for its
		-- inline layout.
		target = current.right
		line = position.opposite_line(document, "LEFT", line, vim.api.nvim_buf_line_count(current.right.buf))
	end
	if
		not side
		or not line
		or line < 1
		or ((not pending.comment or not pending.comment.file) and #(side == "LEFT" and document.old.lines or document.new.lines) == 0)
		or not target.win
		or not vim.api.nvim_win_is_valid(target.win)
	then
		session_api.notify(session, "info", "This review item's diff position is outdated")
		return
	end

	line = math.min(line, vim.api.nvim_buf_line_count(target.buf))
	vim.api.nvim_win_set_cursor(target.win, { line, 0 })
	vim.api.nvim_win_call(target.win, function()
		pcall(vim.cmd.normal, { args = { "zv" }, bang = true })
	end)
	if vim.api.nvim_get_current_tabpage() == session.tabpage then
		if pending.focus_diff then
			vim.api.nvim_set_current_win(target.win)
		elseif
			session.review_panel
			and session.review_panel.win
			and vim.api.nvim_win_is_valid(session.review_panel.win)
		then
			vim.api.nvim_set_current_win(session.review_panel.win)
		end
	end
end

---@param session AtlasDiffSession
local function reload_view(session)
	local state = session.viewer_state --[[@as AtlasDiffviewState]]
	if state.closed or state.reloading or not session.reload then
		return
	end
	local reload = session.reload
	local target = adapter_helpers.open_reload_target()
	state.reloading = true
	local ok, err = pcall(function()
		state.view:close()
		require("diffview.lib").dispose_view(state.view)
	end)
	if not ok then
		state.reloading = false
		vim.cmd("tabclose")
		session_api.notify(session, "error", "Unable to close Diffview: " .. tostring(err))
		return
	end
	M.detach(session, "reload")
	vim.schedule(function()
		reload(target)
	end)
end

---@param session AtlasDiffSession
local function register_review_buffers(session)
	local current = session.current
	if not current then
		return
	end
	local state = session.viewer_state --[[@as AtlasDiffviewState]]
	local candidates = { current.left.buf, current.right.buf }
	local diffview_panel_buf = state.view.panel and state.view.panel.bufid or nil
	if diffview_panel_buf then
		candidates[#candidates + 1] = diffview_panel_buf
	end
	local buffers, seen = {}, {}
	for _, buf in ipairs(candidates) do
		if buf and not seen[buf] and vim.api.nvim_buf_is_valid(buf) then
			seen[buf] = true
			buffers[#buffers + 1] = buf
		end
	end
	review_keymaps.register(session, {
		buffers = buffers,
		reload = state.reload_view,
		help_key = keymaps.resolve("pulls.external_help"),
		file_buffers = diffview_panel_buf and { diffview_panel_buf } or nil,
		add_file_comment = function(pending)
			local file = state.view:infer_cur_file()
			if file then
				comments.add_to_file(session, {
					path = relative_path(session.source.root, file.path),
					old_path = file.oldpath and relative_path(session.source.root, file.oldpath) or nil,
				}, pending)
			end
		end,
	})
	if session.review_panel then
		review_panel.register_toggle(session.review_panel, buffers)
	end
end

---@param session AtlasDiffSession
local function render_view(session)
	local state = session.viewer_state --[[@as AtlasDiffviewState]]
	if state.closed then
		return
	end
	local layout = state.view and state.view.cur_layout or nil
	if layout and layout.sync_scroll then
		pcall(layout.sync_scroll, layout)
	end
end

---@param session AtlasDiffSession
local function suspend(session)
	local state = session.viewer_state --[[@as AtlasDiffviewState]]
	if state.closed then
		return
	end
	if session.current then
		ui_comments.clear(session.current)
		hints.clear(session.current)
		session.current = nil
	end
	if not state.suspended then
		state.suspended = true
		session_api.notify(session, "warn", "Atlas review overlays require a two-pane Diffview layout")
	end
end

---@param session AtlasDiffSession
---@return boolean synced
local function sync(session)
	if
		session.closed
		or not session.tabpage
		or not vim.api.nvim_tabpage_is_valid(session.tabpage)
		or session_api.get(session.tabpage) ~= session
	then
		return false
	end
	local state = session.viewer_state --[[@as AtlasDiffviewState]]
	if state.closed then
		return false
	end
	local view = state.view
	local current = view.cur_entry
	local layout = view.cur_layout
	if not view.ready or not current or not layout then
		return false
	end
	local layout_name = tostring(layout.name or "")
	local is_side_by_side = layout_name:match("^diff2_") ~= nil
	local inline_diff = (not is_side_by_side and layout_name:match("^diff1_inline")) and get_inline_diff() or nil
	local is_inline = inline_diff ~= nil
	if not is_side_by_side and not is_inline then
		suspend(session)
		return false
	end

	state.additions, state.deletions = 0, 0
	for _, file in view.files:iter() do
		if file.stats then
			state.additions = state.additions + (file.stats.additions or 0)
			state.deletions = state.deletions + (file.stats.deletions or 0)
		end
	end

	local path = relative_path(session.source.root, current.path)
	local old_path = relative_path(session.source.root, current.oldpath)
	if old_path == "" then
		old_path = path
	end
	if path == "" then
		return false
	end
	local status = FILE_STATUSES[tostring(current.status or ""):sub(1, 1)] or "modified"

	local current_view, previous, buffers_changed
	if is_inline then
		if not layout.b or not layout.b:is_file_open() then
			return false
		end
		local bufnr = layout.b.file.bufnr
		if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
			return false
		end
		local new_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		-- No old-side buffer exists to read actual content from (see
		-- `NO_LEFT_BUFFER`), but nothing downstream needs more than its
		-- *length* for bounds-checking (`position.lua`, `threads_by_line`) --
		-- confirmed by grepping every `.old.lines`/`.new.lines` read in this
		-- module tree. `inline_diff.get_hunks` (public, cached per-buffer by
		-- the inline renderer) gives the hunks already in Atlas's own
		-- `{old_start, old_count, new_start, new_count}` shape; the old-side
		-- length falls out of the same hunks via the standard
		-- old = new - sum(new_count - old_count) identity.
		local hunks = inline_diff.get_hunks(bufnr) or {}
		local changes, old_count = {}, #new_lines
		for _, h in ipairs(hunks) do
			changes[#changes + 1] = { old_start = h[1], old_count = h[2], new_start = h[3], new_count = h[4] }
			old_count = old_count - h[4] + h[2]
		end
		local old_lines = {}
		for i = 1, math.max(0, old_count) do
			old_lines[i] = ""
		end
		local binary = (status ~= "added" and layout.b.file.binary == true)
			or (status ~= "deleted" and layout.a_file and layout.a_file.binary == true)
		previous = session.current
		buffers_changed = not previous or previous.left.buf ~= NO_LEFT_BUFFER or previous.right.buf ~= bufnr
		current_view = {
			layout = "inline",
			document = {
				status = status,
				old = { path = old_path, lines = old_lines },
				new = { path = path, lines = new_lines },
				changes = binary and {} or changes,
				binary = binary,
			},
			left = { buf = NO_LEFT_BUFFER, win = nil },
			right = { buf = bufnr, win = layout.b.id },
		}
		state.suspended = false
		session.statusline:attach(current_view.right.win)
	else
		if not layout.a:is_file_open() or not layout.b:is_file_open() then
			return false
		end
		local old_lines = buffer_lines(layout.a)
		local new_lines = buffer_lines(layout.b)
		local binary = (status ~= "added" and layout.a.file.binary == true)
			or (status ~= "deleted" and layout.b.file.binary == true)
		previous = session.current
		buffers_changed = not previous
			or previous.left.buf ~= layout.a.file.bufnr
			or previous.right.buf ~= layout.b.file.bufnr
		current_view = {
			layout = "side-by-side",
			document = {
				status = status,
				old = { path = old_path, lines = old_lines },
				new = { path = path, lines = new_lines },
				changes = binary and {} or line_changes(old_lines, new_lines),
				binary = binary,
			},
			left = { buf = layout.a.file.bufnr, win = layout.a.id },
			right = { buf = layout.b.file.bufnr, win = layout.b.id },
		}
		state.suspended = false
		session.statusline:attach(current_view.left.win)
		session.statusline:attach(current_view.right.win)
	end

	session_api.set_current(session, current_view)
	session_api.review_attached(session)
	if buffers_changed then
		register_review_buffers(session)
	end
	if state.auto_open_panel and open_review_panel(session, false) then
		state.auto_open_panel = false
	end
	finish_pending_jump(session)
	return true
end

---@param session AtlasDiffSession
local function schedule_sync(session)
	local state = session.viewer_state --[[@as AtlasDiffviewState]]
	if session.closed or state.closed or state.sync_scheduled then
		return
	end
	state.sync_scheduled = true
	vim.schedule(function()
		if session.viewer_state ~= state or state.closed then
			return
		end
		state.sync_scheduled = false
		sync(session)
	end)
end

---@param session AtlasDiffSession
---@param item AtlasDiffReviewPanelSelection
---@param focus_diff boolean
local function focus_item(session, item, focus_diff)
	local state = session.viewer_state --[[@as AtlasDiffviewState]]
	if state.closed then
		return
	end
	local pending = { focus_diff = focus_diff }
	local comment = item.comment and (item.comment.file or item.comment.inline) and item.comment or nil
	if not comment then
		session_api.notify(session, "info", "This comment is not attached to the diff")
		return
	end
	local target = comment.file or comment.inline
	local path = relative_path(session.source.root, target.path)
	pending.comment = comment
	if path == "" then
		session_api.notify(session, "info", "This review item's file is no longer in the diff")
		return
	end
	pending.path = path
	state.pending_jump = pending
	finish_pending_jump(session)
	if not state.pending_jump then
		return
	end
	for _, file in state.view.files:iter() do
		if
			relative_path(session.source.root, file.path) == path
			or relative_path(session.source.root, file.oldpath) == path
		then
			state.view:set_file(file, false, true)
			return
		end
	end
	state.pending_jump = nil
	session_api.notify(session, "info", "This review item's file is no longer in the diff")
end

---@param session AtlasDiffSession
local function register_events(session)
	local state = session.viewer_state --[[@as AtlasDiffviewState]]
	vim.api.nvim_create_autocmd("User", {
		group = state.group,
		pattern = { "DiffviewDiffBufWinEnter", "DiffviewViewPostLayout" },
		callback = function()
			if
				session.viewer_state == state
				and not state.closed
				and vim.api.nvim_get_current_tabpage() == session.tabpage
			then
				schedule_sync(session)
			end
		end,
	})
	vim.api.nvim_create_autocmd("User", {
		group = state.group,
		pattern = "DiffviewViewClosed",
		callback = function()
			vim.schedule(function()
				if
					session.viewer_state == state
					and not state.reloading
					and not state.closed
					and not session.closed
					and session.tabpage
					and not vim.api.nvim_tabpage_is_valid(session.tabpage)
				then
					M.detach(session, "viewer_closed")
				end
			end)
		end,
	})
end

---@param session AtlasDiffSession
---@param view table
---@param tabpage integer
local function attach(session, view, tabpage)
	local diff_config = (config.options.pulls or {}).diff or {}
	---@type AtlasDiffviewState
	local state = {
		view = view,
		group = vim.api.nvim_create_augroup("AtlasDiffview" .. tabpage, { clear = true }),
		sync_scheduled = false,
		suspended = false,
		auto_open_panel = diff_config.show_review_panel == true and session.review ~= nil,
		pending_jump = nil,
		additions = 0,
		deletions = 0,
		closed = false,
		reloading = false,
	}
	session.viewer_state = state
	state.reload_view = function()
		reload_view(session)
	end

	if session.review then
		local panel =
			session_api.create_review_panel(session, string.format("atlas-diff-diffview://%d/review", tabpage))
		review_panel.configure(panel)
		review_panel.register_keymaps(panel)
	end
	register_events(session)
	session_api.attach(session, {
		tabpage = tabpage,
		notify = function(level, message, duration)
			notify.show(level, message, { timeout = duration })
		end,
		focus_item = function(item, focus_diff)
			focus_item(session, item, focus_diff)
		end,
		render_view = function()
			render_view(session)
		end,
		toggle_review_panel = function(focus)
			toggle_review_panel(session, focus)
		end,
	})
	schedule_sync(session)
end

---@param session AtlasDiffSession
---@param loading_view AtlasLoadingView
---@param on_done fun(err: string|nil)
---@return nil
function M.open(session, loading_view, on_done)
	local finished = false
	local function finish(err)
		if finished then
			return
		end
		finished = true
		loading_view:finish()
		vim.schedule(function()
			on_done(err)
		end)
	end

	local source = session.source
	local range = source.head_revision and source.base_revision .. "..." .. source.head_revision or source.base_revision
	local ok, view = pcall(vim.api.nvim_win_call, loading_view.win, function()
		vim.cmd("tcd " .. vim.fn.fnameescape(source.root))
		vim.api.nvim_cmd({
			cmd = "DiffviewOpen",
			args = { range },
		}, {})
		return require("diffview.lib").get_current_view()
	end)
	if not ok then
		finish(tostring(view))
		return nil
	end
	local tabpage = view and view.tabpage or nil
	if not tabpage or not vim.api.nvim_tabpage_is_valid(tabpage) then
		finish("Diffview session is unavailable")
		return nil
	end

	local attached, attach_err = pcall(attach, session, view, tabpage)
	if not attached then
		local state = session.viewer_state --[[@as AtlasDiffviewState]]
		if state.view == view then
			M.detach(session, "attach_failed")
		end
		finish("Unable to attach review to Diffview: " .. tostring(attach_err))
		return nil
	end
	finish(nil)
	return nil
end

---@param session AtlasDiffSession
---@param reason string|nil
function M.detach(session, reason)
	local state = session.viewer_state --[[@as AtlasDiffviewState]]
	if session.closed or not state or state.closed then
		return
	end
	state.closed = true
	state.pending_jump = nil
	pcall(vim.api.nvim_del_augroup_by_id, state.group)
	session_api.detach(session, reason)
end

return M
