-- Issues a merge request closes on merge, parsed from its description
-- (DESIGN-merge-request-view.md §5 ON MERGE, §6 Description cards). Mirrors
-- GitLab's default closing pattern: a closing keyword (close/fix/resolve/
-- implement in any tense), an optional ":" and "issue(s)", then one or more
-- refs joined by "," or "and". Pure: no vim.api.
local M = {}

local KEYWORDS = {}
for _, word in ipairs({
	"close",
	"closes",
	"closed",
	"closing",
	"fix",
	"fixes",
	"fixed",
	"fixing",
	"resolve",
	"resolves",
	"resolved",
	"resolving",
	"implement",
	"implements",
	"implemented",
	"implementing",
}) do
	KEYWORDS[word] = true
end

local REF = "^([%w_%.%-/]*)#(%d+)"

---@class AtlasClosingRef
---@field iid integer
---@field project string|nil Project path for cross-project refs ("group/project#12"), nil for "#12".
---@field keyword string The closing keyword as written, e.g. "Closes".
---@field line integer 1-based description line the ref is on.

---@param text string|nil
---@return AtlasClosingRef[]
function M.parse(text)
	local out, seen = {}, {}
	local lnum = 0
	for line in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
		lnum = lnum + 1
		line = line:gsub("\r$", "")
		local pos = 1
		while true do
			local s, e, word = line:find("%f[%a](%a+)", pos)
			if s == nil then
				break
			end
			pos = e + 1
			local c = KEYWORDS[word:lower()] and line:match("^:?%s+()", e + 1) or nil
			if c then
				c = line:match("^[Ii]ssues?%s+()", c) or c
				while true do
					local _, re, project, iid = line:find(REF, c)
					if re == nil then
						break
					end
					project = project ~= "" and project or nil
					local key = (project or "") .. "#" .. iid
					if not seen[key] then
						seen[key] = true
						table.insert(out, { iid = tonumber(iid), project = project, keyword = word, line = lnum })
					end
					c = re + 1
					local nxt = line:match("^%s*,?%s*[Aa][Nn][Dd]%s+()", c) or line:match("^%s*,?%s*()", c)
					if nxt == nil or not line:find(REF, nxt) then
						break
					end
					c = nxt
				end
				pos = math.max(pos, c)
			end
		end
	end
	return out
end

return M
