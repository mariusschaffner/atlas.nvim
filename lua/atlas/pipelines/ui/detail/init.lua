local M = {}

local detail_ui = require("atlas.ui.detail")
local renderer = require("atlas.pipelines.ui.detail.renderer")
local notify = require("atlas.core.notify")
local request_scope = require("atlas.core.requests")
local state = require("atlas.pipelines.ui.detail.state")

local function render()
	renderer.render()
end

local function render_if_open()
	if detail_ui.is_showing("pipelines") then
		render()
	end
end

---@param left Pipeline|nil
---@param right Pipeline|nil
---@return boolean
local function same_pipeline(left, right)
	return left ~= nil and right ~= nil and tostring(left.key or "") == tostring(right.key or "")
end

---@param pipeline Pipeline
---@param force_refresh boolean
local function load_details(pipeline, force_refresh)
	local provider = state.provider
	local fetch = provider and provider.capabilities.core.fetch_pipeline_details
	if not fetch then
		return
	end

	state.details_loading = true
	state.requests.run(function(done)
		return fetch(pipeline, { force_load = force_refresh }, done)
	end, function(detailed, err)
		if not same_pipeline(state.current_pipeline, pipeline) then
			return
		end
		state.details_loading = false
		if detailed == nil then
			notify.error(tostring(err or "Failed to load pipeline details"))
		else
			state.current_pipeline = detailed
		end
		render_if_open()
	end)
end

local function cleanup()
	local buf = state.buf
	if buf and vim.api.nvim_buf_is_valid(buf) then
		require("atlas.pipelines.ui.detail.keymaps").remove(buf)
	end
	state.reset()
end

---@return boolean
function M.is_open()
	return detail_ui.is_showing("pipelines")
end

---@param pipeline Pipeline
---@param opts { force_refresh: boolean|nil }|nil
function M.select(pipeline, opts)
	if not M.is_open() then
		return
	end
	opts = opts or {}

	state.requests.cancel()
	state.requests = request_scope.new()
	state.current_pipeline = pipeline
	state.details_loading = false
	render()
	load_details(pipeline, opts.force_refresh == true)
end

---@param pipeline Pipeline
---@param opts { provider: PipelinesProvider|nil, force_refresh: boolean|nil }|nil
function M.open(pipeline, opts)
	opts = opts or {}
	local provider = opts.provider or state.provider
	if provider == nil then
		notify.error("Pipelines provider unavailable")
		return
	end

	state.win, state.buf, state.header_win, state.header_buf = detail_ui.open("pipelines", cleanup, render)
	state.provider = provider
	if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
		require("atlas.pipelines.ui.detail.keymaps").register(state.buf)
	end

	M.select(pipeline, { force_refresh = opts.force_refresh == true })
end

function M.close()
	if M.is_open() then
		detail_ui.close()
	end
end

return M
