-- Pure layout math for the MR detail view's Changes tab
-- (DESIGN-merge-request-view.md §6): change-bar scaling, totals, and path
-- truncation. No vim.api, no state.
local M = {}

M.BAR_CELLS = 10

---@param text string
---@return string[]
local function chars(text)
	local out = {}
	for ch in tostring(text or ""):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
		table.insert(out, ch)
	end
	return out
end

---@param n number
---@return integer
local function round(n)
	return math.floor(n + 0.5)
end

--- Largest per-file change (additions + deletions) across `entries`.
---@param entries PullsDiffstatEntry[]
---@return integer
function M.max_total(entries)
	local max = 0
	for _, entry in ipairs(entries or {}) do
		local total = (tonumber(entry.lines_added) or 0) + (tonumber(entry.lines_removed) or 0)
		if total > max then
			max = total
		end
	end
	return max
end

--- Sum of additions and deletions across `entries`.
---@param entries PullsDiffstatEntry[]
---@return integer added
---@return integer removed
function M.totals(entries)
	local added, removed = 0, 0
	for _, entry in ipairs(entries or {}) do
		added = added + (tonumber(entry.lines_added) or 0)
		removed = removed + (tonumber(entry.lines_removed) or 0)
	end
	return added, removed
end

--- How many of a file's change-bar cells are green (additions) and red
--- (deletions). The bar is scaled to the MR's largest file, which fills all
--- `cells`; any changed file gets at least one cell, a file with both
--- additions and deletions keeps at least one of each when it has room.
---@param added integer
---@param removed integer
---@param max_total integer Largest per-file total in the MR (`M.max_total`).
---@param cells integer|nil Default `M.BAR_CELLS`.
---@return integer green
---@return integer red
function M.bar_cells(added, removed, max_total, cells)
	cells = cells or M.BAR_CELLS
	added = math.max(0, tonumber(added) or 0)
	removed = math.max(0, tonumber(removed) or 0)
	local total = added + removed
	if total <= 0 or (tonumber(max_total) or 0) <= 0 or cells <= 0 then
		return 0, 0
	end
	local filled = math.min(cells, math.max(1, round(cells * total / max_total)))
	if filled == 1 then
		if removed > added then
			return 0, 1
		end
		return 1, 0
	end
	local red = removed > 0 and math.max(1, round(filled * removed / total)) or 0
	if added > 0 and red >= filled then
		red = filled - 1
	end
	return filled - red, red
end

--- Splits `path` into directory (with trailing "/") and file name, fitted to
--- `width` columns: the directory is shortened from the left with "…" first,
--- then dropped, then the name is cut from the right with "…".
---@param path string
---@param width integer
---@return string dir
---@return string name
function M.split_path(path, width)
	path = tostring(path or "")
	local dir = path:match("^(.*/)") or ""
	local name = path:sub(#dir + 1)
	local dir_chars, name_chars = chars(dir), chars(name)
	if #dir_chars + #name_chars <= width then
		return dir, name
	end
	local room = width - #name_chars
	if room >= 2 then
		local keep = room - 1
		return "…" .. table.concat(dir_chars, "", #dir_chars - keep + 1, #dir_chars), name
	end
	if #name_chars <= width then
		return "", name
	end
	if width <= 0 then
		return "", ""
	end
	return "", table.concat(name_chars, "", 1, width - 1) .. "…"
end

return M
