local M = {}

local TERMINAL_ESCAPE_PATTERN = [[\%x1b\%(\[[0-?]*[ -/]*[@-~]\|\].\{-}\%(\%x07\|\%x1b\\\)\|[ -/]*[0-~]\)]]

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
local function strip_terminal_sequences(text)
	return vim.fn.substitute(text, TERMINAL_ESCAPE_PATTERN, "", "g")
end

---@param log string
---@return string[]
function M.split_log_lines(log)
	local text = tostring(log or ""):gsub("^\239\187\191", ""):gsub("\r\n", "\n"):gsub("\r", "\n")
	text = strip_terminal_sequences(text)
	local lines = vim.split(text, "\n", { plain = true })
	if #lines > 1 and lines[#lines] == "" then
		table.remove(lines)
	end
	return lines
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
	if content:match("^##%[group%]") then
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
