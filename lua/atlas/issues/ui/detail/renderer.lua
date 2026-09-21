local M = {}

local utils = require("atlas.ui.shared.utils")
local spinner = require("atlas.ui.components.spinner")
local header = require("atlas.issues.ui.detail.components.header")
local tabs = require("atlas.ui.components.tabs")
local state = require("atlas.issues.ui.detail.state")
local detail_ui = require("atlas.ui.detail")
local inline_edit = require("atlas.ui.inline_edit")
local highlights = require("atlas.ui.shared.highlights")

local ns = vim.api.nvim_create_namespace("atlas.issues.provider_detail")
local header_ns = vim.api.nvim_create_namespace("atlas.issues.provider_detail.header")

local PADDING_X = 1

---@param buf integer
---@param lines string[]
local function set_lines(buf, lines)
	if buf == nil or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
end

---@return IssuesDetailHeaderField|nil
local function linked_mr_field()
	local value = state.linked_merge_requests
	if value == nil then
		return nil
	end
	local core = state.provider and state.provider.capabilities.core
	local has_hint = core and core.fetch_linked_merge_requests ~= nil
	-- Navigable (via "gp"), not editable: no highlighted border, just the
	-- hint prefix in the title.
	local label = utils.field_hint_label("issues.go_to_pull", "Linked MR", has_hint)

	if value == "loading" then
		return { label = label, value = spinner.with_text("Loading..."), hl = "AtlasTextMuted" }
	end
	if type(value) == "string" then
		return { label = label, value = value, hl = "AtlasLogError" }
	end
	if #value == 0 then
		return { label = label, value = "None", hl = "AtlasTextMuted" }
	end

	local parts, spans, cursor = {}, {}, 0
	for i, mr in ipairs(value) do
		local token = "!" .. tostring(mr.id)
		table.insert(parts, token)
		local hl = mr.state == "merged" and "AtlasTextPositive"
			or (mr.state == "closed" and "AtlasLogError" or "AtlasTextMuted")
		table.insert(spans, { start_col = cursor, end_col = cursor + #token, hl_group = hl })
		cursor = cursor + #token + (i < #value and 2 or 0)
	end
	return { label = label, value = table.concat(parts, ", "), hl = spans }
end

---@return IssuesDetailHeaderField|nil
local function linked_branches_field()
	local value = state.linked_branches
	if value == nil then
		return nil
	end
	local core = state.provider and state.provider.capabilities.core
	local can_create = core and core.create_branch ~= nil and core.fetch_project_branches ~= nil

	if value == "loading" then
		return { label = "Linked Branches", value = spinner.with_text("Loading..."), hl = "AtlasTextMuted" }
	end
	if type(value) == "string" then
		return { label = "Linked Branches", value = value, hl = "AtlasLogError" }
	end
	if #value == 0 then
		-- "gb" only creates a branch when none is linked yet (see
		-- issues.create_branch's guard in ui/detail/keymaps.lua): editable
		-- (highlighted border) here, but greyed out below once a branch
		-- already exists and the binding becomes a no-op.
		local label = utils.field_hint_label("issues.create_branch", "Linked Branches", can_create)
		return { label = label, value = "None", hl = "AtlasTextMuted", editable = can_create }
	end

	local parts, spans, cursor = {}, {}, 0
	for i, branch in ipairs(value) do
		local name = tostring(branch.name)
		table.insert(parts, name)
		local hl = highlights.dynamic_for(name) or "AtlasTextMuted"
		table.insert(spans, { start_col = cursor, end_col = cursor + #name, hl_group = hl })
		cursor = cursor + #name + (i < #value and 2 or 0)
	end
	return { label = "Linked Branches", value = table.concat(parts, ", "), hl = spans }
end

---@param issue Issue
---@param tab_items IssuesDetailTabDefinition[]
---@param width integer
---@return string[] lines
---@return table[] highlights
---@return table<string, AtlasFieldBoxRegion> regions
local function render_header(issue, tab_items, width)
	local lines, spans = {}, {}
	local details = state.current_details
	local provider_detail = state.provider_detail
	local provider_fields = provider_detail
			and provider_detail.header_fields
			and provider_detail.header_fields(issue, details, state.details_loading)
		or {}
	local status_badge = provider_detail and provider_detail.title_status and provider_detail.title_status(issue) or nil

	-- Three columns: Author/Assignee, Labels/Milestone, Linked MR/Linked Branches.
	local left_fields = {}
	utils.insert_if(left_fields, provider_fields.author)
	utils.insert_if(left_fields, provider_fields.assignee)

	local middle_fields = {}
	utils.insert_if(middle_fields, provider_fields.labels)
	utils.insert_if(middle_fields, provider_fields.milestone)

	local right_fields = {}
	utils.insert_if(right_fields, linked_mr_field())
	utils.insert_if(right_fields, linked_branches_field())

	local header_lines, header_spans, header_regions =
		header.render(issue, width, left_fields, middle_fields, right_fields, status_badge)
	utils.append_block(lines, spans, { lines = header_lines, highlights = header_spans })

	return lines, spans, header_regions or {}
end

--- Whether the description field (the "overview" tab's content) can be
--- edited right now -- drives the content box's editable border color, same
--- signal `register_edit_keymap` uses to decide whether "i" does anything.
---@return boolean
local function description_editable()
	local core = state.provider and state.provider.capabilities.core
	return state.current_tab == "overview" and core ~= nil and core.update_description ~= nil
end

--- The content box's current border color -- reused for both the actual
--- border (`detail_ui.set_content_border`) and the title's non-label
--- characters, so the "-" separators/leading dash match the border instead
--- of sitting at the default `FloatTitle` color.
---@return string
local function content_border_hl()
	return description_editable() and "AtlasFieldBoxBorderEditable" or "AtlasBorder"
end

---@param tab_items IssuesDetailTabDefinition[]
---@param active_tab string
---@return { [1]: string, [2]: string }[]
function M.title_chunks(tab_items, active_tab)
	if #tab_items <= 1 then
		return {}
	end
	return tabs.title_chunks(tab_items, active_tab, {
		active_hl = "AtlasDetailTabActive",
		inactive_hl = "AtlasTextMuted",
		gap = " - ",
		border_hl = content_border_hl(),
	})
end

---@param tab_items IssuesDetailTabDefinition[]
---@param get_tab_module fun(key: string|nil): IssuesDetailTabModule|nil
function M.render(tab_items, get_tab_module)
	local buf = state.buf
	local win = state.win
	if buf == nil or win == nil then
		return
	end
	if not vim.api.nvim_buf_is_valid(buf) or not vim.api.nvim_win_is_valid(win) then
		return
	end

	local issue = state.current_issue
	local header_win = state.header_win
	local header_buf = state.header_buf
	local has_header = utils.window.valid(header_win) and utils.buffer.valid(header_buf)

	if has_header then
		local header_lines, header_spans, header_regions = {}, {}, {}
		if issue ~= nil then
			header_lines, header_spans, header_regions = render_header(issue, tab_items, vim.api.nvim_win_get_width(header_win))
		end
		set_lines(header_buf, header_lines)
		utils.apply_spans(header_buf, header_ns, header_spans)
		state.header_regions = header_regions
		detail_ui.resize_header(#header_lines)
	end

	detail_ui.set_content_title(M.title_chunks(tab_items, state.current_tab))

	local footer_chunks
	if description_editable() then
		-- Matches the border color exactly, in both states (editable-blue while
		-- viewing, editing-orange once `gE`/"i" opens the inline editor) --
		-- inline_edit.lua sets the border directly while editing, bypassing
		-- content_border_hl(), so that state has to be checked here too.
		local hl = inline_edit.is_active(buf) and "AtlasFieldBoxBorderEditing" or content_border_hl()
		-- Leading "─ " mirrors the top title's own border-dash prefix
		-- (tabs.title_chunks), so the hint aligns with the title above it.
		footer_chunks = {
			{ "─ ", hl },
			{ utils.field_hint_label("ui.edit_description", "Edit", true), hl },
		}
	end
	detail_ui.set_content_footer(footer_chunks)

	if inline_edit.is_active(buf) then
		-- Editing owns the border color (AtlasFieldBoxBorderEditing) until it
		-- finishes; don't let an unrelated re-render (spinner tick, header
		-- update, ...) stomp it back to the merely-editable color mid-edit.
		return
	end
	detail_ui.set_content_border(content_border_hl())

	local width = vim.api.nvim_win_get_width(win)
	local lines = {}
	local spans = {}

	if issue == nil then
		if state.issue_loading then
			utils.push(lines, spans, spinner.with_text("Loading issue..."), "AtlasTextMuted", PADDING_X)
		else
			lines = { "", "  Nothing selected..." }
		end
		state.line_map = {}
	else
		local details = state.current_details
		local tab_mod = get_tab_module(state.current_tab)

		if tab_mod and tab_mod.render then
			local tab_lines, tab_spans, tab_line_map = tab_mod.render(issue, details, width)
			lines, spans = tab_lines, tab_spans
			state.line_map = tab_line_map or {}
			if details == nil and state.current_tab == "overview" then
				if #lines > 0 then
					table.insert(lines, "")
				end
				local text = state.details_loading and spinner.with_text("Loading issue details...")
					or "Issue details unavailable."
				utils.push(lines, spans, text, "AtlasTextMuted", PADDING_X)
			end
		elseif details == nil then
			local text = state.details_loading and spinner.with_text("Loading issue...") or "Issue details unavailable."
			utils.push(lines, spans, text, "AtlasTextMuted", PADDING_X)
			state.line_map = {}
		else
			lines = { "  Unknown tab: " .. tostring(state.current_tab) }
			state.line_map = {}
		end
	end

	set_lines(buf, lines)
	utils.apply_spans(buf, ns, spans)
end

return M
