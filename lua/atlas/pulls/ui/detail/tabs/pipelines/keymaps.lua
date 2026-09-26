local M = {}

local help = require("atlas.ui.popups.help")
local resolver = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local notify = require("atlas.core.notify")
local detail = require("atlas.pulls.ui.detail.state")
local state = require("atlas.pulls.ui.detail.tabs.pipelines.state")

local RETRY_REFRESH_DELAY_MS = 1000

---@return PullsPipelinesTabModule
local function pipelines_tab()
	-- Lazy require: init.lua requires this module at load time, so a
	-- top-level require here would be circular.
	return require("atlas.pulls.ui.detail.tabs.pipelines")
end

---@param row integer 0-indexed
local function move_cursor_to_row(row)
	local win = detail.win
	if win == nil or not vim.api.nvim_win_is_valid(win) then
		return
	end
	pcall(vim.api.nvim_win_set_cursor, win, { row + 1, 0 })
end

---@param refresh fun()
local function follow_active(refresh)
	refresh()
	local region = state.active_id and state.regions[state.active_id]
	if region then
		move_cursor_to_row(region.row)
	end
end

--- `za`: toggles the active entry (pipeline or job). Expanding a pipeline
--- focuses its first job (fetching job details first if not cached yet, in
--- which case the focus is deferred -- see `state.pending_focus_pipeline_id`
--- and `init.lua`'s `M.render`). Exposed on `M` so `init.lua`'s `on_enter`
--- (`<CR>`) can alias to the same behavior.
---@param pr PullRequest
---@param refresh fun()
---@return boolean|nil
function M.toggle_fold(pr, refresh)
	local entry = state.active_entry()
	if entry == nil then
		return
	end
	local tab = pipelines_tab()

	if entry.kind == "pipeline" then
		-- `nav_id` (prefixed) is the navigable/active/expanded_pipelines
		-- namespace; `raw_id` (unprefixed) is what `ensure_pipeline_details`
		-- and `state.details_by_id` have always been keyed by (see
		-- renderer.lua's `append_pipeline_box` for the same split). Don't mix
		-- the two up.
		local raw_id = tostring(entry.pipeline.id)
		local nav_id = "pipeline:" .. raw_id
		local was_expanded = state.is_pipeline_expanded(nav_id)
		state.toggle_pipeline(nav_id)
		if was_expanded then
			refresh()
			return true
		end

		tab.ensure_pipeline_details(pr, entry.pipeline)
		local detailed = state.details_by_id[raw_id]
		if detailed ~= nil and detailed ~= "loading" and type(detailed) ~= "string" then
			refresh() -- populate state.navigable with this pipeline's now-known jobs
			if tab.focus_first_job(pr, raw_id) then
				follow_active(refresh)
				return true
			end
		else
			state.pending_focus_pipeline_id = raw_id
		end
		refresh()
		return true
	end

	if entry.kind == "job" then
		local job_id = tostring(entry.job.id)
		state.toggle_job(job_id)
		if state.is_job_expanded(job_id) then
			tab.ensure_job_log(pr, entry.pipeline, entry.job)
		end
		refresh()
		return true
	end
end

---@param pr PullRequest
---@param refresh fun()
local function do_next(pr, refresh)
	local entry = state.active_entry()

	if entry and entry.kind == "job" and state.is_job_expanded(tostring(entry.job.id)) then
		local region = state.regions[entry.id]
		local win = detail.win
		if region and win and vim.api.nvim_win_is_valid(win) then
			local cur_row = vim.api.nvim_win_get_cursor(win)[1] - 1
			if cur_row < region.row + region.height - 1 then
				pcall(vim.api.nvim_win_set_cursor, win, { cur_row + 2, 0 })
				return
			end
		end
		-- At the log's last line: collapse this job before advancing.
		state.expanded_jobs[tostring(entry.job.id)] = nil
	end

	state.move_active(1)
	local new_entry = state.active_entry()
	if new_entry and new_entry.kind == "job" then
		state.expanded_jobs[tostring(new_entry.job.id)] = true
		pipelines_tab().ensure_job_log(pr, new_entry.pipeline, new_entry.job)
	end
	refresh()
	local region = new_entry and state.regions[new_entry.id]
	if region then
		move_cursor_to_row(region.row)
	end
end

---@param pr PullRequest
---@param refresh fun()
local function do_previous(pr, refresh)
	local entry = state.active_entry()

	if entry and entry.kind == "job" and state.is_job_expanded(tostring(entry.job.id)) then
		local region = state.regions[entry.id]
		local win = detail.win
		if region and win and vim.api.nvim_win_is_valid(win) then
			local cur_row = vim.api.nvim_win_get_cursor(win)[1] - 1
			if cur_row > region.row then
				pcall(vim.api.nvim_win_set_cursor, win, { cur_row, 0 })
				return
			end
		end
		state.expanded_jobs[tostring(entry.job.id)] = nil
	end

	state.move_active(-1)
	local new_entry = state.active_entry()
	if new_entry and new_entry.kind == "job" then
		state.expanded_jobs[tostring(new_entry.job.id)] = true
		pipelines_tab().ensure_job_log(pr, new_entry.pipeline, new_entry.job)
	end
	refresh()
	local region = new_entry and state.regions[new_entry.id]
	if region then
		-- Moving backward lands on the *last* line of the newly-active job's
		-- log (or the single-line pipeline region), matching reverse-scroll
		-- expectations rather than jumping back to its top.
		move_cursor_to_row(region.row + region.height - 1)
	end
end

---@param action "retry"|"cancel"
local function run_action(action)
	local entry = state.active_entry()
	if not entry or (entry.kind ~= "pipeline" and entry.kind ~= "job") then
		notify.warn("Select a pipeline or job first")
		return
	end
	local pr = detail.current_pr
	local pipelines_api = detail.provider and detail.provider.capabilities.pipelines
	if pr == nil or pipelines_api == nil then
		return
	end

	local target_label, fn, arg
	if entry.kind == "job" then
		target_label = "Job"
		fn = action == "retry" and pipelines_api.retry_job or pipelines_api.cancel_job
		arg = entry.job
	else
		target_label = "Pipeline"
		fn = action == "retry" and pipelines_api.retry or pipelines_api.cancel
		arg = entry.pipeline
	end

	if fn == nil then
		notify.warn(target_label .. " " .. action .. " is not supported by this provider")
		return
	end

	local verb = action == "retry" and "Retrying" or "Cancelling"
	notify.loading(string.format("%s %s...", verb, target_label:lower()))
	fn(pr, arg, function(ok, err)
		if not ok then
			notify.error(string.format("Failed to %s %s: %s", action, target_label:lower(), tostring(err)))
			return
		end
		notify.success(
			string.format("%s %s", target_label, action == "retry" and "retried" or "cancelled"),
			{ timeout = 1200 }
		)
		vim.defer_fn(function()
			require("atlas.pulls.ui.detail").refresh()
		end, RETRY_REFRESH_DELAY_MS)
	end)
end

---@param buf integer
---@param refresh fun()
function M.setup(buf, refresh)
	local items = {}

	utils.insert_if(
		items,
		resolver.item("ui.next_item", {
			desc = "Next pipeline / job output line",
			hint = false,
			opts = { nowait = true, silent = true },
			callback = function()
				local pr = detail.current_pr
				if pr then
					do_next(pr, refresh)
				end
			end,
		})
	)
	utils.insert_if(
		items,
		resolver.item("ui.previous_item", {
			desc = "Previous pipeline / job output line",
			hint = false,
			opts = { nowait = true, silent = true },
			callback = function()
				local pr = detail.current_pr
				if pr then
					do_previous(pr, refresh)
				end
			end,
		})
	)
	utils.insert_if(
		items,
		resolver.item("ui.toggle_fold", {
			desc = "Toggle pipeline / job",
			hint = false, -- shown on the active box's own bottom border instead
			opts = { nowait = true, silent = true },
			callback = function()
				local pr = detail.current_pr
				if pr then
					M.toggle_fold(pr, refresh)
				end
			end,
		})
	)
	utils.insert_if(
		items,
		resolver.item("pulls.pipeline_retry", {
			desc = "Retry pipeline / job",
			hint_desc = "Retry",
			opts = { nowait = true, silent = true },
			callback = function()
				run_action("retry")
			end,
		})
	)
	utils.insert_if(
		items,
		resolver.item("pulls.pipeline_cancel", {
			desc = "Cancel pipeline / job",
			hint_desc = "Cancel",
			opts = { nowait = true, silent = true },
			callback = function()
				run_action("cancel")
			end,
		})
	)

	help.register("Detail", items, { index = 212, buffer = buf })
end

---@param buf integer
function M.teardown(buf)
	local items = {}
	utils.insert_if(items, resolver.remove_item("ui.next_item"))
	utils.insert_if(items, resolver.remove_item("ui.previous_item"))
	utils.insert_if(items, resolver.remove_item("ui.toggle_fold"))
	utils.insert_if(items, resolver.remove_item("pulls.pipeline_retry"))
	utils.insert_if(items, resolver.remove_item("pulls.pipeline_cancel"))
	help.remove("Detail", items, { buffer = buf })
end

return M
