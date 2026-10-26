-- Full-width, cell-based strips drawn inside a detail view's header box: the
-- milestone view's date timeline (DESIGN-milestone-view.md §4) and the merge
-- request view's readiness strip (DESIGN-merge-request-view.md §4). Holds the
-- shared cell canvas (one cell = one display column, glyphs may be
-- multi-byte) plus the node strip layout: evenly spaced nodes joined by
-- segments, a label line and a hint line under them. Domain-agnostic: callers
-- hand in plain text/highlight data.
local M = {}

local ELLIPSIS = "…"

--- Splits `text` into its UTF-8 characters (each assumed 1 display column wide).
---@param text string
---@return string[]
local function chars(text)
	local out = {}
	for ch in tostring(text or ""):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
		table.insert(out, ch)
	end
	return out
end

--- Display width of `text`, counting one column per UTF-8 character.
---@param text string
---@return integer
function M.width(text)
	return #chars(text)
end

---@param width integer
---@return string[] cells
function M.cells(width)
	local cells = {}
	for i = 1, width do
		cells[i] = " "
	end
	return cells
end

--- Writes `text` one character per cell starting at `start_col`; characters
--- past the end of the strip are dropped.
---@param cells string[]
---@param start_col integer 0-indexed
---@param text string
function M.set_text(cells, start_col, text)
	for i, ch in ipairs(chars(text)) do
		local idx = start_col + i
		if cells[idx] then
			cells[idx] = ch
		end
	end
end

---@param cells string[]
---@param col integer 0-indexed
---@param glyph string
function M.set_glyph(cells, col, glyph)
	if cells[col + 1] then
		cells[col + 1] = glyph
	end
end

--- Concatenates `cells` into the rendered line, plus a `byte_range(from_col,
--- to_col)` helper mapping 0-indexed column ranges to byte offsets -- needed
--- because the strips' glyphs (│ ━ ─ ┃ ✓ ...) are multi-byte UTF-8, so a
--- column index and a byte offset aren't the same number.
---@param cells string[]
---@return string line
---@return fun(from_col: integer, to_col: integer): integer, integer byte_range
function M.finalize(cells)
	local parts, offsets = {}, {}
	local byte_pos = 0
	for i, cell in ipairs(cells) do
		offsets[i] = byte_pos
		table.insert(parts, cell)
		byte_pos = byte_pos + #cell
	end
	offsets[#cells + 1] = byte_pos
	local line = table.concat(parts)
	local function byte_range(from_col, to_col)
		from_col = math.max(0, math.min(#cells, from_col))
		to_col = math.max(0, math.min(#cells, to_col))
		return offsets[from_col + 1], offsets[to_col + 1]
	end
	return line, byte_range
end

--- Start columns of `n` evenly spaced nodes, each `node_width` cells wide:
--- the first flush left, the last flush right.
---@param n integer
---@param width integer
---@param node_width integer
---@return integer[] cols 0-indexed
function M.node_columns(n, width, node_width)
	local cols = {}
	if n <= 0 then
		return cols
	end
	if n == 1 then
		return { 0 }
	end
	local span = math.max(0, width - node_width)
	for i = 1, n do
		cols[i] = math.floor((i - 1) * span / (n - 1) + 0.5)
	end
	return cols
end

---@class AtlasStripChunk
---@field [1] string text
---@field [2] string|nil highlight group

---@param chunks AtlasStripChunk[]
---@return integer
local function chunks_width(chunks)
	local w = 0
	for _, chunk in ipairs(chunks) do
		w = w + M.width(chunk[1])
	end
	return w
end

--- Shortens `chunks` to `max` columns, ending in "…" when anything was cut.
---@param chunks AtlasStripChunk[]
---@param max integer
---@return AtlasStripChunk[]
local function truncate_chunks(chunks, max)
	if chunks_width(chunks) <= max then
		return chunks
	end
	if max <= 0 then
		return {}
	end
	local out, used = {}, 0
	local room = max - 1
	for _, chunk in ipairs(chunks) do
		if used >= room then
			break
		end
		local cs = chars(chunk[1])
		local take = math.min(#cs, room - used)
		table.insert(out, { table.concat(cs, "", 1, take), chunk[2] })
		used = used + take
	end
	local last_hl = (out[#out] or chunks[1])[2]
	table.insert(out, { ELLIPSIS, last_hl })
	return out
end

M.chunks_width = chunks_width
M.truncate_chunks = truncate_chunks

--- Shortens `text` to `max` columns, ending in "…" when anything was cut.
---@param text string
---@param max integer
---@return string
function M.truncate(text, max)
	local out = truncate_chunks({ { tostring(text or "") } }, max)
	local parts = {}
	for _, chunk in ipairs(out) do
		table.insert(parts, chunk[1])
	end
	return table.concat(parts)
end

--- Places one text item under each node: the first left-aligned with its
--- node, the last right-aligned with its node, the others centred under
--- theirs. Items keep at least `GAP` columns between each other; when they
--- can't, the later item is shifted right and, if there's no room left, the
--- earlier one is truncated with "…". Items without chunks are skipped.
---@param items (AtlasStripChunk[]|nil)[] One entry per node.
---@param cols integer[] Node start columns (`M.node_columns`).
---@param node_width integer
---@param width integer
---@return { col: integer, chunks: AtlasStripChunk[] }[] placed One per non-empty item, in node order.
function M.place_labels(items, cols, node_width, width)
	local GAP = 2
	local n = #cols
	local placed = {}
	for i = 1, n do
		local chunks = items[i]
		if chunks and chunks_width(chunks) > 0 then
			local w = math.min(chunks_width(chunks), width)
			local col
			if i == 1 and n > 1 then
				col = cols[i]
			elseif i == n and n > 1 then
				col = cols[i] + node_width - w
			else
				col = cols[i] + math.floor(node_width / 2) - math.floor(w / 2)
			end
			col = math.max(0, math.min(width - w, col))
			table.insert(placed, { col = col, chunks = truncate_chunks(chunks, w), node = i })
		end
	end

	-- Left to right: never start before the previous item's end + GAP.
	for idx = 2, #placed do
		local prev = placed[idx - 1]
		local min_col = prev.col + chunks_width(prev.chunks) + GAP
		if placed[idx].col < min_col then
			placed[idx].col = min_col
		end
	end
	-- Right to left: anything pushed past the edge (or into its right
	-- neighbour) is pulled back, truncating the left neighbour if needed.
	local right_limit = width
	for idx = #placed, 1, -1 do
		local item = placed[idx]
		local w = chunks_width(item.chunks)
		if item.col + w > right_limit then
			item.col = math.max(0, right_limit - w)
			if item.col + w > right_limit then
				item.chunks = truncate_chunks(item.chunks, right_limit - item.col)
			end
		end
		if idx > 1 then
			local prev = placed[idx - 1]
			local prev_w = chunks_width(prev.chunks)
			if prev.col + prev_w + GAP > item.col then
				prev.chunks = truncate_chunks(prev.chunks, math.max(0, item.col - GAP - prev.col))
			end
		end
		right_limit = item.col - GAP
	end

	local out = {}
	for _, item in ipairs(placed) do
		if chunks_width(item.chunks) > 0 then
			table.insert(out, { col = item.col, chunks = item.chunks, node = item.node })
		end
	end
	return out
end

---@class AtlasStripNode
---@field glyph string Single-column glyph, e.g. "✓".
---@field hl string Glyph highlight.
---@field outline_hl string|nil Highlight for the "(" ")" around the glyph; defaults to `hl`.
---@field segment_hl string|nil Highlight of the segment to the right of this node; "━" when set to anything but `AtlasBorder`, "─" otherwise.
---@field label AtlasStripChunk[]|nil
---@field hint AtlasStripChunk[]|nil

local NODE_WIDTH = 3

--- Three lines: nodes joined by segments, labels, hints (the hint line is
--- left out when no node has one).
---@param nodes AtlasStripNode[]
---@param width integer
---@return string[] lines
---@return AtlasUIHighlight[] highlights
function M.render_nodes(nodes, width)
	width = math.max(NODE_WIDTH, width)
	local lines, spans = {}, {}
	local cols = M.node_columns(#nodes, width, NODE_WIDTH)

	do
		local cells = M.cells(width)
		local segments = {}
		for i, node in ipairs(nodes) do
			local col = cols[i]
			M.set_glyph(cells, col, "(")
			M.set_glyph(cells, col + 1, node.glyph)
			M.set_glyph(cells, col + 2, ")")
			if i < #nodes then
				local from, to = col + NODE_WIDTH + 1, cols[i + 1] - 1
				local seg_hl = node.segment_hl or "AtlasBorder"
				local glyph = seg_hl == "AtlasBorder" and "─" or "━"
				for c = from, to - 1 do
					M.set_glyph(cells, c, glyph)
				end
				if to > from then
					table.insert(segments, { from = from, to = to, hl = seg_hl })
				end
			end
		end
		local line, byte_range = M.finalize(cells)
		table.insert(lines, line)
		for i, node in ipairs(nodes) do
			local col = cols[i]
			local outline = node.outline_hl or node.hl
			local o0, o1 = byte_range(col, col + 1)
			table.insert(spans, { line = 0, start_col = o0, end_col = o1, hl_group = outline })
			local g0, g1 = byte_range(col + 1, col + 2)
			table.insert(spans, { line = 0, start_col = g0, end_col = g1, hl_group = node.hl })
			local c0, c1 = byte_range(col + 2, col + 3)
			table.insert(spans, { line = 0, start_col = c0, end_col = c1, hl_group = outline })
		end
		for _, seg in ipairs(segments) do
			local s0, s1 = byte_range(seg.from, seg.to)
			table.insert(spans, { line = 0, start_col = s0, end_col = s1, hl_group = seg.hl })
		end
	end

	---@param field "label"|"hint"
	local function text_line(field)
		local items = {}
		local any = false
		for i, node in ipairs(nodes) do
			items[i] = node[field]
			any = any or (node[field] ~= nil and chunks_width(node[field]) > 0)
		end
		if not any then
			return
		end
		local cells = M.cells(width)
		local placed = M.place_labels(items, cols, NODE_WIDTH, width)
		local ranges = {}
		for _, item in ipairs(placed) do
			local col = item.col
			for _, chunk in ipairs(item.chunks) do
				local w = M.width(chunk[1])
				M.set_text(cells, col, chunk[1])
				if chunk[2] then
					table.insert(ranges, { from = col, to = col + w, hl = chunk[2] })
				end
				col = col + w
			end
		end
		local line, byte_range = M.finalize(cells)
		table.insert(lines, line)
		for _, r in ipairs(ranges) do
			local s0, s1 = byte_range(r.from, r.to)
			table.insert(spans, { line = #lines - 1, start_col = s0, end_col = s1, hl_group = r.hl })
		end
	end
	text_line("label")
	text_line("hint")

	return lines, spans
end

return M
