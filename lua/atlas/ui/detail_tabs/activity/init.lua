-- The detail views' Activity tab (DESIGN-detail-view.md §6): a day-grouped
-- timeline of system events and comment threads, inline reply/edit composers
-- and a docked "new comment" composer. Domain-agnostic: each detail view
-- (issues, merge requests) builds one instance with `M.new(host)`, where the
-- host supplies the subject (issue/MR), its window/buffer, and a comments
-- capability in the issue provider's shape (`AtlasActivityComments`).
local M = {}

local notify = require("atlas.core.notify")

---@class AtlasActivityUser
---@field id integer|string|nil
---@field account_id string|nil
---@field display_name string

---@class AtlasActivityComment : IssueComment

---@class AtlasActivityComments
---@field fetch_conversation (fun(subject: table, opts: { force_refresh: boolean|nil }|nil, on_done: fun(items: IssueConversationItem[]|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field add_comment (fun(subject: table, content: string, on_done: fun(comment: IssueComment|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field reply_comment (fun(subject: table, parent: IssueComment, content: string, on_done: fun(comment: IssueComment|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field edit_comment (fun(subject: table, comment: IssueComment, content: string, on_done: fun(comment: IssueComment|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field delete_comment (fun(subject: table, comment: IssueComment, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil)|nil
---@field set_thread_resolved (fun(subject: table, root: IssueComment, resolved: boolean, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil)|nil
---@field reaction_options table[]|nil

---@class AtlasActivityHost
---@field name string Unique per detail view, used for augroup/namespace names (e.g. "IssuesConversation").
---@field add_action_id string Keymap action that focuses the docked composer.
---@field expand_action_id string Keymap action that expands a collapsed activity run.
---@field closed_message string Shown when commenting on a closed subject.
---@field subject fun(): table|nil The open issue/MR.
---@field subject_key fun(subject: table): string Identity for "is this still the same subject" checks.
---@field subject_label fun(subject: table): string For loading/error messages, e.g. "g/p#17".
---@field is_open fun(subject: table|nil): boolean Whether comments can still be added/edited.
---@field win fun(): integer|nil Content window.
---@field buf fun(): integer|nil Content buffer.
---@field line_map fun(): table<integer, table> The detail view's current line map.
---@field is_active fun(): boolean Whether this Activity tab is the detail view's current tab.
---@field comments fun(): AtlasActivityComments|nil
---@field current_user fun(): AtlasActivityUser|nil
---@field fetch_current_user (fun(on_done: fun(user: AtlasActivityUser|nil)): { cancel: fun() }|nil)|nil Loads the signed-in user when the dashboard hasn't.
---@field completion fun(subject: table, comments: IssueComment[]): AtlasMarkdownCompletionProvider|nil
---@field on_comment_count (fun(subject: table, delta: integer))|nil
---@field person_hl fun(name: string): string Highlight for "@handle" mentions.

---@param host AtlasActivityHost
---@return table tab A detail-view tab module (render/on_select/activate/...) plus its `state`.
function M.new(host)
	local state = require("atlas.ui.detail_tabs.activity.state").new(host)
	local actions = require("atlas.ui.detail_tabs.activity.actions").new(host, state)
	local renderer = require("atlas.ui.detail_tabs.activity.renderer").new(host, state, actions)
	local keymaps = require("atlas.ui.detail_tabs.activity.keymaps").new(host, state, actions)

	local tab = { state = state }

	function tab.reset()
		state.reset()
		notify.clear()
	end

	--- "you" badges, Edit/Delete availability and the composers' avatar all
	--- key off the signed-in user, which the dashboard normally loads -- fetch
	--- it here too when the detail view was opened without the dashboard.
	---@param refresh fun()
	local function ensure_current_user(refresh)
		if host.current_user() ~= nil or host.fetch_current_user == nil then
			return
		end
		state.requests.run(function(done)
			return host.fetch_current_user(done)
		end, function(user)
			if user == nil then
				return
			end
			local buf = host.buf()
			if host.is_active() and buf and vim.api.nvim_buf_is_valid(buf) then
				keymaps.attach_dock(buf, refresh)
			end
			refresh()
		end)
	end

	---@param subject table
	---@param refresh fun()
	---@param opts { force_refresh: boolean|nil }|nil
	function tab.on_select(subject, refresh, opts)
		state.activate(subject)
		notify.clear()
		opts = opts or {}
		ensure_current_user(refresh)

		local comments = host.comments()
		if not comments or not comments.fetch_conversation then
			state.items = {}
			refresh()
			return
		end

		local label = host.subject_label(subject)
		state.items = "loading"
		notify.loading(string.format("Loading conversation for %s...", label))
		state.requests.run(function(done)
			return comments.fetch_conversation(subject, opts, done)
		end, function(result, err)
			if not state.is_current(subject) then
				return
			end
			state.items = {}
			if result then
				for _, item in ipairs(result) do
					if item.kind ~= "comment" or item.entity.deleted ~= true then
						table.insert(state.items, item)
					end
				end
			end

			state.error = nil
			if err then
				if not result then
					state.error = tostring(err)
				end
				local message = result and "Conversation for %s partially failed: %s"
					or "Failed to load conversation for %s: %s"
				notify.error(string.format(message, label, tostring(err)))
			else
				notify.success(string.format("Conversation loaded for %s", label), { timeout = 1200 })
			end
			refresh()
		end)
	end

	---@param subject table
	---@param details table|nil
	---@param width integer
	---@return string[], table[], table<integer, table>
	function tab.render(subject, details, width)
		local lines, spans, line_map = renderer.render(subject, details, width)
		-- Re-rendering rewrites every line; put the cursor-line hint back once
		-- the new content (and line_map) is in place.
		vim.schedule(keymaps.update_hint)
		return lines, spans, line_map
	end

	--- Every row is a plain cursor stop: j/k move line by line here, and
	--- actions target whatever comment the cursor is on.
	---@return boolean
	function tab.is_selectable_line()
		return true
	end

	---@return boolean
	function tab.is_loading()
		return state.is_loading()
	end

	---@param buf integer
	---@param refresh fun()
	function tab.activate(buf, refresh)
		keymaps.setup(buf, refresh)
	end

	---@param buf integer
	function tab.deactivate(buf)
		keymaps.teardown(buf)
		state.deactivate()
		notify.clear()
	end

	return tab
end

return M
