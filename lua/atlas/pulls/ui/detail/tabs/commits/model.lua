-- Pure parsing for the MR detail view's Commits tab: splits a commit subject
-- into its Conventional Commits parts (type chip, scope, subject), recognises
-- merge commits, and tallies commits per type for the footer. No vim.api.
local M = {}

---@class AtlasCommitSubject
---@field type string|nil Lower-cased type ("feat", "fix", "merge", ...); nil when the subject isn't conventional.
---@field scope string|nil
---@field subject string
---@field breaking boolean
---@field merge boolean

--- "Merge branch 'a' into 'b'" (GitLab/git default) -> "a → b".
---@param line string
---@return string|nil
local function merge_subject(line)
	local source, target = line:match("^Merge branch '([^']+)' into '([^']+)'")
	if source then
		return source .. " → " .. target
	end
	source = line:match("^Merge branch '([^']+)'")
	if source then
		return source
	end
	local remote, into = line:match("^Merge remote%-tracking branch '([^']+)' into (%S+)")
	if remote then
		return remote .. " → " .. into
	end
	if line:match("^Merge ") then
		return (line:gsub("^Merge%s+", ""))
	end
	return nil
end

--- Parses a commit message's first line.
---@param message string|nil
---@return AtlasCommitSubject
function M.parse(message)
	local line = tostring(message or ""):gsub("\r\n", "\n"):match("^[^\n]*") or ""
	line = vim.trim and vim.trim(line) or line:match("^%s*(.-)%s*$")

	local merged = merge_subject(line)
	if merged then
		return { type = "merge", scope = nil, subject = merged, breaking = false, merge = true }
	end

	local kind, rest = line:match("^(%a[%w%-]*)(.*)$")
	if kind then
		local scope
		local scoped, after = rest:match("^%(([^)]*)%)(.*)$")
		if scoped then
			scope, rest = scoped, after
		end
		local bang, subject = rest:match("^(!?):%s*(.*)$")
		if bang ~= nil and subject ~= "" then
			return {
				type = kind:lower(),
				scope = scope ~= "" and scope or nil,
				subject = subject,
				breaking = bang == "!",
				merge = false,
			}
		end
	end
	return { type = nil, scope = nil, subject = line, breaking = false, merge = false }
end

--- Commits per type, most frequent first (ties in order of first
--- appearance in `messages`); commits without a type are left out.
---@param messages string[] Commit messages, oldest first.
---@return { type: string, count: integer }[]
function M.tally(messages)
	local counts, order = {}, {}
	for _, message in ipairs(messages or {}) do
		local kind = M.parse(message).type
		if kind then
			if counts[kind] == nil then
				counts[kind] = 0
				table.insert(order, kind)
			end
			counts[kind] = counts[kind] + 1
		end
	end
	local out = {}
	for index, kind in ipairs(order) do
		table.insert(out, { type = kind, count = counts[kind], index = index })
	end
	table.sort(out, function(a, b)
		if a.count ~= b.count then
			return a.count > b.count
		end
		return a.index < b.index
	end)
	for _, entry in ipairs(out) do
		entry.index = nil
	end
	return out
end

return M
