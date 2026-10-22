-- Parses + renders the milestone description's markdown dialect
-- (DESIGN-milestone-view.md §6) -- deliberately a sibling to
-- `atlas.ui.components.markdown_lines` rather than new branches in it: the
-- two dialects (issue checklist/hashtags vs. milestone sections) are
-- different enough that mixing them risks regressing the already-shipped
-- issue view. `**Heading**:`/`**Heading**` lines on their own line delimit
-- sections; a `Meilenstein`/`Milestone`/`Goal` section is promoted first and
-- flagged for the highlighted "goal block" styling; a `Zeitplan` section
-- whose body is *only* the start/due dates is hidden (the timeline strip
-- already shows them). `M.parse` is pure string-in/table-out (unit-tested);
-- `M.render` additionally wraps paragraphs via `shared_utils.wrap_line`
-- (vim.fn-backed, like `markdown_lines.render`), so it's verified via the
-- headless/manual smoke-test path instead, same as that module.
local M = {}

local shared_utils = require("atlas.ui.shared.utils")

local GOAL_NAMES = { meilenstein = true, milestone = true, goal = true }

local DATE_LABEL_WORDS = { "start", "due", "beginn", "ende", "von", "bis", "zeitraum", "datum", "period" }

---@param line string
---@return string|nil name -- nil when `line` isn't a standalone "**Heading**" / "**Heading**:" line
local function heading_name(line)
	return line:match("^%*%*(.-)%*%*:?%s*$")
end

---@param line string
---@return boolean
local function is_blank(line)
	return line:match("^%s*$") ~= nil
end

---@param line string
---@return boolean
local function is_date_only_line(line)
	if is_blank(line) then
		return true
	end
	local s = line:lower()
	for _, word in ipairs(DATE_LABEL_WORDS) do
		s = s:gsub(word, "")
	end
	s = s:gsub("[%d%.%-/:%s]", "")
	return s == ""
end

---@param lines string[]
---@return boolean
local function is_dates_only_body(lines)
	local saw_content = false
	for _, line in ipairs(lines) do
		if not is_date_only_line(line) then
			return false
		end
		if not is_blank(line) then
			saw_content = true
		end
	end
	return saw_content
end

---@param lines string[]
local function trim_blank_edges(lines)
	while lines[1] and is_blank(lines[1]) do
		table.remove(lines, 1)
	end
	while lines[#lines] and is_blank(lines[#lines]) do
		table.remove(lines)
	end
end

---@class AtlasMilestoneMarkdownSection
---@field name string|nil Heading text, nil for the preamble (content before the first heading).
---@field lines string[] Body lines (blank edges trimmed).
---@field is_goal boolean|nil
---@field hidden boolean|nil

--- Splits the raw description into sections, promotes the goal section
--- first, and flags a dates-only Zeitplan section as hidden. Pure: no
--- vim.fn/vim.api dependency, safe to unit-test directly.
---@param text string|nil
---@return AtlasMilestoneMarkdownSection[]
function M.parse(text)
	if text == nil or tostring(text):match("^%s*$") then
		return {}
	end

	local raw_lines = shared_utils.sanitize_lines(text)
	local sections = {}
	local current = nil

	local function flush()
		if current ~= nil then
			trim_blank_edges(current.lines)
			if current.name ~= nil or #current.lines > 0 then
				table.insert(sections, current)
			end
		end
	end

	for _, line in ipairs(raw_lines) do
		local name = heading_name(line)
		if name then
			flush()
			current = { name = name, lines = {} }
		else
			current = current or { name = nil, lines = {} }
			table.insert(current.lines, line)
		end
	end
	flush()

	local goal_idx = nil
	for i, section in ipairs(sections) do
		local lname = section.name and section.name:lower() or nil
		if lname and GOAL_NAMES[lname] then
			section.is_goal = true
			goal_idx = goal_idx or i
		elseif lname == "zeitplan" and is_dates_only_body(section.lines) then
			section.hidden = true
		end
	end

	if goal_idx and goal_idx > 1 then
		local goal = table.remove(sections, goal_idx)
		table.insert(sections, 1, goal)
	end

	return sections
end

---@param text string|nil
---@param opts { width: integer|nil }|nil
---@return string[] lines
---@return AtlasUIHighlight[] highlights
function M.render(text, opts)
	opts = opts or {}
	local width = opts.width or 80
	local sections = M.parse(text)
	local lines, spans = {}, {}

	for _, section in ipairs(sections) do
		if not section.hidden then
			if #lines > 0 then
				table.insert(lines, "")
			end

			if section.name then
				local line_no = #lines
				table.insert(lines, section.name)
				table.insert(spans, { line = line_no, start_col = 0, end_col = #section.name, hl_group = "AtlasAccent" })
			end

			if section.is_goal then
				local glyph = "◎ "
				local body_text = table.concat(section.lines, " ")
				local base = #lines
				for _, wline in ipairs(shared_utils.wrap_line(glyph .. body_text, width)) do
					table.insert(lines, wline)
				end
				for i = base, #lines - 1 do
					table.insert(spans, { line = i, line_hl_group = "AtlasBgHighlight" })
				end
				table.insert(spans, { line = base, start_col = 0, end_col = #glyph, hl_group = "AtlasKeyHint" })
			else
				for _, body_line in ipairs(section.lines) do
					if is_blank(body_line) then
						table.insert(lines, "")
					else
						for _, wline in ipairs(shared_utils.wrap_line(body_line, width)) do
							table.insert(lines, wline)
						end
					end
				end
			end
		end
	end

	return lines, spans
end

return M
