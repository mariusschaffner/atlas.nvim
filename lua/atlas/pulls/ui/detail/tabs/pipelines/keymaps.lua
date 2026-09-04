local M = {}

local help = require("atlas.ui.popups.help")
local resolver = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local notify = require("atlas.core.notify")
local detail = require("atlas.pulls.ui.detail.state")

local RETRY_REFRESH_DELAY_MS = 1000

---@param action_id AtlasKeymapActionId|string
---@param map_item table
---@return table|nil
local function item(action_id, map_item)
	local keys = resolver.resolve(action_id)
	if keys == nil then
		return nil
	end
	local out = vim.tbl_deep_extend("force", {}, map_item)
	out.key = #keys == 1 and keys[1] or keys
	return out
end

---@param action_id AtlasKeymapActionId|string
---@return table|nil
local function remove_item(action_id)
	local keys = resolver.resolve(action_id)
	if keys == nil then
		return nil
	end
	return { key = (#keys == 1 and keys[1] or keys) }
end

---@return table|nil
local function cursor_entry()
	local win = detail.win
	if win == nil or not vim.api.nvim_win_is_valid(win) then
		return nil
	end
	local lnum = vim.api.nvim_win_get_cursor(win)[1]
	return detail.line_map[lnum]
end

---@param action "retry"|"cancel"
local function run_action(action)
	local entry = cursor_entry()
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
function M.setup(buf, _refresh)
	local items = {}

	utils.insert_if(
		items,
		item("pulls.pipeline_retry", {
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
		item("pulls.pipeline_cancel", {
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
	utils.insert_if(items, remove_item("pulls.pipeline_retry"))
	utils.insert_if(items, remove_item("pulls.pipeline_cancel"))
	help.remove("Detail", items, { buffer = buf })
end

return M
