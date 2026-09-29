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

---@param line string
---@return string
local function collapse_carriage_returns(line)
	-- A bare `\r` mid-line is a terminal "return to column 0, overwrite"
	-- request -- progress bars from docker/npm/apt/curl/etc. use this
	-- extensively. Keep only what a real terminal would end up showing: the
	-- text after the *last* `\r` on the line. (A `\r` immediately before a
	-- real newline can't survive to this point -- `\r\n` was already folded
	-- into `\n` before splitting -- so this never eats a trailing line.)
	return (line:gsub("^.*\r", ""))
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

--- Joins GitLab's job-trace stream multiplexing: progress redraws that
--- would otherwise appear as one all-consuming `\r` are instead sent as
--- discrete `<hex-stream-id><O|E><+| ><text>` lines, where `+` means
--- "append to this stream's current line" and ` ` starts a new one.
---@param lines string[]
---@return string[]
local function coalesce_streams(lines)
	local out = {}
	---@type table<string, table>
	local streams = {}
	for _, line in ipairs(lines) do
		local stream, separator, message = line:match("^(%x%x[OE])([+ ])(.*)$")
		if stream then
			local previous = streams[stream]
			if separator == "+" and previous then
				previous.text = previous.text .. message
			else
				local entry = { text = message }
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

---@param text string
---@return integer|nil epoch
---@return string|nil key
---@return string|nil title
local function match_section_start(text)
	local epoch, key, flags, title = text:match("^section_start:(%d+):([%w_.%-]+)([^\r]*)\r?(.*)$")
	if epoch and (flags == "" or flags:match("^%[.-%]$")) then
		return tonumber(epoch), key, (title ~= "" and title or key)
	end
end

---@param text string
---@return integer|nil epoch
---@return string|nil key
local function match_section_end(text)
	local epoch, key = text:match("^section_end:(%d+):([%w_.%-]+)\r?%s*$")
	if epoch then
		return tonumber(epoch), key
	end
end

--- Parses a raw job trace into a tree of lines and GitLab CI section groups
--- (`section_start:<epoch>:<key>[flags]\r<title>` / `section_end:<epoch>:<key>`),
--- coalescing stream-multiplexed progress redraws along the way. Unmatched/
--- unbalanced `section_end` markers are ignored rather than corrupting the
--- nesting stack.
---@param raw string
---@return AtlasLogEntry[]
function M.parse(raw)
	local lines = coalesce_streams(M.clean_lines(raw))

	---@type AtlasLogEntry[]
	local entries = {}
	---@type { group: AtlasLogGroup, key: string, epoch: number }[]
	local stack = {}

	for _, line in ipairs(lines) do
		local parent = stack[#stack]
		local current = parent and parent.group.entries or entries

		local start_epoch, start_key, title = match_section_start(line)
		if start_epoch then
			---@type AtlasLogGroup
			local group = {
				kind = "group",
				name = collapse_carriage_returns(title),
				key = start_key,
				entries = {},
			}
			table.insert(current, group)
			table.insert(stack, { group = group, key = start_key, epoch = start_epoch })
		else
			local end_epoch, end_key = match_section_end(line)
			local closed = false
			if end_epoch then
				for index = #stack, 1, -1 do
					local frame = stack[index]
					if frame.key == end_key then
						if end_epoch >= frame.epoch then
							frame.group.duration = end_epoch - frame.epoch
						end
						for last = #stack, index, -1 do
							stack[last] = nil
						end
						closed = true
						break
					end
				end
			end
			if not closed then
				table.insert(current, { kind = "line", text = collapse_carriage_returns(line) })
			end
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
