-- Rendering of the pipeline detail view (DESIGN-pipeline-view.md §1-§4): the
-- shared boxed header (meta line, pill + title + timer/keys) holding the stage
-- graph and its key hints, and the job log in the content float whose native
-- title is the log header. Reads the store; never fetches.
local M = {}

local utils = require("atlas.ui.shared.utils")
local detail_ui = require("atlas.ui.detail")
local detail_header = require("atlas.ui.components.detail_header")
local keyhints = require("atlas.ui.components.keyhints")
local spinner = require("atlas.ui.components.spinner")
local resolver = require("atlas.core.keymaps")
local status = require("atlas.pipelines.status")
local graph = require("atlas.pipelines.ui.detail.components.graph")
local log_view = require("atlas.pipelines.ui.detail.log_view")
local state = require("atlas.pipelines.ui.detail.state")

local header_ns = vim.api.nvim_create_namespace("atlas.pipelines.detail.header")

---@param buf integer|nil
---@param lines string[]
local function set_lines(buf, lines)
	if not utils.buffer.valid(buf) then
		return
	end
	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
end

---@return integer
local function now()
	return state.store and state.store:now() or os.time()
end

--- What the header shows: the loaded snapshot, else what the view was opened with.
---@return PipelineGraph|nil
local function current_pipeline()
	if state.store and state.store.pipeline then
		return state.store.pipeline
	end
	local ref = state.pipeline_ref
	if ref == nil then
		return nil
	end
	return {
		id = ref.id,
		project_path = ref.project_path,
		status = (ref.status or ""):lower(),
		ref = ref.ref or "",
		sha = ref.sha or "",
		short_sha = ref.short_sha,
		user = ref.user,
		created_at = ref.created_at,
		started_at = ref.started_at,
		finished_at = ref.finished_at,
		duration = ref.duration,
		merge_request = state.merge_request,
		stages = {},
	}
end

---@param action_id string
---@return string|nil
local function display_key(action_id)
	local keys = resolver.resolve(action_id)
	return keys and keyhints.format_key(keys[1]) or nil
end

--- "h/l"-style combined key for a pair of actions (nil if either is unmapped).
---@param a string
---@param b string
---@return string|nil
local function key_pair(a, b)
	local ka, kb = display_key(a), display_key(b)
	if ka == nil or kb == nil then
		return nil
	end
	return ka .. "/" .. kb
end

---@param path string
---@param id string
---@return string
local function breadcrumb(path, id)
	local parts = vim.split(path or "", "/", { plain = true, trimempty = true })
	local project = parts[#parts] or path or ""
	table.remove(parts)
	local namespace = table.concat(parts, " / ")
	local left = namespace ~= "" and (namespace .. " / " .. project) or project
	return string.format("%s › pipelines › #%s", left, tostring(id or ""))
end

---@param pipeline PipelineGraph
---@return { [1]: string, [2]: string|nil }[]
local function meta_chunks(pipeline)
	local chunks = {}
	local function add(text, hl)
		if #chunks > 0 then
			table.insert(chunks, { " · " })
		end
		table.insert(chunks, { text, hl })
	end
	if (pipeline.ref or "") ~= "" then
		add("⎇ " .. pipeline.ref, "AtlasCyan")
	end
	if pipeline.short_sha then
		add(pipeline.short_sha)
	end
	local mr = pipeline.merge_request
	if mr and mr.iid then
		add("!" .. tostring(mr.iid), "AtlasAccent")
	end
	if pipeline.user then
		add(pipeline.user.username or pipeline.user.name)
	end
	local rel = utils.relative_time(pipeline.started_at or pipeline.created_at)
	if rel ~= "-" then
		add(rel == "now" and "started just now" or ("started " .. rel .. " ago"))
	end
	return chunks
end

---@param pipeline PipelineGraph
---@return integer done
---@return integer total
local function job_counts(pipeline)
	local done, total = 0, 0
	for _, stage in ipairs(pipeline.stages or {}) do
		for _, job in ipairs(stage.jobs or {}) do
			total = total + 1
			local s = status.normalize(job.status)
			if s == "success" or s == "failed" or s == "canceled" or s == "skipped" then
				done = done + 1
			end
		end
	end
	return done, total
end

--- Right side of the title line: "3:05 elapsed · 4/7 jobs".
---@param pipeline PipelineGraph
---@param pill AtlasPipelinePill
---@return { [1]: string, [2]: string|nil }[]
local function title_right(pipeline, pill)
	local chunks = {}
	local value, suffix = status.elapsed(pipeline, now())
	local info = {}
	if value then
		table.insert(chunks, { value, pill.color })
		table.insert(info, suffix:sub(2))
	end
	local done, total = job_counts(pipeline)
	if total > 0 then
		table.insert(info, string.format("%d/%d jobs", done, total))
	end
	if #info > 0 then
		table.insert(chunks, { (value and " " or "") .. table.concat(info, " · "), "AtlasTextMuted" })
	end
	return chunks
end

---@param chunks { [1]: string, [2]: string|nil }[]
---@return integer
local function chunks_width(chunks)
	local w = 0
	for _, chunk in ipairs(chunks) do
		w = w + vim.api.nvim_strwidth(chunk[1])
	end
	return w
end

--- Pipeline-level key hints, right-aligned in the header box's bottom
--- border: "R retry failed" only once the pipeline failed, "gX cancel" only
--- while it can still be cancelled (running or waiting to run).
---@param pipeline PipelineGraph
---@return { [1]: string, [2]: string }[]
local function pipeline_hints(pipeline)
	local s = status.normalize(pipeline.status)
	local segments = {}
	if s == "failed" then
		table.insert(segments, { action_id = "pipelines.retry_failed", label = "retry failed" })
	end
	if status.is_active(s) then
		table.insert(segments, { action_id = "pipelines.cancel_pipeline", label = "cancel" })
	end
	return keyhints.chunks(segments, { separator = "   " })
end

--- The graph's key hints (§3), drawn into the header box's bottom border:
--- "h/l stage   j/k job   ⏎ output   r retry   p manual   X cancel".
--- `retry` only shows for a failed job, `manual` only for a manual job
--- that's waiting to be played and `cancel` only for a running job.
--- Trailing hints are dropped when they don't fit `width`.
---@param width integer
---@return { [1]: string, [2]: string }[]
local function graph_hints(width)
	local job = state.store and state.store:selected_job()
	local segments = {
		{ keys = { key_pair("pipelines.previous_stage", "pipelines.next_stage") }, label = "stage" },
		{ keys = { key_pair("ui.next_item", "ui.previous_item") }, label = "job" },
		{ action_id = "ui.select", label = "output" },
	}
	if job and status.normalize(job.status) == "failed" then
		table.insert(segments, { action_id = "pipelines.retry_job", label = "retry" })
	end
	if job and status.job_badge(job, now()).kind == "manual" then
		table.insert(segments, { action_id = "pipelines.play_job", label = "manual" })
	end
	if job and status.normalize(job.status) == "running" then
		table.insert(segments, { action_id = "pipelines.cancel_job", label = "cancel" })
	end

	local chunks = keyhints.chunks(segments, { separator = "   " })
	while #segments > 1 and chunks_width(chunks) > width do
		table.remove(segments)
		chunks = keyhints.chunks(segments, { separator = "   " })
	end
	return chunks
end

--- The graph as the header box's `extra` block (its key hints go into the
--- box's bottom border, see `graph_hints`).
---@param pipeline PipelineGraph
---@param width integer
---@return IssuesDetailHeaderBlock
---@return integer|nil selected_row 0-based row of the selected pill inside the block.
local function graph_block(pipeline, width)
	local store = state.store
	if store == nil or (store.pipeline == nil and store.error == nil) then
		local text = spinner.with_text("Loading pipeline...")
		return { lines = { text }, highlights = { { line = 0, start_col = 0, end_col = #text, hl_group = "AtlasTextMuted" } } },
			nil
	end
	if store.pipeline == nil then
		local text = "Failed to load pipeline: " .. tostring(store.error)
		return { lines = { text }, highlights = { { line = 0, start_col = 0, end_col = #text, hl_group = "AtlasRed" } } },
			nil
	end

	local result = graph.render(pipeline, {
		width = width,
		now = now(),
		selected_job_id = store.selected_job_id,
		focused = state.focus == "graph",
		play_key = display_key("pipelines.play_job"),
		prev_first = state.viewport_first,
	})
	state.viewport_first = result.viewport.first

	-- A blank row keeps the last pills off the box's bottom border (and its hints).
	local lines = vim.list_extend(vim.list_extend({}, result.lines), { "" })
	return {
		lines = lines,
		highlights = result.highlights,
		regions = { graph = { row = 0, col = 0, width = width, height = #result.lines } },
	}, result.selected_row
end

--- Scrolls the header window so the selected pill stays visible when the
--- graph is taller than the (capped) header.
---@param row integer 0-based header line.
local function reveal_header_row(row)
	local win = state.header_win
	if not utils.window.valid(win) then
		return
	end
	local height = vim.api.nvim_win_get_height(win)
	local line_count = vim.api.nvim_buf_line_count(state.header_buf)
	if line_count <= height then
		return
	end
	vim.api.nvim_win_call(win, function()
		local view = vim.fn.winsaveview()
		local top = view.topline - 1
		if row - 1 < top then
			top = math.max(0, row - 1)
		elseif row + 1 >= top + height then
			top = math.min(line_count - height, row + 2 - height)
		end
		vim.fn.winrestview({ topline = top + 1, lnum = top + 1 })
	end)
end

function M.render_header()
	local buf, win = state.header_buf, state.header_win
	if not utils.buffer.valid(buf) or not utils.window.valid(win) then
		return
	end
	local pipeline = current_pipeline()
	if pipeline == nil then
		return
	end
	local outer = vim.api.nvim_win_get_width(win)
	local pill = status.pipeline_pill(pipeline.status)
	local mr = pipeline.merge_request
	local data = {
		breadcrumb = breadcrumb(pipeline.project_path, pipeline.id),
		meta_right_chunks = meta_chunks(pipeline),
		state_icon = pill.icon,
		state_label = pill.label,
		state_hl = pill.hl,
		title = (mr and mr.title) or pipeline.commit_title or ("Pipeline #" .. tostring(pipeline.id)),
		iid_text = "#" .. tostring(pipeline.id),
		title_right = title_right(pipeline, pill),
	}

	-- Bottom border: job hints left (with the graph), pipeline hints right.
	local loaded = state.store and state.store.pipeline
	local room = detail_header.bottom_width(outer)
	if loaded then
		data.bottom_right_chunks = pipeline_hints(pipeline)
		if #data.bottom_right_chunks > 0 then
			room = room - chunks_width(data.bottom_right_chunks) - 3
		end
	end
	local extra, selected_row = nil, nil
	if not state.fullscreen then
		extra, selected_row = graph_block(pipeline, detail_header.inner_width(outer))
		if loaded then
			data.bottom_chunks = graph_hints(room)
		end
	end
	local lines, spans, regions = detail_header.render(data, outer, extra)
	-- One blank row between the header box and the log box below it.
	table.insert(lines, "")
	set_lines(buf, lines)
	utils.apply_spans(buf, header_ns, spans)
	detail_ui.resize_header(#lines)
	if selected_row and regions.graph then
		reveal_header_row(regions.graph.row + selected_row)
	end
end

--- Log header (§4) as the content float's title: "◐ molecule-default ─── ● following  F follow · / search ...".
---@return { [1]: string, [2]: string }[]
local function log_title()
	local win = state.win
	local store = state.store
	local job = store and store:selected_job()
	local border_hl = state.focus == "log" and "AtlasCyan" or "AtlasBorder"
	if job == nil or not utils.window.valid(win) then
		return {}
	end
	local badge = status.job_badge(job, now())
	local left = {
		{ "─ ", border_hl },
		{ badge.icon .. " ", badge.icon_hl },
		{ job.name, "AtlasTextBright" },
		{ " ", border_hl },
	}
	local right = { { " ", border_hl } }
	if state.log.follow and job.status == "running" then
		table.insert(right, { " ● following ", "AtlasBadgeFollow" })
		table.insert(right, { "  ", border_hl })
	end
	local segments = {
		{ action_id = "pipelines.follow", label = "follow" },
		{ keys = { "/" }, label = "search" },
		{ action_id = "ui.toggle_fold", label = "fold" },
		{ action_id = "pipelines.fullscreen", label = "fullscreen" },
	}
	if state.focus == "log" then
		table.insert(segments, { action_id = "pipelines.focus_graph", label = "graph" })
	end
	for _, chunk in ipairs(keyhints.chunks(segments, { separator = " · " })) do
		table.insert(right, { chunk[1], chunk[2] == "Normal" and "AtlasKeyHintLabel" or chunk[2] })
	end
	table.insert(right, { " ─", border_hl })

	local function width(chunks)
		local w = 0
		for _, chunk in ipairs(chunks) do
			w = w + vim.api.nvim_strwidth(chunk[1])
		end
		return w
	end
	local total = vim.api.nvim_win_get_width(win)
	local fill = total - width(left) - width(right)
	if fill < 1 then
		return left
	end
	local out = left
	table.insert(out, { string.rep("─", fill), border_hl })
	vim.list_extend(out, right)
	return out
end

function M.render_log_title()
	if utils.window.valid(state.win) then
		detail_ui.set_content_title(log_title())
	end
end

function M.render_log()
	if not utils.window.valid(state.win) or not utils.buffer.valid(state.buf) then
		return
	end
	-- log_view sets the window's highlights itself (dark log background +
	-- focus-coloured border), so only the title goes through the host.
	log_view.render()
	M.render_log_title()
end

function M.render()
	M.render_header()
	M.render_log()
end

return M
