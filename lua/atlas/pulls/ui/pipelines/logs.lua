local M = {}

---@class AtlasLogLine
---@field kind "line"
---@field text string

---@class AtlasLogGroup
---@field kind "group"
---@field name string GitLab's human-readable section title (falls back to `key`).
---@field key string GitLab's raw section identifier (e.g. "build_image"), stable across polls -- usable as part of a fold-state key.
---@field duration number|nil Seconds, present once `section_end` closes the group.
---@field entries (AtlasLogLine|AtlasLogGroup)[]

---@alias AtlasLogEntry AtlasLogLine|AtlasLogGroup

local LOG_HIGHLIGHT_RULES = {
	{
		hl_group = "AtlasLogError",
		patterns = {
			"^##%[error%]",
			"^%[error%]",
			"^error:",
			"^failed:",
			"^failed[%.!]*$",
			"^failure[%.!]*$",
			"^%w[%w%s_%-]* failed[%.!]*$",
			"^job failed[:%.!].*$",
			"^process completed with exit code [1-9]%d*[%.!]*$",
		},
	},
	{
		hl_group = "AtlasLogWarn",
		patterns = {
			"^##%[warning%]",
			"^%[warning%]",
			"^%[warn%]",
			"^warning:",
			"^warn:",
			"deprecated",
		},
	},
	{
		hl_group = "AtlasLogInfo",
		patterns = {
			"^##%[notice%]",
			"^%[notice%]",
			"^%[info%]",
			"^notice:",
			"^info:",
		},
	},
	{
		hl_group = "AtlasTextPositive",
		patterns = {
			"^%[success%]",
			"^%[passed%]",
			"^success:",
			"^passed:",
			"^passed[%.!]*$",
			"^%w[%w%s_%-]* passed[%.!]*$",
			"^%w[%w%s_%-]* succeeded[%.!]*$",
			"^process completed with exit code 0[%.!]*$",
		},
	},
}

---@param line string
---@return integer|nil
local function log_timestamp_end(line)
	local _, timestamp_end = line:find("^%d%d%d%d%-%d%d%-%d%d[T ]%d%d:%d%d:%d%d")
	if not timestamp_end then
		return nil
	end

	local fraction = line:sub(timestamp_end + 1):match("^[.,]%d+")
	if fraction then
		timestamp_end = timestamp_end + #fraction
	end

	local suffix = line:sub(timestamp_end + 1)
	if suffix:match("^[Zz]") then
		timestamp_end = timestamp_end + 1
	else
		local timezone = suffix:match("^[+%-]%d%d:%d%d")
		if timezone then
			timestamp_end = timestamp_end + #timezone
		end
	end

	return timestamp_end
end

--- Byte position (1-indexed, inclusive -- directly usable as an extmark's
--- 0-indexed exclusive `end_col`) where a leading timestamp ends, or nil if
--- `line` doesn't start with one. Exposed so callers can style the
--- timestamp separately from the rest of the line (classify_log_line only
--- classifies the message that follows it).
---@param line string
---@return integer|nil
function M.timestamp_end(line)
	return log_timestamp_end(line)
end

---@param content string
---@return string|nil
local function log_message_hl(content)
	local normalized = vim.trim(content):lower()
	for _, rule in ipairs(LOG_HIGHLIGHT_RULES) do
		for _, pattern in ipairs(rule.patterns) do
			if normalized:match(pattern) then
				return rule.hl_group
			end
		end
	end
	return nil
end

---@param text string
---@return string
local function strip_escape_sequences(text)
	-- OSC hyperlink/title sequences terminated by BEL.
	text = text:gsub("\27%][^\7\27]*\7", "")
	-- OSC/DCS/PM/APC sequences terminated by ST ("\27\\").
	text = text:gsub("\27[%]PX^_][^\27]*\27\\", "")
	-- CSI sequences (cursor movement, SGR colors, erase-line, ...).
	text = text:gsub("\27%[[0-?]*[ -/]*[@-~]", "")
	-- Any other 2+-byte escape sequence not covered above.
	text = text:gsub("\27[ -/]*[0-~]", "")
	-- Remaining C0/DEL control bytes, excluding tab/LF/CR (9/10/13).
	text = text:gsub("[%z\1-\8\11\12\14-\31\127]", "")
	return text
end

---@param line string
---@return string
local function strip_dangling_escape(line)
	-- A CSI sequence split across a `\r`-redraw boundary (e.g. GitLab's
	-- `section_start:...\r\27[0K<title>`, once the `\r` itself has been
	-- consumed elsewhere) can leave an unterminated escape prefix.
	return (line:gsub("\27%[[0-?]*[ -/]*$", ""))
end

--- Strips ANSI/OSC escape sequences and control characters, normalizes line
--- endings, and splits into lines. Deliberately leaves bare `\r` characters
--- (mid-line progress redraws) and GitLab's `section_start`/`section_end`/
--- stream-multiplex markers untouched -- see `M.parse` for those.
---@param raw string
---@return string[]
function M.clean_lines(raw)
	local text = tostring(raw or "")
	if text == "" then
		return {}
	end

	text = text:gsub("^\239\187\191", ""):gsub("\r\n", "\n")
	text = strip_escape_sequences(text)

	local lines = vim.split(text, "\n", { plain = true })
	if #lines > 1 and lines[#lines] == "" then
		table.remove(lines)
	end

	for i, line in ipairs(lines) do
		lines[i] = strip_dangling_escape(line)
	end

	return lines
end

--- Splits off a leading ISO-8601 timestamp (GitLab's "full" trace format
--- stamps *every* line, control lines included -- `FF_USE_FASTZIP`-era
--- runners enable this per-runner, so some jobs in an otherwise plain,
--- untimestamped pipeline can still have it).
---@param text string
---@return string|nil prefix Includes one trailing separating space/tab, if any.
---@return string rest
local function strip_leading_timestamp(text)
	local timestamp_end = log_timestamp_end(text)
	if not timestamp_end then
		return nil, text
	end
	local separator_len = 0
	local next_char = text:sub(timestamp_end + 1, timestamp_end + 1)
	if next_char == " " or next_char == "\t" then
		separator_len = 1
	end
	return text:sub(1, timestamp_end + separator_len), text:sub(timestamp_end + separator_len + 1)
end

---@param text string
---@return boolean
local function looks_like_section_marker(text)
	local _, rest = strip_leading_timestamp(text)
	return rest:match("^section_start:%d+:") ~= nil or rest:match("^section_end:%d+:") ~= nil
end

---@param text string
---@return string
local function last_segment(text)
	return text:match("\r([^\r]*)$") or text
end

--- Joins GitLab's job-trace stream multiplexing: discrete
--- `[<timestamp> ]<hex-stream-id><O|E><+| ><text>` lines, where `+` means
--- "this continues the current stream buffer" and ` ` starts a new one.
--- Most continuations are ordinary transport chunking (a long line split
--- mid-word across frames) and get concatenated with nothing, exactly like
--- upstream -- but a `section_end`/`section_start` pair emitted back to back
--- with no real newline between them also arrives this way, and *those* need
--- the `\r` GitLab would otherwise have used to separate them (so `M.parse`'s
--- `\r`-segment handling below can tell them apart). Detected by checking
--- whether either side of the join looks like a section marker.
---@param lines string[]
---@return string[]
local function coalesce_streams(lines)
	local out = {}
	---@type table<string, table>
	local streams = {}
	for _, line in ipairs(lines) do
		local prefix, rest = strip_leading_timestamp(line)
		local stream, separator, message = rest:match("^(%x%x[OE])([+ ])(.*)$")
		if stream then
			local previous = streams[stream]
			if separator == "+" and previous then
				local joiner = (looks_like_section_marker(last_segment(previous.text)) or looks_like_section_marker(message))
						and "\r"
					or ""
				previous.text = previous.text .. joiner .. message
			else
				local entry = { text = (prefix or "") .. message }
				table.insert(out, entry)
				streams[stream] = entry
			end
		else
			table.insert(out, { text = line })
		end
	end

	local flat = {}
	for _, entry in ipairs(out) do
		table.insert(flat, entry.text)
	end
	return flat
end

---@param text string A single `\r`-free segment.
---@return integer|nil epoch
---@return string|nil key
local function match_section_start(text)
	local epoch, key, flags = text:match("^section_start:(%d+):([%w_.%-]+)(.*)$")
	if epoch and (flags == "" or flags:match("^%[.-%]$")) then
		return tonumber(epoch), key
	end
end

---@param text string A single `\r`-free segment.
---@return integer|nil epoch
---@return string|nil key
local function match_section_end(text)
	local epoch, key = text:match("^section_end:(%d+):([%w_.%-]+)%s*$")
	if epoch then
		return tonumber(epoch), key
	end
end

--- Parses a raw job trace into a tree of lines and GitLab CI section groups,
--- coalescing stream-multiplexed frames first (see `coalesce_streams`).
--- Each resulting line is then split on `\r`: a bare `section_start:<epoch>
--- :<key>[flags]` segment takes its title from the *next* segment (GitLab's
--- own `section_start:...\r<title>` convention) unless that segment is
--- itself a marker; any other segment only survives if it's the last one in
--- the line (a real terminal only ever shows what the final `\r` in a burst
--- left behind -- earlier segments were overwritten). A segment that merely
--- *looks* like a section marker but doesn't parse cleanly is still dropped
--- rather than shown as raw control text. Unmatched/unbalanced `section_end`
--- markers are ignored rather than corrupting the nesting stack.
---@param raw string
---@return AtlasLogEntry[]
function M.parse(raw)
	local lines = coalesce_streams(M.clean_lines(raw))

	---@type AtlasLogEntry[]
	local entries = {}
	---@type { group: AtlasLogGroup, key: string, epoch: number }[]
	local stack = {}

	for _, line in ipairs(lines) do
		local prefix, rest = strip_leading_timestamp(line)
		local parts = vim.split(rest, "\r", { plain = true })

		local index = 1
		while index <= #parts do
			local part = parts[index]
			local parent = stack[#stack]
			local current = parent and parent.group.entries or entries

			local start_epoch, start_key = match_section_start(part)
			if start_epoch then
				local title = start_key
				local next_part = parts[index + 1]
				if next_part and next_part ~= "" and not looks_like_section_marker(next_part) then
					title = next_part
					index = index + 1
				end
				---@type AtlasLogGroup
				local group = { kind = "group", name = title, key = start_key, entries = {} }
				table.insert(current, group)
				table.insert(stack, { group = group, key = start_key, epoch = start_epoch })
			else
				local end_epoch, end_key = match_section_end(part)
				if end_epoch then
					for stack_index = #stack, 1, -1 do
						local frame = stack[stack_index]
						if frame.key == end_key then
							if end_epoch >= frame.epoch then
								frame.group.duration = end_epoch - frame.epoch
							end
							for last = #stack, stack_index, -1 do
								stack[last] = nil
							end
							break
						end
					end
				elseif index == #parts and part ~= "" and not looks_like_section_marker(part) then
					table.insert(current, { kind = "line", text = (prefix or "") .. part })
				end
			end

			index = index + 1
		end
	end

	return entries
end

--- Formats a section duration. Unlike `atlas.ui.shared.utils.human_duration`
--- (job/pipeline durations, always minute-granular), GitLab CI sections
--- routinely last only a few seconds -- rounding those to "0m" would make
--- the duration badge worse than useless.
---@param seconds number
---@return string
function M.format_duration(seconds)
	local total = math.floor(seconds + 0.5)
	if total < 60 then
		return string.format("%ds", total)
	end
	local minutes = math.floor(total / 60)
	local secs = total % 60
	if minutes < 60 then
		return secs == 0 and string.format("%dm", minutes) or string.format("%dm %ds", minutes, secs)
	end
	local hours = math.floor(minutes / 60)
	local rem_minutes = minutes % 60
	return rem_minutes == 0 and string.format("%dh", hours) or string.format("%dh %dm", hours, rem_minutes)
end

---@param entries AtlasLogEntry[]
---@param out string[]
---@param depth integer
local function append_flat(entries, out, depth)
	local indent = string.rep("  ", depth)
	for _, entry in ipairs(entries) do
		if entry.kind == "group" then
			local duration = entry.duration and (" (" .. M.format_duration(entry.duration) .. ")") or ""
			table.insert(out, indent .. "▸ " .. entry.name .. duration)
			append_flat(entry.entries, out, depth + 1)
		else
			table.insert(out, indent .. entry.text)
		end
	end
end

--- Flattens a parsed tree back into plain lines -- for callers that don't
--- offer interactive folding (the PR-tab's inline job-log box): each group
--- becomes one non-interactive header line, its raw `section_start`/
--- `section_end` markers already gone.
---@param entries AtlasLogEntry[]
---@return string[]
function M.flatten(entries)
	local out = {}
	append_flat(entries, out, 0)
	return out
end

--- Classifies a single log line as a whole (no sub-token spans) -- used where
--- log lines are rendered as individual tree rows (e.g. the pipelines tab's
--- inline job-log expansion) and per-token alignment isn't practical.
---@param line string
---@return string|nil hl_group
function M.classify_log_line(line)
	local timestamp_end = log_timestamp_end(line)
	local message_start = line:find("%S", (timestamp_end or 0) + 1)
	if not message_start then
		return nil
	end
	local content = line:sub(message_start)

	if content:match("^%d%d%u%+") or content:match("^%d%d%u%s") then
		return "AtlasColumnHeader"
	end
	if content:match("^▸ ") or content:match("^##%[group%]") then
		return "AtlasColumnHeader"
	end
	if content:match("^##%[endgroup%]") then
		return "AtlasTextMuted"
	end
	if
		content:match("^##%[command%]")
		or content:match("^%[command%]")
		or content:match("^%$%s")
		or content:match("^%+%s")
	then
		return "AtlasLogInfo"
	end

	return log_message_hl(content)
end

return M
