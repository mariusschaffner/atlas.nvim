-- "Viewed" marks for the MR detail view's Changes tab
-- (DESIGN-merge-request-view.md §6): stored locally per MR and head commit,
-- so they reset when new commits arrive (as on GitLab). `M.key` is pure; the
-- rest reads/writes one small JSON file per key under stdpath("data") --
-- not the cache dir, which `:Atlas clear` wipes.
local M = {}

---@type table<string, table<string, boolean>>
local loaded = {}

--- Storage key for one MR at one head commit.
---@param project_path string
---@param iid string|integer
---@param head_sha string|nil
---@return string
function M.key(project_path, iid, head_sha)
	return string.format("%s!%s@%s", tostring(project_path or ""), tostring(iid or ""), tostring(head_sha or ""))
end

---@param pr PullRequest
---@return string
function M.key_for(pr)
	return M.key(pr.repo_full_name, pr.id, pr.source and pr.source.commit_hash or nil)
end

---@param key string
---@return string
local function file_for(key)
	local name = key:gsub("[^%w%._%-]", "_")
	if #name > 120 then
		name = name:sub(1, 80) .. "_" .. vim.fn.sha256(key):sub(1, 16)
	end
	return vim.fs.joinpath(vim.fn.stdpath("data"), "atlas", "viewed", name .. ".json")
end

---@param key string
---@return table<string, boolean>
function M.load(key)
	if loaded[key] then
		return loaded[key]
	end
	local set = {}
	local path = file_for(key)
	if vim.fn.filereadable(path) == 1 then
		local ok, decoded = pcall(function()
			return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
		end)
		if ok and type(decoded) == "table" then
			for _, file in ipairs(decoded) do
				set[tostring(file)] = true
			end
		end
	end
	loaded[key] = set
	return set
end

---@param key string
---@param set table<string, boolean>
local function save(key, set)
	local files = {}
	for file, on in pairs(set) do
		if on then
			table.insert(files, file)
		end
	end
	table.sort(files)
	local path = file_for(key)
	pcall(vim.fn.mkdir, vim.fs.dirname(path), "p")
	pcall(vim.fn.writefile, { vim.json.encode(files) }, path)
end

---@param key string
---@param file string
---@return boolean viewed The new state.
function M.toggle(key, file)
	local set = M.load(key)
	set[file] = not set[file] or nil
	save(key, set)
	return set[file] == true
end

return M
