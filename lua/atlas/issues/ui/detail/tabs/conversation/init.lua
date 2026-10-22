local M = {}

local renderer = require("atlas.issues.ui.detail.tabs.conversation.renderer")
local keymaps = require("atlas.issues.ui.detail.tabs.conversation.keymaps")
local state = require("atlas.issues.ui.detail.tabs.conversation.state")
local detail = require("atlas.issues.ui.detail.state")
local notify = require("atlas.core.notify")

function M.reset()
	state.reset()
	notify.clear()
end

--- "you" badges, Edit/Delete availability and the composers' avatar all key
--- off the signed-in user, which the dashboard normally loads -- fetch it
--- here too when the detail view was opened without the dashboard.
---@param refresh fun()
local function ensure_current_user(refresh)
	local issues_state = require("atlas.issues.state")
	local core = detail.provider and detail.provider.capabilities.core
	if issues_state.current_user ~= nil or not core or not core.fetch_user then
		return
	end
	state.requests.run(function(done)
		return core.fetch_user(done)
	end, function(user)
		if user == nil or issues_state.current_user ~= nil then
			return
		end
		issues_state.current_user = user
		if detail.current_tab == "conversation" and detail.buf and vim.api.nvim_buf_is_valid(detail.buf) then
			keymaps.attach_dock(detail.buf, refresh)
		end
		refresh()
	end)
end

---@param issue Issue
---@param refresh fun()
---@param opts { force_refresh: boolean|nil }|nil
function M.on_select(issue, refresh, opts)
	state.activate(issue)
	notify.clear()
	opts = opts or {}
	ensure_current_user(refresh)

	local provider = detail.provider
	local comments = provider and provider.capabilities.comments
	if not comments or not comments.fetch_conversation then
		state.items = {}
		refresh()
		return
	end

	local key = tostring(issue.key or "")
	state.items = "loading"
	notify.loading(string.format("Loading conversation for %s...", key))
	state.requests.run(function(done)
		return comments.fetch_conversation(issue, opts, done)
	end, function(result, err)
		if not state.is_current(issue) then
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
			notify.error(string.format(message, key, tostring(err)))
		else
			notify.success(string.format("Conversation loaded for %s", key), { timeout = 1200 })
		end
		refresh()
	end)
end

---@param issue Issue
---@param details IssueDetails|nil
---@param width integer
---@return string[], table[], table<integer, table>
function M.render(issue, details, width)
	local lines, spans, line_map = renderer.render(issue, details, width)
	-- Re-rendering rewrites every line; put the cursor-line hint back once
	-- the new content (and line_map) is in place.
	vim.schedule(keymaps.update_hint)
	return lines, spans, line_map
end

--- Every row is a plain cursor stop: j/k move line by line here, and actions
--- target whatever comment the cursor is on.
---@return boolean
function M.is_selectable_line()
	return true
end

---@return boolean
function M.is_loading()
	return state.is_loading()
end

---@param buf integer
---@param refresh fun()
function M.activate(buf, refresh)
	keymaps.setup(buf, refresh)
end

---@param buf integer
function M.deactivate(buf)
	keymaps.teardown(buf)
	state.deactivate()
	notify.clear()
end

return M
