-- Compact "key label" hints ("C-s post  Esc cancel  c focus"): the key in
-- the key-hint color, the label dim. Keys always come from
-- `atlas.core.keymaps` (never hardcoded), and segments whose action has no
-- key configured are dropped.
local M = {}

local resolver = require("atlas.core.keymaps")
local line_builder = require("atlas.ui.components.line")

local NAMED_KEYS = {
	cr = "⏎",
	enter = "⏎",
	["return"] = "⏎",
	esc = "Esc",
	tab = "Tab",
	space = "Space",
	bs = "BS",
}

--- Display form of a Vim key notation: "<C-s>" -> "C-s", "<Esc>" -> "Esc",
--- "<CR>" -> "⏎"; plain keys ("gc", "c") are returned unchanged.
---@param key string
---@return string
function M.format_key(key)
	local inner = key:match("^<(.+)>$")
	if not inner then
		return key
	end
	local named = NAMED_KEYS[inner:lower()]
	if named then
		return named
	end
	local mod, rest = inner:match("^(%a)%-(.+)$")
	if mod then
		return mod:upper() .. "-" .. rest
	end
	return inner
end

---@class AtlasKeyHintSegment
---@field action_id string|nil Resolved via `atlas.core.keymaps`; ignored when `keys` is set.
---@field keys string[]|nil Explicit keys (e.g. a caller-side override like the filter box's `<CR>`).
---@field label string

---@class AtlasKeyHintOptions
---@field separator string|nil Between segments; default two spaces.
---@field key_hl string|nil Default `AtlasKeyHint`.
---@field label_hl string|nil Default `AtlasKeyHintLabel`.
---@field separator_hl string|nil Default `label_hl`.

---@param segment AtlasKeyHintSegment
---@return string|nil
local function first_key(segment)
	local keys = segment.keys or (segment.action_id and resolver.resolve(segment.action_id)) or nil
	return keys and keys[1] or nil
end

--- Appends the hints onto an `atlas.ui.components.line` builder.
---@param line AtlasLine
---@param segments AtlasKeyHintSegment[]
---@param opts AtlasKeyHintOptions|nil
---@return AtlasLine
function M.append(line, segments, opts)
	opts = opts or {}
	local key_hl = opts.key_hl or "AtlasKeyHint"
	local label_hl = opts.label_hl or "AtlasKeyHintLabel"
	local separator = opts.separator or "  "
	local first = true
	for _, segment in ipairs(segments) do
		local key = first_key(segment)
		if key then
			if not first then
				line:add(separator, opts.separator_hl or label_hl)
			end
			first = false
			line:add(M.format_key(key), key_hl)
			if segment.label ~= "" then
				line:add(" " .. segment.label, label_hl)
			end
		end
	end
	return line
end

---@param segments AtlasKeyHintSegment[]
---@param opts AtlasKeyHintOptions|nil
---@return string text
---@return AtlasUIHighlight[] spans Spans with `line = 0`.
function M.render(segments, opts)
	return M.append(line_builder.new(), segments, opts):finish(0)
end

--- Same hints as `{text, hl}` chunks, for `virt_text`.
---@param segments AtlasKeyHintSegment[]
---@param opts AtlasKeyHintOptions|nil
---@return { [1]: string, [2]: string }[]
function M.chunks(segments, opts)
	local line = M.append(line_builder.new(), segments, opts)
	local text = table.concat(line.parts)
	local chunks = {}
	local cursor = 0
	for _, span in ipairs(line.spans) do
		if span.start_col > cursor then
			table.insert(chunks, { text:sub(cursor + 1, span.start_col), "Normal" })
		end
		table.insert(chunks, { text:sub(span.start_col + 1, span.end_col), span.hl_group })
		cursor = span.end_col
	end
	if cursor < #text then
		table.insert(chunks, { text:sub(cursor + 1), "Normal" })
	end
	return chunks
end

return M
