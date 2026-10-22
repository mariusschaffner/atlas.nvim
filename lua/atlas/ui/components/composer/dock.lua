-- The docked "write a new comment…" composer pinned to the bottom of a
-- detail view's content window (via `atlas.ui.detail.set_content_dock`).
--
-- Collapsed:  ╭──────────────────────────────────────────────╮
--             │ MS › write a new comment…            c focus │
--             ╰──────────────────────────────────────────────╯
-- Expanded:   header (avatar, "Comment" chip, "Esc cancel"), the text area
--             (a `composer.session` float), a separator and the footer
--             (mode badge, key hints).
--
-- One dock at a time (there is only one detail view). Hosts reserve
-- `M.total_height()` trailing rows in their own buffer.
local M = {}

local detail_ui = require("atlas.ui.detail")
local avatar = require("atlas.ui.components.avatar")
local line_builder = require("atlas.ui.components.line")
local keyhints = require("atlas.ui.components.keyhints")
local frame = require("atlas.ui.components.composer.frame")
local session_mod = require("atlas.ui.components.composer.session")
local utils = require("atlas.ui.shared.utils")

local ns = vim.api.nvim_create_namespace("atlas.composer.dock")
local MIN_TEXT_ROWS = 3

---@class AtlasComposerDockOptions
---@field author string|nil Name the avatar chip is drawn for (current user).
---@field label string|nil Header chip, default "Comment".
---@field prompt string|nil Collapsed placeholder, default "write a new comment…".
---@field placeholder string|nil Expanded placeholder.
---@field focus_hints AtlasKeyHintSegment[]|nil Collapsed right-side hints ("c focus").
---@field hints AtlasKeyHintSegment[]|nil Expanded footer hints.
---@field completion AtlasMarkdownCompletionProvider|nil
---@field extra_keys AtlasComposerKeyBinding[]|nil
---@field on_submit fun(text: string, done: fun(ok: boolean, err: string|nil))
---@field on_resize (fun())|nil Called when `M.total_height()` changes, so the host re-renders its padding.

---@type { opts: AtlasComposerDockOptions, buf: integer, expanded: boolean, text_rows: integer, session: AtlasComposerSession|nil, mode: string, dirty: boolean, draft: string|nil }|nil
local active = nil

---@return integer
local function dock_width()
	local win = detail_ui.content_dock_win()
	if win then
		return vim.api.nvim_win_get_width(win)
	end
	return 60
end

---@param lines string[]
---@param spans AtlasUIHighlight[]
local function write(lines, spans)
	if active == nil or not vim.api.nvim_buf_is_valid(active.buf) then
		return
	end
	vim.api.nvim_set_option_value("modifiable", true, { buf = active.buf })
	vim.api.nvim_buf_set_lines(active.buf, 0, -1, false, lines)
	vim.api.nvim_set_option_value("modifiable", false, { buf = active.buf })
	utils.apply_spans(active.buf, ns, spans)
end

---@param width integer
---@return string[] lines, AtlasUIHighlight[] spans
local function render_collapsed(width)
	local opts = active.opts
	local line = line_builder.new()
	line:add(" ")
	local chip, chip_hl = avatar.chip(opts.author)
	line:add(chip, chip_hl)
	line:add(" › ", "AtlasComposerPrompt")
	line:add(opts.prompt or "write a new comment…", "AtlasComposerPromptPlaceholder")
	if opts.focus_hints then
		local hint = keyhints.render(opts.focus_hints)
		if hint ~= "" then
			line:pad_to(math.max(line.width + 2, width - vim.fn.strdisplaywidth(hint) - 1))
			keyhints.append(line, opts.focus_hints)
		end
	end
	local text, spans = line:finish(0)
	return { text }, spans
end

--- "Esc cancel" for the expanded header's right side, nil when the close
--- action has no key configured.
---@return AtlasTimelineEventSegment[]|nil
local function close_hint()
	local keys = require("atlas.core.keymaps").resolve("ui.field_edit.close")
	if not keys or not keys[1] then
		return nil
	end
	return {
		{ keyhints.format_key(keys[1]), "AtlasKeyHint" },
		{ " cancel", "AtlasKeyHintLabel" },
	}
end

---@param width integer
---@return string[] lines, AtlasUIHighlight[] spans, AtlasFieldBoxRegion region
local function render_expanded(width)
	local opts = active.opts
	local chip, chip_hl = avatar.chip(opts.author)
	return frame.render({
		indent = 0,
		width = width,
		bar = false,
		transparent = true,
		header_left = {
			{ chip, chip_hl },
			{ "  ", nil },
			{ " " .. (opts.label or "Comment") .. " ", "AtlasComposerChip" },
		},
		header_right = close_hint(),
		height = active.text_rows,
		placeholder = nil,
		mode = active.mode,
		hints = opts.hints,
		dirty = false,
		separator = true,
	})
end

---@return integer rows Interior rows the dock currently needs.
local function interior_rows()
	if active == nil then
		return 0
	end
	if not active.expanded then
		return 1
	end
	return frame.row_count({
		header_left = {},
		height = active.text_rows,
		separator = true,
	})
end

--- Total rows the dock covers at the bottom of the content window
--- (interior + its rounded border), 0 when no dock is attached.
---@return integer
function M.total_height()
	if active == nil then
		return 0
	end
	return interior_rows() + 2
end

---@return boolean
function M.is_attached()
	return active ~= nil
end

---@return boolean
function M.is_expanded()
	return active ~= nil and active.expanded
end

---@return AtlasFieldBoxRegion|nil
local function redraw()
	if active == nil then
		return nil
	end
	detail_ui.set_content_dock({
		buf = active.buf,
		height = interior_rows(),
		winhighlight = active.expanded and "Normal:Normal,NormalFloat:Normal,FloatBorder:AtlasComposerBorderActive"
			or "Normal:Normal,NormalFloat:Normal,FloatBorder:AtlasComposerBorder",
	})
	local width = dock_width()
	if active.expanded then
		local lines, spans, region = render_expanded(width)
		write(lines, spans)
		return region
	end
	local lines, spans = render_collapsed(width)
	write(lines, spans)
	return nil
end

---@param opts AtlasComposerDockOptions
function M.attach(opts)
	if active ~= nil then
		active.opts = opts
		redraw()
		return
	end
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
	active = {
		opts = opts,
		buf = buf,
		expanded = false,
		text_rows = MIN_TEXT_ROWS,
		session = nil,
		mode = "i",
		dirty = false,
	}
	redraw()
end

function M.detach()
	if active == nil then
		return
	end
	local current = active
	if current.session and current.session.is_open() then
		current.session.close()
	end
	active = nil
	detail_ui.set_content_dock(nil)
	if vim.api.nvim_buf_is_valid(current.buf) then
		pcall(vim.api.nvim_buf_delete, current.buf, { force = true })
	end
end

local function notify_resize()
	if active and active.opts.on_resize then
		active.opts.on_resize()
	end
end

local function collapse()
	if active == nil then
		return
	end
	active.expanded = false
	active.session = nil
	active.text_rows = MIN_TEXT_ROWS
	redraw()
	notify_resize()
end

--- Expands the dock and focuses its editor, optionally seeded with a draft
--- (e.g. coming back from the full-buffer editor).
---@param seed_text string|nil
function M.focus(seed_text)
	if active == nil then
		return
	end
	if active.session and active.session.is_open() then
		vim.api.nvim_set_current_win(active.session.win)
		return
	end
	active.expanded = true
	active.mode = "i"
	local region = redraw()
	notify_resize()
	local dock_win = detail_ui.content_dock_win()
	if region == nil or dock_win == nil then
		collapse()
		return
	end
	local opts = active.opts
	active.session = session_mod.start({
		anchor_win = dock_win,
		fixed_rows = true,
		region = region,
		seed_text = seed_text or "",
		placeholder = opts.placeholder,
		transparent = true,
		completion = opts.completion,
		max_height = 10,
		extra_keys = opts.extra_keys,
		on_submit = opts.on_submit,
		on_done = function()
			collapse()
		end,
		on_layout = function(height)
			if active == nil then
				return
			end
			active.text_rows = math.max(MIN_TEXT_ROWS, height)
			local new_region = redraw()
			notify_resize()
			if new_region and active.session then
				active.session.move(new_region)
			end
		end,
		on_state = function(state)
			if active == nil then
				return
			end
			active.mode = state.mode
			active.dirty = state.dirty
			redraw()
		end,
	})
end

--- The live editor session while expanded (for hosts' extra key callbacks).
---@return AtlasComposerSession|nil
function M.session()
	return active and active.session or nil
end

return M
