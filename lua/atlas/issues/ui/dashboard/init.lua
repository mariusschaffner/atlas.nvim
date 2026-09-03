local M = {}

local dashboard_host = require("atlas.ui.dashboard")
local dashboard_tabs = require("atlas.ui.dashboard_tabs")
local ui_state = require("atlas.ui.state")
local statusline = require("atlas.ui.statusline")
local ns = vim.api.nvim_create_namespace("atlas.ui")

---@param buf integer
---@param spans table[]
local function apply_spans(buf, spans)
	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	for _, span in ipairs(spans) do
		vim.api.nvim_buf_set_extmark(buf, ns, span.line, span.start_col, {
			end_row = span.line,
			end_col = span.end_col,
			hl_group = span.hl_group,
		})
	end
end

function M.render()
	local win = dashboard_host.win()
	local buf = dashboard_host.buf()
	if win == nil or buf == nil then
		return
	end

	local width = vim.api.nvim_win_get_width(win)

	local tab_lines, tab_spans = dashboard_tabs.render(dashboard_host.domain(), width)
	local body_lines, body_spans, body_line_map = require("atlas.issues.ui.dashboard.renderer").render({
		width = width,
	})

	local lines = vim.list_extend({}, tab_lines)
	vim.list_extend(lines, body_lines)

	local spans = vim.list_extend({}, tab_spans)
	local offset = #tab_lines
	for _, span in ipairs(body_spans) do
		table.insert(spans, {
			line = span.line + offset,
			start_col = span.start_col,
			end_col = span.end_col,
			hl_group = span.hl_group,
		})
	end

	local line_map = {}
	for lnum, entry in pairs(body_line_map) do
		line_map[lnum + offset] = entry
	end
	ui_state.line_map = line_map

	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	apply_spans(buf, spans)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
end

---@param issue Issue
local function open_detail(issue)
	local state = require("atlas.issues.state")
	local controller = require("atlas.issues.ui.dashboard.controller")
	require("atlas.issues.ui.detail").open(issue, {
		provider = state.provider,
		on_update = function(updated, result)
			if result then
				controller.apply_action_result(result)
			elseif updated then
				controller.update_issue(updated)
			end
		end,
	})
end

---@param item { kind: string, _issue: Issue|nil }|nil
function M.select(item)
	local detail = require("atlas.issues.ui.detail")
	if detail.is_open() and type(item) == "table" and item.kind == "issue" and type(item._issue) == "table" then
		open_detail(item._issue)
	end
end

function M.toggle_detail()
	local detail = require("atlas.issues.ui.detail")
	if detail.is_open() then
		detail.close()
		return
	end
	local item = require("atlas.ui.navigation").current_item()
	if type(item) == "table" and item.kind == "issue" and type(item._issue) == "table" then
		open_detail(item._issue)
	end
end

---@param provider IssuesProvider
---@param opts? { initial_view?: IssuesViewConfig }
function M.init(provider, opts)
	local state = require("atlas.issues.state")
	local controller = require("atlas.issues.ui.dashboard.controller")
	local keymaps = require("atlas.issues.ui.dashboard.keymaps")
	if state.provider ~= provider then
		state.current_user = nil
	end
	state.provider = provider
	state.provider_views = provider.views()
	state.current_view = nil

	local notifications = require("atlas.ui.notifications")
	notifications.set_provider(provider)
	state.error = nil
	state.set_issues({})
	state.collapsed_issue_keys = {}

	local capabilities = provider.capabilities
	local ui = capabilities.ui
	if ui and ui.setup then
		ui.setup()
	end

	state.views = state.provider_views
	state.active_view = (opts and opts.initial_view) or state.views[1]
	state.filter_text = require("atlas.ui.filter_query").serialize(state.active_view, { domain = "issues" })

	statusline.clear_items()

	local buf = dashboard_host.buf()
	if buf ~= nil then
		keymaps.register(buf, state.views)
	end

	if state.active_view == nil then
		state.error = "No issues view configured"
		M.render()
		return
	end

	M.render()
	controller.switch_view(state.active_view)

	if capabilities.notifications then
		notifications.refresh({ force_load = false, on_done = M.render })
	end
end

--- Re-activates an already-initialized dashboard (e.g. switching back to this
--- tab) without resetting filters, scroll position, or already-loaded issues.
---@param provider IssuesProvider
function M.activate(provider)
	local state = require("atlas.issues.state")
	local keymaps = require("atlas.issues.ui.dashboard.keymaps")
	state.provider = provider

	local buf = dashboard_host.buf()
	if buf ~= nil then
		keymaps.register(buf, state.views)
	end

	M.render()
	require("atlas.ui.navigation").focus_first_item()
end

return M
