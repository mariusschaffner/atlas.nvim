-- The job log in the pipeline detail view's content float (DESIGN-pipeline-view.md §4).
local M = {}

local utils = require("atlas.ui.shared.utils")
local pipeline_logs = require("atlas.pulls.ui.pipelines.logs")
local state = require("atlas.pipelines.ui.detail.state")

local ns = vim.api.nvim_create_namespace("atlas.pipelines.detail.log")

---@param border_hl string
---@return string
local function winhighlight(border_hl)
	return table.concat({
		"Normal:AtlasBgDark",
		"NormalFloat:AtlasBgDark",
		"FloatBorder:" .. border_hl,
		"CursorLine:CursorLine",
		"LineNr:AtlasProgressEmpty",
	}, ",")
end

---@param lines string[]
local function replace(lines)
	local buf = state.buf
	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
end

---@param text string
---@param hl string
local function message(text, hl)
	replace({ text })
	vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
	vim.api.nvim_buf_set_extmark(state.buf, ns, 0, 0, { end_col = #text, hl_group = hl })
	vim.api.nvim_set_option_value("number", false, { win = state.win, scope = "local" })
end

function M.render()
	local win, buf = state.win, state.buf
	if not utils.window.valid(win) or not utils.buffer.valid(buf) then
		return
	end
	vim.api.nvim_set_option_value(
		"winhighlight",
		winhighlight(state.focus == "log" and "AtlasCyan" or "AtlasBorder"),
		{ win = win, scope = "local" }
	)
	local store = state.store
	local job = store and store:selected_job()
	if job == nil then
		message(store and store.pipeline and "No job selected." or "", "AtlasTextMuted")
		return
	end
	local trace = store.traces[job.id]
	if trace == nil or trace.status == "loading" then
		message("Loading log...", "AtlasTextMuted")
		return
	end
	if trace.status == "error" then
		message("Failed to load job log: " .. tostring(trace.err), "AtlasRed")
		return
	end
	if trace.raw == "" then
		message(job.started_at == nil and "This job hasn't started yet." or "(empty log)", "AtlasTextMuted")
		return
	end
	replace(pipeline_logs.flatten(pipeline_logs.parse(trace.raw)))
	vim.api.nvim_set_option_value("number", true, { win = win, scope = "local" })
end

--- Restores the content window options this view changed.
function M.detach()
	if utils.window.valid(state.win) then
		vim.api.nvim_set_option_value("number", false, { win = state.win, scope = "local" })
	end
end

return M
