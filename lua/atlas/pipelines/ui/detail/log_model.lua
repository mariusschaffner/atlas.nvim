-- Turns a raw job trace into the log pane's rows (DESIGN-pipeline-view.md §4):
-- GitLab sections become header rows with fold ranges, ANSI colours become
-- highlight spans, WARNING/ERROR lines get a tinted background. Also the row
-- diff the view uses to append without redrawing. Pure: no editor state.
local M = {}

local logs = require("atlas.pulls.ui.pipelines.logs")

---@class AtlasPipelineLogSection
---@field name string
---@field key string
---@field duration number|nil Seconds; nil while the section is still running.
---@field last integer 1-based row of the section's last line (== its header row when empty).
---@field depth integer

---@class AtlasPipelineLogRow
---@field text string
---@field spans { start_col: integer, end_col: integer, hl_group: string }[]
---@field line_hl string|nil Background tint for the whole line.
---@field number_hl string|nil Line-number colour.
---@field section AtlasPipelineLogSection|nil Set on section header rows.

--- Background tint (and line-number colour) for a log line.
---@param text string Plain text.
---@param classified string|nil `classify_log_line`'s group.
---@return string|nil line_hl
---@return string|nil number_hl
function M.tint(text, classified)
	if text:find("ERROR", 1, true) or classified == "AtlasLogError" then
		return "AtlasLogErrorLine", "AtlasRed"
	end
	if text:find("WARNING", 1, true) or classified == "AtlasLogWarn" then
		return "AtlasLogWarnLine", "AtlasYellow"
	end
	return nil, nil
end

--- Section duration as shown on its header ("3s", "1:02").
---@param seconds number
---@return string
function M.duration_text(seconds)
	return require("atlas.pipelines.status").clock(seconds)
end

---@param text string Line with possible SGR sequences.
---@return AtlasPipelineLogRow
local function line_row(text)
	local plain, spans = logs.ansi_spans(text)
	local classified = logs.classify_log_line(plain)
	if #spans == 0 and classified and classified ~= "AtlasColumnHeader" then
		spans = { { start_col = 0, end_col = #plain, hl_group = classified } }
	end
	local line_hl, number_hl = M.tint(plain, classified)
	return { text = plain, spans = spans, line_hl = line_hl, number_hl = number_hl }
end

---@param group AtlasLogGroup
---@param depth integer
---@return AtlasPipelineLogRow
local function header_row(group, depth)
	local name = (logs.ansi_spans(group.name or group.key or ""))
	name = vim.trim(name)
	if name == "" then
		name = group.key or "section"
	end
	local head = "▾ " .. name
	local text = head
	local spans = { { start_col = 0, end_col = #head, hl_group = "AtlasAccent" } }
	if group.duration then
		local tail = " · " .. M.duration_text(group.duration)
		text = head .. tail
		table.insert(spans, { start_col = #head, end_col = #text, hl_group = "AtlasTextMuted" })
	end
	return {
		text = text,
		spans = spans,
		section = { name = name, key = group.key, duration = group.duration, depth = depth },
	}
end

---@param entries AtlasLogEntry[]
---@param rows AtlasPipelineLogRow[]
---@param depth integer
local function append(entries, rows, depth)
	for _, entry in ipairs(entries) do
		if entry.kind == "group" then
			local row = header_row(entry, depth)
			table.insert(rows, row)
			append(entry.entries, rows, depth + 1)
			row.section.last = #rows
		else
			table.insert(rows, line_row(entry.text))
		end
	end
end

--- All rows for a raw trace.
---@param raw string
---@return AtlasPipelineLogRow[]
function M.build(raw)
	local rows = {}
	append(logs.parse(raw or "", { keep_ansi = true }), rows, 0)
	return rows
end

---@param a AtlasPipelineLogRow
---@param b AtlasPipelineLogRow
---@return boolean
local function same_row(a, b)
	if a.text ~= b.text or a.line_hl ~= b.line_hl or #a.spans ~= #b.spans then
		return false
	end
	for i, span in ipairs(a.spans) do
		local other = b.spans[i]
		if span.start_col ~= other.start_col or span.end_col ~= other.end_col or span.hl_group ~= other.hl_group then
			return false
		end
	end
	-- A section's fold range (`last`) isn't on screen: a running section
	-- growing must not count as its header row changing.
	local sa, sb = a.section, b.section
	if (sa == nil) ~= (sb == nil) then
		return false
	end
	return sa == nil or sa.duration == sb.duration
end

--- First row (1-based) where `new` differs from `old`, or nil when they're equal.
--- Appending to a trace only ever changes rows from this point down.
---@param old AtlasPipelineLogRow[]
---@param new AtlasPipelineLogRow[]
---@return integer|nil
function M.first_diff(old, new)
	local n = math.min(#old, #new)
	for i = 1, n do
		if not same_row(old[i], new[i]) then
			return i
		end
	end
	if #old ~= #new then
		return n + 1
	end
	return nil
end

--- First error row (1-based), where a failed job's log opens.
---@param rows AtlasPipelineLogRow[]
---@return integer|nil
function M.first_error_row(rows)
	for i, row in ipairs(rows) do
		if row.line_hl == "AtlasLogErrorLine" then
			return i
		end
	end
	return nil
end

--- Sections that can fold (they have at least one line), outermost first.
---@param rows AtlasPipelineLogRow[]
---@return { row: integer, last: integer, finished: boolean }[]
function M.folds(rows)
	local out = {}
	for i, row in ipairs(rows) do
		local section = row.section
		if section and section.last and section.last > i then
			table.insert(out, { row = i, last = section.last, finished = section.duration ~= nil })
		end
	end
	return out
end

return M
