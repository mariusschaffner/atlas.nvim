-- Builds one rendered line out of `{text, hl}` segments while tracking both
-- byte offsets (what extmark highlight spans need) and display width (what
-- alignment needs -- box-drawing glyphs, `·`, `▎`, ... are multi-byte but one
-- column wide). Shared by the timeline/composer components so none of them
-- re-derive byte-vs-display bookkeeping by hand.
local M = {}

local strwidth = vim.fn.strdisplaywidth

---@class AtlasLine
---@field parts string[]
---@field spans { start_col: integer, end_col: integer, hl_group: string }[]
---@field bytes integer
---@field width integer
local Line = {}
Line.__index = Line

---@return AtlasLine
function M.new()
	return setmetatable({ parts = {}, spans = {}, bytes = 0, width = 0 }, Line)
end

---@param text string|nil
---@param hl string|nil
---@return AtlasLine
function Line:add(text, hl)
	if text == nil or text == "" then
		return self
	end
	if hl then
		table.insert(self.spans, { start_col = self.bytes, end_col = self.bytes + #text, hl_group = hl })
	end
	table.insert(self.parts, text)
	self.bytes = self.bytes + #text
	self.width = self.width + strwidth(text)
	return self
end

--- Pads with spaces up to display column `col` (no-op when already past it).
---@param col integer
---@param hl string|nil
---@return AtlasLine
function Line:pad_to(col, hl)
	if col > self.width then
		self:add(string.rep(" ", col - self.width), hl)
	end
	return self
end

--- Right-aligns `text` so it ends exactly at display column `width`, padding
--- the gap with spaces (at least one when `text` is non-empty).
---@param text string
---@param hl string|nil
---@param width integer
---@param gap_hl string|nil
---@return AtlasLine
function Line:right(text, hl, width, gap_hl)
	local text_width = strwidth(text)
	local target = math.max(self.width + (text ~= "" and 1 or 0), width - text_width)
	self:pad_to(target, gap_hl)
	return self:add(text, hl)
end

---@param line_idx integer|nil 0-indexed line the returned spans are stamped with (default 0).
---@return string text
---@return AtlasUIHighlight[] spans
function Line:finish(line_idx)
	local spans = {}
	for _, span in ipairs(self.spans) do
		table.insert(spans, {
			line = line_idx or 0,
			start_col = span.start_col,
			end_col = span.end_col,
			hl_group = span.hl_group,
		})
	end
	return table.concat(self.parts), spans
end

--- Appends a finished line onto `lines`/`spans`, stamping its spans with the
--- row it lands on.
---@param lines string[]
---@param spans AtlasUIHighlight[]
---@return integer row 0-indexed row the line was appended at.
function Line:push(lines, spans)
	local row = #lines
	local text, line_spans = self:finish(row)
	table.insert(lines, text)
	vim.list_extend(spans, line_spans)
	return row
end

--- Appends a rendered block (lines + 0-based spans) onto `lines`/`spans`,
--- shifting every span by the block's insertion offset.
---@param lines string[]
---@param spans AtlasUIHighlight[]
---@param block_lines string[]
---@param block_spans AtlasUIHighlight[]
---@return integer base 0-indexed row the block starts at.
function M.splice(lines, spans, block_lines, block_spans)
	local base = #lines
	vim.list_extend(lines, block_lines)
	for _, span in ipairs(block_spans) do
		local shifted = vim.deepcopy(span)
		shifted.line = base + span.line
		table.insert(spans, shifted)
	end
	return base
end

return M
