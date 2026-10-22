local M = {}

local utils = require("atlas.ui.shared.utils")
local state = require("atlas.pulls.ui.detail.state")
local detail_header = require("atlas.ui.components.detail_header")
local strip = require("atlas.ui.components.strip")
local detail_data = require("atlas.pulls.ui.detail.data")
local detail_tabs = require("atlas.pulls.ui.components.tabs")
local resolver = require("atlas.core.keymaps")
local spinner = require("atlas.ui.components.spinner")
local presentation = require("atlas.pulls.ui.presentation")
local detail_ui = require("atlas.ui.detail")
local inline_edit = require("atlas.ui.inline_edit")
local inline_field_edit = require("atlas.ui.inline_field_edit")
local conversation_state = require("atlas.pulls.ui.detail.tabs.conversation.state")

local ns = vim.api.nvim_create_namespace("atlas.provider_detail")
local header_ns = vim.api.nvim_create_namespace("atlas.provider_detail.header")

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

---@param action_id string
---@return string|nil
local function key_hint(action_id)
	local keys = resolver.resolve(action_id)
	return keys and keys[1] or nil
end

---@param pr PullRequest
---@return string
local function breadcrumb(pr)
	local path = tostring(pr.repo_full_name or "")
	local parts = vim.split(path, "/", { plain = true, trimempty = true })
	local project = parts[#parts] or path
	table.remove(parts)
	local namespace = table.concat(parts, "/")
	local left = namespace ~= "" and (namespace .. " / " .. project) or project
	return string.format("%s › merge requests › !%s", left, tostring(pr.id or ""))
end

---@param pr PullRequest
---@return string
local function meta_right(pr)
	local author = presentation.user_handle(pr.author)
	local rel = utils.relative_time(pr.updated_on)
	local updated = rel ~= "-" and (rel .. " ago") or "-"
	return string.format("opened by %s · updated %s", author, updated)
end

local GATE_GLYPHS = { passed = "✓", pending = "◷", failed = "✗" }
local GATE_HL = { passed = "AtlasGreen", pending = "AtlasYellow", failed = "AtlasRed" }
local MERGE_NODE = {
	ready = { glyph = "⇣", hl = "AtlasGreen", label_hl = "AtlasGreen" },
	blocked = { glyph = "⇣", hl = "AtlasTextMuted", label_hl = "AtlasTextMuted" },
	merged = { glyph = "●", hl = "AtlasPurple", label_hl = "AtlasPurple" },
	closed = { glyph = "✗", hl = "AtlasTextMuted", label_hl = "AtlasTextMuted" },
}

--- "gM merge"-style hint chunks: the key in the key-hint colour, the word dim.
---@param action_id string
---@param word string
---@return AtlasStripChunk[]
local function key_chunks(action_id, word)
	local key = key_hint(action_id)
	if key == nil then
		return { { word, "AtlasTextMuted" } }
	end
	return { { key, "AtlasKeyHint" }, { " " .. word, "AtlasTextMuted" } }
end

--- The readiness strip (DESIGN-merge-request-view.md §4): one node per merge
--- gate plus the merge node, labels under them, and key/reason hints.
---@param width integer
---@return string[] lines
---@return AtlasUIHighlight[] highlights
local function render_strip(width)
	if state.merge_checks == "loading" or state.reviewers == "loading" then
		local text = spinner.with_text("Loading merge status...")
		return { text }, { { line = 0, start_col = 0, end_col = #text, hl_group = "AtlasTextMuted" } }
	end
	local gates = detail_data.readiness()
	if gates == nil then
		local text = type(state.merge_checks) == "string" and state.merge_checks or "Merge status unavailable"
		return { text }, { { line = 0, start_col = 0, end_col = #text, hl_group = "AtlasTextMuted" } }
	end

	local nodes = {}
	for i, gate in ipairs(gates.gates) do
		local blocking = gates.blocking == i
		local hint
		if gate.key == "pipeline" and key_hint("pulls.open_pipeline") then
			hint = key_chunks("pulls.open_pipeline", "pipeline")
			if blocking and gate.reason then
				table.insert(hint, { " · " .. gate.reason, "AtlasTextMuted" })
			end
		elseif blocking and gate.reason then
			hint = { { gate.reason, "AtlasTextMuted" } }
		end
		table.insert(nodes, {
			glyph = GATE_GLYPHS[gate.state],
			hl = GATE_HL[gate.state],
			segment_hl = gate.state == "passed" and "AtlasGreen" or "AtlasBorder",
			label = { { gate.label, blocking and GATE_HL[gate.state] or nil } },
			hint = hint,
		})
	end

	local merge = gates.merge
	local style = MERGE_NODE[merge.state] or MERGE_NODE.blocked
	local merge_hint
	if merge.state == "ready" then
		merge_hint = key_chunks("pulls.merge", "merge")
	elseif merge.state == "blocked" then
		merge_hint = key_chunks("pulls.merge", "blocked")
		if merge.reason then
			table.insert(merge_hint, 1, { merge.reason .. " · ", "AtlasTextMuted" })
		end
	end
	table.insert(nodes, {
		glyph = style.glyph,
		hl = style.hl,
		label = { { merge.label, style.label_hl } },
		hint = merge_hint,
	})

	return strip.render_nodes(nodes, width)
end

---@param pr PullRequest
---@param outer_width integer
---@return string[] lines
---@return AtlasUIHighlight[] highlights
---@return table<string, AtlasFieldBoxRegion> regions
local function render_header(pr, outer_width)
	local pill = presentation.pr_state_pill(pr.state)
	local strip_lines, strip_spans = render_strip(detail_header.inner_width(outer_width))
	return detail_header.render({
		breadcrumb = breadcrumb(pr),
		meta_right = meta_right(pr),
		state_label = pill.text,
		state_hl = pill.hl,
		title = pr.title or "",
		iid_text = "!" .. tostring(pr.id or ""),
	}, outer_width, { lines = strip_lines, highlights = strip_spans })
end

--- Whether the description field (the "overview" tab's content) can be
--- edited right now -- drives the content box's editable border color, same
--- signal the overview tab module's `edit_description_keys()` uses to decide
--- whether "i" does anything. Like the header fields (title, assignee,
--- reviewers, delete-source-branch), editing is only available while the PR
--- is open or a draft.
---@return boolean
local function description_editable()
	if state.current_tab ~= "overview" then
		return false
	end
	if not presentation.is_open_or_draft(state.current_pr) then
		return false
	end
	local provider = state.provider
	local capability = provider and provider.capabilities.actions
	for _, action in ipairs(capability and capability.items or {}) do
		if action.id == "edit_description" then
			return true
		end
	end
	return false
end

--- The Activity tab's own border color -- blue by default whenever the tab
--- supports adding a top-level comment (mirrors the description tab always
--- being blue while editable), escalating to orange only once actively
--- typing a new top-level comment. A reply keeps its own comment box's
--- border as the "is this actively being edited" signal, so the global
--- border just stays blue for those.
---@return string|nil
local function conversation_border_hl()
	if state.current_tab ~= "conversation" then
		return nil
	end
	local comments = state.provider and state.provider.capabilities.comments
	if comments == nil or comments.add_comment == nil then
		return nil
	end
	if not presentation.is_open_or_draft(state.current_pr) then
		return nil
	end
	local composing = conversation_state.composing
	if composing ~= nil and composing.kind == "add" and inline_field_edit.is_active() then
		return "AtlasFieldBoxBorderEditing"
	end
	return "AtlasFieldBoxBorderEditable"
end

--- The content box's current border color -- reused for both the actual
--- border (`detail_ui.set_content_border`) and the title's non-label
--- characters, so the "-" separators/leading dash match the border instead
--- of sitting at the default `FloatTitle` color.
---@return string
local function content_border_hl()
	return conversation_border_hl() or (description_editable() and "AtlasFieldBoxBorderEditable" or "AtlasBorder")
end

--- Whether the Activity tab's "[i] - Add" footer hint should show: only on
--- that tab, only when the provider supports adding a top-level comment, and
--- not while a comment is already being inline-edited/composed (that box
--- already shows its own Save/Cancel hint on its own border).
---@return boolean
local function conversation_addable()
	local comments = state.provider and state.provider.capabilities.comments
	return state.current_tab == "conversation"
		and comments ~= nil
		and comments.add_comment ~= nil
		and presentation.is_open_or_draft(state.current_pr)
		and not inline_field_edit.is_active()
end

---@param tab_items PullsDetailTab[]
---@param active_tab string
---@return { [1]: string, [2]: string }[]
function M.title_chunks(tab_items, active_tab)
	if #tab_items <= 1 then
		return {}
	end
	return detail_tabs.title_chunks(tab_items, active_tab, content_border_hl())
end

---@param tab_items PullsDetailTab[]
---@param get_tab_module fun(key: string): PullsDetailTabModule|nil
function M.render(tab_items, get_tab_module)
	local buf = state.buf
	local win = state.win
	if buf == nil or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	if win == nil or not vim.api.nvim_win_is_valid(win) then
		return
	end

	local pr = state.current_pr
	local header_win = state.header_win
	local header_buf = state.header_buf
	local has_header = utils.window.valid(header_win) and utils.buffer.valid(header_buf)
	local tab_mod = pr ~= nil and get_tab_module(state.current_tab) or nil

	if has_header then
		local header_lines, header_spans, header_regions = {}, {}, {}
		if pr ~= nil then
			header_lines, header_spans, header_regions = render_header(pr, vim.api.nvim_win_get_width(header_win))
		end
		set_lines(header_buf, header_lines)
		utils.apply_spans_clamped(header_buf, header_ns, header_spans)
		state.header_regions = header_regions
		detail_ui.resize_header(#header_lines)
	end

	detail_ui.set_content_title(M.title_chunks(tab_items, state.current_tab))

	-- Leading "─ " mirrors the top title's own border-dash prefix
	-- (tabs.title_chunks), so the hint aligns with the title above it. No
	-- "[i] - Edit" hint on the Description tab (DESIGN-merge-request-view.md §2).
	local footer_chunks
	if inline_edit.is_active(buf) then
		local hl = "AtlasFieldBoxBorderEditing"
		footer_chunks = {
			{ "─ ", hl },
			{ utils.field_hint_label("ui.submit", "Save", true), hl },
			{ " ── ", hl },
			{ utils.field_hint_label("ui.field_edit.close", "Cancel", true), hl },
			{ " ", hl },
		}
	elseif conversation_addable() then
		local hl = content_border_hl()
		footer_chunks = {
			{ "─ ", hl },
			{ utils.field_hint_label("ui.comments.add", "Add", true), "AtlasFooterInfo" },
			{ " ", hl },
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

	if pr == nil then
		if state.pr_loading then
			utils.push(lines, spans, spinner.with_text("Loading pull request..."), "AtlasTextMuted", PADDING_X)
		else
			lines = { "", "  Nothing selected..." }
		end
		state.line_map = {}
	else
		if tab_mod then
			local tab_lines, tab_spans, tab_line_map = tab_mod.render(pr, state.current_details, width)
			lines, spans = tab_lines, tab_spans
			state.line_map = tab_line_map or {}
		else
			lines = { "  Unknown tab: " .. tostring(state.current_tab) }
			state.line_map = {}
		end
	end

	set_lines(buf, lines)
	utils.apply_spans_clamped(buf, ns, spans)
end

return M
