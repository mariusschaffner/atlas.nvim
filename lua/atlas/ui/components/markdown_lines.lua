-- A small, purpose-built renderer for the issue description markdown
-- (DESIGN-detail-view.md §5) -- not a general CommonMark parser. Handles
-- exactly: `#`/`##` headings (bold accent, `#` stripped, with a trailing
-- "n of m done" when immediately followed by a run of task items),
-- `#hashtag` tokens (orange), the three user-story keywords (bold accent),
-- `- [ ]`/`- [x]` task items (✓/○ glyph, done text dimmed / open text
-- bright), and two levels of nested bullets (`•`/`–`). Pure render function:
-- given raw description text, returns rendered lines + highlight spans + a
-- buffer-line -> source-line task index, so a caller can map the cursor to a
-- source line for toggling and recompute header progress from the same data.
local M = {}

local utils = require("atlas.ui.shared.utils")
local ui_utils = require("atlas.ui.utils")

local USER_STORY_PREFIXES = { "As", "I want", "so that" }

---@param line string
---@return boolean|nil checked, string|nil rest -- nil, nil when `line` isn't a task item
local function task_pattern(line)
	local mark, rest = line:match("^%s*[-*+]%s*%[([xX ])%]%s*(.*)$")
	if mark == nil then
		return nil, nil
	end
	return mark:lower() == "x", rest
end

---@param line string
---@return string|nil hashes, string|nil text -- nil, nil when `line` isn't a heading
local function heading_text(line)
	return line:match("^(#+)%s+(.*)$")
end

---@param line string
---@return integer|nil level (0 or 1), string|nil text -- nil, nil when `line` isn't a bullet
local function bullet_text(line)
	local indent, rest = line:match("^(%s*)[-*+]%s+(.*)$")
	if indent == nil then
		return nil, nil
	end
	return (#indent >= 2) and 1 or 0, rest
end

--- Counts a contiguous run of task items starting at `raw_lines[from]`,
--- tolerating a single blank-line gap (e.g. a blank line between the "###
--- Acceptance criteria" heading and its first checklist item).
---@param raw_lines string[]
---@param from integer
---@return integer completed, integer total
local function count_following_tasks(raw_lines, from)
	local completed, total = 0, 0
	local skipped_blank = false
	local j = from
	while j <= #raw_lines do
		local candidate = raw_lines[j]
		if candidate:match("^%s*$") then
			if skipped_blank then
				break
			end
			skipped_blank = true
			j = j + 1
		else
			local checked = task_pattern(candidate)
			if checked == nil then
				break
			end
			total = total + 1
			if checked then
				completed = completed + 1
			end
			skipped_blank = false
			j = j + 1
		end
	end
	return completed, total
end

---@class AtlasMarkdownTask
---@field line integer 0-indexed rendered-buffer line.
---@field raw_line integer 1-indexed line number into the original description text (see `utils.sanitize_lines`).
---@field checked boolean

---@param text string Raw description markdown.
---@param opts { width: integer|nil }|nil `width` right-aligns a heading's "n of m done" suffix; omit to just pad it with two spaces.
---@return string[] lines
---@return AtlasUIHighlight[] highlights
---@return AtlasMarkdownTask[] tasks
function M.render(text, opts)
	opts = opts or {}
	local width = opts.width
	local raw_lines = utils.sanitize_lines(text)

	local lines, spans, tasks = {}, {}, {}

	local i = 1
	while i <= #raw_lines do
		local raw = raw_lines[i]
		local hashes, htext = heading_text(raw)
		local checked, rest = task_pattern(raw)
		local level, btext = bullet_text(raw)

		if hashes then
			local completed, total = count_following_tasks(raw_lines, i + 1)
			local line_no = #lines
			local rendered = htext
			table.insert(lines, rendered)
			table.insert(spans, { line = line_no, start_col = 0, end_col = #htext, hl_group = "AtlasAccent" })
			if total > 0 then
				local suffix = string.format("%d of %d done", completed, total)
				local gap_width = width and math.max(1, width - ui_utils.text_width(htext) - ui_utils.text_width(suffix))
					or 2
				rendered = htext .. string.rep(" ", gap_width) .. suffix
				lines[#lines] = rendered
				table.insert(
					spans,
					{ line = line_no, start_col = #rendered - #suffix, end_col = #rendered, hl_group = "AtlasTextMuted" }
				)
			end
			i = i + 1
		elseif checked ~= nil then
			local glyph = checked and "✓" or "○"
			local glyph_hl = checked and "AtlasProgressFill" or "AtlasKeyHint"
			local text_hl = checked and "AtlasTextDone" or "AtlasTextBright"
			local rendered = string.format("%s %s", glyph, rest or "")
			local line_no = #lines
			table.insert(lines, rendered)
			table.insert(spans, { line = line_no, start_col = 0, end_col = #glyph, hl_group = glyph_hl })
			table.insert(spans, { line = line_no, start_col = #glyph + 1, end_col = #rendered, hl_group = text_hl })
			table.insert(tasks, { line = line_no, raw_line = i, checked = checked })
			i = i + 1
		elseif level ~= nil then
			local bullet = level == 0 and "•" or "–"
			local indent = level == 0 and "" or "  "
			table.insert(lines, string.format("%s%s %s", indent, bullet, btext or ""))
			i = i + 1
		else
			local line_no = #lines
			table.insert(lines, raw)
			for s, token in raw:gmatch("()#(%w+)") do
				table.insert(
					spans,
					{ line = line_no, start_col = s - 1, end_col = s - 1 + 1 + #token, hl_group = "AtlasOrange" }
				)
			end
			for _, kw in ipairs(USER_STORY_PREFIXES) do
				if raw:sub(1, #kw) == kw then
					table.insert(spans, { line = line_no, start_col = 0, end_col = #kw, hl_group = "AtlasAccent" })
					break
				end
			end
			i = i + 1
		end
	end

	return lines, spans, tasks
end

--- Flips a single task item's `[ ]`/`[x]` marker in `text` (the raw
--- description) at `raw_line` (1-indexed, as returned in `AtlasMarkdownTask`)
--- and returns the updated full description text. Returns `text` unchanged
--- if `raw_line` isn't a task line.
---@param text string
---@param raw_line integer
---@return string
function M.toggle_task(text, raw_line)
	local raw_lines = utils.sanitize_lines(text)
	local line = raw_lines[raw_line]
	if line == nil then
		return text
	end
	local checked = task_pattern(line)
	if checked == nil then
		return text
	end
	local replacement = checked and "[ ]" or "[x]"
	raw_lines[raw_line] = (line:gsub("%[[xX ]%]", replacement, 1))
	return table.concat(raw_lines, "\n")
end

return M
