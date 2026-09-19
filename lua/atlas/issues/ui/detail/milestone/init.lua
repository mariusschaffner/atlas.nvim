local M = {}

local detail_ui = require("atlas.ui.detail")
local renderer = require("atlas.issues.ui.detail.milestone.renderer")
local notify = require("atlas.core.notify")
local request_scope = require("atlas.core.requests")
local state = require("atlas.issues.ui.detail.milestone.state")

local function render()
	renderer.render()
end

local function render_if_open()
	if detail_ui.is_showing("milestone") then
		render()
	end
end

---@param id integer|nil
---@return boolean
local function same_milestone(id)
	local current = state.current_milestone
	return current ~= nil and current.id ~= nil and id ~= nil and current.id == id
end

local function load_description(id)
	local core = state.provider and state.provider.capabilities.core
	local fetch = core and core.fetch_milestone
	if not fetch then
		state.description = nil
		state.description_loading = false
		render_if_open()
		return
	end
	state.description_loading = true
	state.requests.run(function(done)
		return fetch(state.project_path, id, done)
	end, function(milestone, err)
		if not same_milestone(id) then
			return
		end
		state.description_loading = false
		if milestone == nil then
			notify.error(tostring(err or "Failed to load milestone"))
		else
			state.current_milestone = milestone
			state.description = milestone.description
		end
		render_if_open()
	end)
end

local function load_work_items(id)
	local core = state.provider and state.provider.capabilities.core
	local fetch = core and core.fetch_milestone_issues
	if not fetch then
		state.work_items = nil
		state.work_items_loading = false
		render_if_open()
		return
	end
	state.work_items_loading = true
	state.requests.run(function(done)
		return fetch(state.project_path, id, done)
	end, function(issues, err)
		if not same_milestone(id) then
			return
		end
		state.work_items_loading = false
		if issues == nil then
			notify.error(tostring(err or "Failed to load work items"))
			state.work_items = nil
		else
			state.work_items = issues
		end
		render_if_open()
	end)
end

local function load_merge_requests(id)
	local core = state.provider and state.provider.capabilities.core
	local fetch = core and core.fetch_milestone_merge_requests
	if not fetch then
		state.merge_requests = nil
		state.merge_requests_loading = false
		render_if_open()
		return
	end
	state.merge_requests_loading = true
	state.requests.run(function(done)
		return fetch(state.project_path, id, done)
	end, function(items, err)
		if not same_milestone(id) then
			return
		end
		state.merge_requests_loading = false
		if items == nil then
			notify.error(tostring(err or "Failed to load merge requests"))
			state.merge_requests = nil
		else
			state.merge_requests = items
		end
		render_if_open()
	end)
end

---@return boolean
function M.is_open()
	return detail_ui.is_showing("milestone")
end

function M.rerender()
	render_if_open()
end

local function cleanup()
	local buf = state.buf
	if buf and vim.api.nvim_buf_is_valid(buf) then
		require("atlas.issues.ui.detail.milestone.keymaps").remove(buf)
	end
	state.reset()
end

---@param milestone IssueMilestone
---@param opts { provider: IssuesProvider, project_path: string }
function M.open(milestone, opts)
	if milestone.id == nil then
		notify.error("Milestone is missing an id")
		return
	end

	state.requests.cancel()
	state.requests = request_scope.new()
	state.win, state.buf, state.header_win, state.header_buf = detail_ui.open("milestone", cleanup, render)
	state.provider = opts.provider
	state.project_path = opts.project_path
	state.current_milestone = milestone
	state.description = milestone.description
	state.work_items = nil
	state.merge_requests = nil
	state.current_tab = "description"

	if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
		require("atlas.issues.ui.detail.milestone.keymaps").register(state.buf)
	end

	render()
	load_description(milestone.id)
	load_work_items(milestone.id)
	load_merge_requests(milestone.id)
end

--- Edit the milestone description inline. No-op when not on the Description
--- tab, when the provider doesn't support it, or while already editing.
function M.edit_description()
	local milestone = state.current_milestone
	local buf = state.buf
	if milestone == nil or milestone.id == nil or buf == nil or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	if state.current_tab ~= "description" then
		return
	end
	local core = state.provider and state.provider.capabilities.core
	local update = core and core.update_milestone_description
	if not update then
		notify.warn("Provider does not support editing milestone descriptions")
		return
	end
	local inline_edit = require("atlas.ui.inline_edit")
	if inline_edit.is_active(buf) then
		return
	end

	local current = tostring(state.description or "")
	local milestone_id = milestone.id
	local project_path = state.project_path
	local keymaps = require("atlas.issues.ui.detail.milestone.keymaps")

	keymaps.remove(buf)
	inline_edit.start({
		buf = buf,
		text = current,
		on_save = function(text, done)
			local updated = text or ""
			if updated == current then
				done(true)
				return
			end
			notify.loading("Updating description...")
			update(project_path, milestone_id, updated, function(ok, err)
				if not same_milestone(milestone_id) then
					done(true)
					return
				end
				if not ok then
					notify.error("Description update failed: " .. tostring(err or "Unknown error"))
					done(false, err)
					return
				end
				state.description = updated
				if state.current_milestone then
					state.current_milestone.description = updated
				end
				notify.success("Description updated", { timeout = 1200 })
				done(true)
			end)
		end,
		on_cancel = function()
			notify.info("Description unchanged", { timeout = 1200 })
		end,
		on_done = function()
			if buf and vim.api.nvim_buf_is_valid(buf) then
				keymaps.register(buf)
			end
			render_if_open()
		end,
	})
end

---@param step 1|-1
local function change_tab(step)
	local items = renderer.tabs
	local index = 1
	for i, tab in ipairs(items) do
		if tab.key == state.current_tab then
			index = i
			break
		end
	end
	state.current_tab = items[(index - 1 + step) % #items + 1].key
	render()
	if state.win and vim.api.nvim_win_is_valid(state.win) then
		vim.api.nvim_win_set_cursor(state.win, { 1, 0 })
	end
end

function M.next_tab()
	change_tab(1)
end

function M.prev_tab()
	change_tab(-1)
end

function M.close()
	if M.is_open() then
		detail_ui.close()
	end
end

return M
