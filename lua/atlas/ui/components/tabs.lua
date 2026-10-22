local utils = require("atlas.ui.shared.utils")

local M = {}

---@param items { key: string, label: string, icon: AtlasIconStyle|nil }[]
---@param active_tab string
---@param width integer
---@param opts? { inactive_hl?: string, active_hl?: string, gap?: string, divider?: boolean, divider_hl?: string, padding_x?: integer }
---@return string[] lines
---@return table[] spans
function M.render(items, active_tab, width, opts)
	opts = opts or {}
	local inactive_hl = opts.inactive_hl or "AtlasTextMuted"
	local active_hl = opts.active_hl
	local gap = opts.gap or " "
	local padding_x = math.max(0, tonumber(opts.padding_x) or 0)
	local padding = string.rep(" ", padding_x)

	local available = math.max(1, width - padding_x)
	local line = ""
	local spans = {}
	local col = 0

	for i, tab in ipairs(items) do
		local icon = tab.icon and tab.icon.icon or ""
		local icon_text = icon ~= "" and (icon .. " ") or ""
		local part = string.format("%s%s ", icon_text, tab.label)
		line = line .. part

		---@type string|nil
		local hl = inactive_hl
		if tab.key == active_tab then
			hl = active_hl
		end
		if type(hl) == "string" and hl ~= "" then
			table.insert(spans, {
				line = 0,
				start_col = col,
				end_col = col + #part,
				hl_group = hl,
			})
		end
		local icon_hl = tab.icon and tab.icon.hl_group or nil
		if icon ~= "" and icon_hl and icon_hl ~= "" then
			table.insert(spans, {
				line = 0,
				start_col = col,
				end_col = col + #icon,
				hl_group = icon_hl,
			})
		end
		col = col + #part

		if i < #items then
			line = line .. gap
			col = col + #gap
		end
	end

	if vim.api.nvim_strwidth(line) > available then
		line = utils.truncate(line, available)
	end
	local visible_spans = {}
	for _, span in ipairs(spans) do
		span.end_col = math.min(span.end_col, #line)
		if span.start_col < span.end_col then
			table.insert(visible_spans, span)
		end
	end
	spans = visible_spans

	local lines = { padding .. line }
	if padding_x > 0 then
		for _, span in ipairs(spans) do
			if (span.line or 0) == 0 then
				span.start_col = span.start_col + padding_x
				span.end_col = span.end_col + padding_x
			end
		end
	end

	if opts.divider ~= false then
		local divider = string.rep("─", math.max(1, width))
		table.insert(lines, divider)
		table.insert(spans, {
			line = 1,
			start_col = 0,
			end_col = #divider,
			hl_group = opts.divider_hl or "AtlasTextMuted",
		})
	end

	return lines, spans
end

--- Builds `{text, hl_group}` chunks suitable for a floating window's native
--- `title` (see `nvim_open_win`'s `title`). Every chunk's `hl_group` slot is
--- always a real string ("" for "no highlight") -- `{text, nil}` silently
--- truncates to a 1-element array under Neovim's title-chunk validation.
--- Icons are deliberately omitted here (unlike `M.render`'s text row) --
--- native title chunks are meant to read as plain tab labels. The leading
--- "─ " mirrors `bordered_box.lua`'s own `╭─ Title` pattern (border dash,
--- then a space) instead of plain padding, so the title starts the same way
--- every other field box's title does; like `bordered_box.lua`, every
--- non-label character (leading dash, gaps, trailing space) is colored with
--- `opts.border_hl` -- the box's own current border color -- rather than
--- left at the default `FloatTitle` highlight, which wouldn't track the
--- border's editable/editing color changes.
---
--- With `opts.right_text` and `opts.width` (the window's inner width), the
--- title is padded with border dashes so `right_text` sits right-aligned at
--- the end of the top border, e.g. the MR view's "2 of 7 viewed"
--- (DESIGN-merge-request-view.md §6).
---@param items { key: string, label: string, icon: AtlasIconStyle|nil }[]
---@param active_tab string
---@param opts? { inactive_hl?: string, active_hl?: string, gap?: string, border_hl?: string, right_text?: string, right_hl?: string, width?: integer }
---@return { [1]: string, [2]: string }[]
function M.title_chunks(items, active_tab, opts)
	opts = opts or {}
	local inactive_hl = opts.inactive_hl or "AtlasTextMuted"
	local active_hl = opts.active_hl or ""
	local gap = opts.gap or " "
	local border_hl = opts.border_hl or ""

	local chunks = { { "─ ", border_hl } }
	for i, tab in ipairs(items) do
		local hl = tab.key == active_tab and active_hl or inactive_hl
		table.insert(chunks, { tab.label, hl })
		if i < #items then
			table.insert(chunks, { gap, border_hl })
		end
	end
	table.insert(chunks, { " ", border_hl })

	local right_text = opts.right_text
	if right_text and right_text ~= "" and opts.width then
		local used = 0
		for _, chunk in ipairs(chunks) do
			used = used + vim.api.nvim_strwidth(chunk[1])
		end
		-- " right_text ─" at the end, the gap filled with border dashes.
		local fill = opts.width - used - vim.api.nvim_strwidth(right_text) - 3
		if fill >= 1 then
			table.insert(chunks, { string.rep("─", fill) .. " ", border_hl })
			table.insert(chunks, { right_text, opts.right_hl or inactive_hl })
			table.insert(chunks, { " ─", border_hl })
		end
	end

	return chunks
end

return M
