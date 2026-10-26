-- The job log in the pipeline detail view's content float
-- (DESIGN-pipeline-view.md §4): GitLab sections as native folds (finished ones
-- closed, the running one open), ANSI colours and WARNING/ERROR tints as
-- extmarks, native line numbers and search. A growing trace only rewrites the
-- rows from the first changed one down, so earlier lines, folds and the
-- cursor stay put. Follow mode keeps the cursor on the last line.
local M = {}

local utils = require("atlas.ui.shared.utils")
local log_model = require("atlas.pipelines.ui.detail.log_model")
local state = require("atlas.pipelines.ui.detail.state")

local ns = vim.api.nvim_create_namespace("atlas.pipelines.detail.log")
local cursor_ns = vim.api.nvim_create_namespace("atlas.pipelines.detail.log.cursor")

local FOLDTEXT = "v:lua.require'atlas.pipelines.ui.detail.log_view'.foldtext()"

---@param border_hl string
---@return string
local function winhighlight(border_hl)
	return table.concat({
		"Normal:AtlasBgDark",
		"NormalFloat:AtlasBgDark",
		"FloatBorder:" .. border_hl,
		"CursorLine:CursorLine",
		"LineNr:AtlasProgressEmpty",
		"Folded:AtlasBgDark",
	}, ",")
end

---@param name string
---@param value any
local function set_win(name, value)
	if utils.window.valid(state.win) then
		pcall(vim.api.nvim_set_option_value, name, value, { win = state.win, scope = "local" })
	end
end

---@param fn fun()
local function in_win(fn)
	vim.api.nvim_win_call(state.win, fn)
end

--- Replaces the buffer from 1-based row `from` down.
---@param from integer
---@param lines string[]
local function set_lines_from(from, lines)
	local buf = state.buf
	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_buf_set_lines(buf, from - 1, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
end

---@param rows AtlasPipelineLogRow[]
---@param from integer 1-based
local function decorate(rows, from)
	local buf = state.buf
	vim.api.nvim_buf_clear_namespace(buf, ns, from - 1, -1)
	for i = from, #rows do
		local row = rows[i]
		for _, span in ipairs(row.spans) do
			pcall(vim.api.nvim_buf_set_extmark, buf, ns, i - 1, span.start_col, {
				end_col = math.min(span.end_col, #row.text),
				hl_group = span.hl_group,
				priority = 110,
			})
		end
		if row.line_hl or row.number_hl then
			pcall(vim.api.nvim_buf_set_extmark, buf, ns, i - 1, 0, {
				line_hl_group = row.line_hl,
				number_hl_group = row.number_hl,
				priority = 100,
			})
		end
	end
end

--- Cursor block on the last line while the job runs (§4).
---@param running boolean
---@param count integer
local function draw_cursor_block(running, count)
	vim.api.nvim_buf_clear_namespace(state.buf, cursor_ns, 0, -1)
	if running and count > 0 then
		pcall(vim.api.nvim_buf_set_extmark, state.buf, cursor_ns, count - 1, 0, {
			virt_text = { { " ▌", "AtlasCyan" } },
			virt_text_pos = "eol",
		})
	end
end

---@param lnum integer
local function set_cursor(lnum)
	pcall(vim.api.nvim_win_set_cursor, state.win, { math.max(1, lnum), 0 })
end

--- Creates the folds of finished sections that don't have one yet. A fresh
--- log closes them all; a section that finishes while it's being watched is
--- closed unless the cursor is inside it.
---@param rows AtlasPipelineLogRow[]
---@param fresh boolean
local function add_folds(rows, fresh)
	local cursor = vim.api.nvim_win_get_cursor(state.win)[1]
	in_win(function()
		for _, fold in ipairs(log_model.folds(rows)) do
			if fold.finished and not state.log.folds[fold.row] then
				vim.cmd(string.format("silent! %d,%dfold", fold.row, fold.last))
				state.log.folds[fold.row] = fold.last
				if not fresh and cursor >= fold.row and cursor <= fold.last then
					vim.cmd(string.format("silent! %dfoldopen", fold.row))
				end
			end
		end
	end)
end

--- Rebuilds every fold, keeping each one's open/closed state.
---@param rows AtlasPipelineLogRow[]
local function rebuild_folds(rows)
	local closed = {}
	in_win(function()
		for row in pairs(state.log.folds) do
			closed[row] = vim.fn.foldclosed(row) == row
		end
		vim.cmd("silent! normal! zE")
	end)
	state.log.folds = {}
	add_folds(rows, true)
	in_win(function()
		for row in pairs(state.log.folds) do
			if closed[row] == false then
				vim.cmd(string.format("silent! %dfoldopen", row))
			end
		end
	end)
end

---@param text string
---@param hl string
local function message(text, hl)
	set_lines_from(1, { text })
	vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
	vim.api.nvim_buf_clear_namespace(state.buf, cursor_ns, 0, -1)
	pcall(vim.api.nvim_buf_set_extmark, state.buf, ns, 0, 0, { end_col = #text, hl_group = hl })
	in_win(function()
		vim.cmd("silent! normal! zE")
	end)
	state.log.rows = {}
	state.log.folds = {}
	set_win("number", false)
end

--- Where a freshly shown log starts: running jobs follow the end, failed
--- ones open at their first error, everything else at the end.
---@param job PipelineGraphJob
---@param rows AtlasPipelineLogRow[]
local function position(job, rows)
	state.log.positioned = true
	if job.status == "running" then
		state.log.follow = true
		set_cursor(#rows)
		return
	end
	state.log.follow = false
	local target = #rows
	if job.status == "failed" then
		target = log_model.first_error_row(rows) or target
	end
	set_cursor(target)
	in_win(function()
		vim.cmd("silent! normal! zvzz")
	end)
end

function M.render()
	local win, buf = state.win, state.buf
	if not utils.window.valid(win) or not utils.buffer.valid(buf) then
		return
	end
	set_win("winhighlight", winhighlight(state.focus == "log" and "AtlasCyan" or "AtlasBorder"))

	local store = state.store
	local job = store and store:selected_job()
	if job == nil then
		message(store and store.pipeline and "No job selected." or "", "AtlasTextMuted")
		return
	end
	local trace = store.traces[job.id]
	if state.log.job_id ~= job.id then
		state.reset_log()
		state.log.job_id = job.id
	end
	if trace == nil or (trace.status == "loading" and trace.raw == "") then
		message("Loading log...", "AtlasTextMuted")
		return
	end
	if trace.status == "error" and trace.raw == "" then
		message("Failed to load job log: " .. tostring(trace.err), "AtlasRed")
		return
	end
	if trace.raw == "" then
		message(job.started_at == nil and "This job hasn't started yet." or "(empty log)", "AtlasTextMuted")
		return
	end

	local rows = log_model.build(trace.raw)
	local old = state.log.rows
	local fresh = #old == 0
	local first = fresh and 1 or log_model.first_diff(old, rows)
	if first then
		local lines = {}
		for i = first, #rows do
			lines[#lines + 1] = rows[i].text
		end
		set_lines_from(first, lines)
		decorate(rows, first)
		state.log.rows = rows
		set_win("number", true)

		local touched = false
		for row, last in pairs(state.log.folds) do
			if last >= first then
				touched = true
			end
			if row >= first then
				state.log.folds[row] = nil
			end
		end
		if fresh then
			in_win(function()
				vim.cmd("silent! normal! zE")
			end)
		end
		if touched and not fresh then
			rebuild_folds(rows)
		else
			add_folds(rows, fresh)
		end
	end
	draw_cursor_block(job.status == "running", #rows)

	if not state.log.positioned then
		position(job, rows)
	elseif state.log.follow and first then
		set_cursor(#rows)
	end
end

--- `foldtext` of a closed section: "▸ prepare executor · 3s".
---@return { [1]: string, [2]: string }[]|string
function M.foldtext()
	local row = state.log.rows[vim.v.foldstart]
	local section = row and row.section
	if section == nil then
		return vim.fn.foldtext()
	end
	local chunks = { { "▸ " .. section.name, "AtlasAccent" } }
	if section.duration then
		table.insert(chunks, { " · " .. log_model.duration_text(section.duration), "AtlasTextMuted" })
	end
	return chunks
end

--- Follow mode back on (`F`): jump to the end and stay there.
function M.follow()
	state.log.follow = true
	local count = #state.log.rows
	if count > 0 and utils.window.valid(state.win) then
		set_cursor(count)
	end
end

--- Opens/closes the section under the cursor (`za`).
function M.toggle_fold()
	if utils.window.valid(state.win) then
		in_win(function()
			vim.cmd("silent! normal! za")
		end)
	end
end

---@type integer|nil
local augroup = nil

--- Sets up the log window (folds, numbers, follow tracking). `on_follow_change`
--- re-renders the follow badge when scrolling turns follow mode off.
---@param on_follow_change fun()
function M.attach(on_follow_change)
	if not utils.window.valid(state.win) or not utils.buffer.valid(state.buf) then
		return
	end
	set_win("foldmethod", "manual")
	set_win("foldenable", true)
	set_win("foldminlines", 0)
	set_win("foldtext", FOLDTEXT)
	set_win("fillchars", "fold: ,eob: ")
	set_win("number", false)

	augroup = vim.api.nvim_create_augroup("AtlasPipelineLog" .. state.buf, { clear = true })
	vim.api.nvim_create_autocmd("CursorMoved", {
		group = augroup,
		buffer = state.buf,
		callback = function()
			if not state.log.follow or not utils.window.valid(state.win) then
				return
			end
			local line = vim.api.nvim_win_get_cursor(state.win)[1]
			if line < vim.api.nvim_buf_line_count(state.buf) then
				state.log.follow = false
				on_follow_change()
			end
		end,
	})
end

--- Restores the content window options this view changed.
function M.detach()
	if augroup then
		pcall(vim.api.nvim_del_augroup_by_id, augroup)
		augroup = nil
	end
	if utils.window.valid(state.win) then
		set_win("number", false)
		set_win("foldenable", false)
		set_win("foldtext", "foldtext()")
		set_win("fillchars", "")
		pcall(vim.api.nvim_win_call, state.win, function()
			vim.cmd("silent! normal! zE")
		end)
	end
	if utils.buffer.valid(state.buf) then
		vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
		vim.api.nvim_buf_clear_namespace(state.buf, cursor_ns, 0, -1)
	end
end

return M
