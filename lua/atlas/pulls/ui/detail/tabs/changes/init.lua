-- The MR detail view's Changes tab (DESIGN-merge-request-view.md §6): one row
-- per changed file with a viewed marker, the path, +/- counts and a change
-- bar scaled to the MR's largest file, plus a totals footer. Reads the
-- diffstat the detail view already loads (`state.diffstat`); viewed marks are
-- local, per MR + head commit (`pulls.ui.detail.viewed`).
local M = {}

local utils = require("atlas.ui.shared.utils")
local spinner = require("atlas.ui.components.spinner")
local help = require("atlas.ui.popups.help")
local resolver = require("atlas.core.keymaps")
local notify = require("atlas.core.notify")
local strip = require("atlas.ui.components.strip")
local model = require("atlas.pulls.ui.detail.tabs.changes.model")
local viewed = require("atlas.pulls.ui.detail.viewed")
local detail = require("atlas.pulls.ui.detail.state")

local PADDING_X = 1
local MARKER_W = 3 -- "✓  "
local ADD_W = 6 -- " +112"
local DEL_W = 6 -- "  −29"
local GAP_BAR = 2
local BAR_CELL = "■"
local MINUS = "−"

---@param pr PullRequest
---@return table<string, boolean>
local function viewed_set(pr)
	return viewed.load(viewed.key_for(pr))
end

--- Viewed/total file counts for the tab bar's right-aligned info.
---@return integer|nil viewed_count nil while the diffstat isn't loaded.
---@return integer total
function M.viewed_counts()
	local pr = detail.current_pr
	local entries = detail.diffstat
	if pr == nil or type(entries) ~= "table" then
		return nil, 0
	end
	local set = viewed_set(pr)
	local count = 0
	for _, entry in ipairs(entries) do
		if set[entry.path] then
			count = count + 1
		end
	end
	return count, #entries
end

---@param width integer
---@return integer
local function path_width(width)
	return math.max(8, width - PADDING_X - MARKER_W - ADD_W - DEL_W - GAP_BAR - model.BAR_CELLS - 1)
end

--- Right-aligns `text` in a `w`-column cell.
---@param text string
---@param w integer
---@return string
local function rjust(text, w)
	return string.rep(" ", math.max(0, w - strip.width(text))) .. text
end

---@param text string
---@param w integer
---@return string
local function ljust(text, w)
	return text .. string.rep(" ", math.max(0, w - strip.width(text)))
end

---@param lines string[]
---@param spans table[]
---@param parts { [1]: string, [2]: string|string[]|nil }[]
local function push_parts(lines, spans, parts)
	local row = #lines
	local line = ""
	for _, part in ipairs(parts) do
		local text, hl = part[1], part[2]
		if hl then
			for _, group in ipairs(type(hl) == "table" and hl or { hl }) do
				table.insert(spans, { line = row, start_col = #line, end_col = #line + #text, hl_group = group })
			end
		end
		line = line .. text
	end
	table.insert(lines, line)
end

---@param _pr PullRequest
---@param _details PullRequestDetails|nil
---@param width integer
---@return string[] lines
---@return table[] highlights
---@return table<integer, table> line_map
function M.render(_pr, _details, width)
	local pr = detail.current_pr or _pr
	local lines, spans, line_map = {}, {}, {}
	local entries = detail.diffstat
	if entries == "loading" or entries == nil then
		utils.push(lines, spans, spinner.with_text("Loading changes..."), "AtlasTextMuted", PADDING_X)
		return lines, spans, line_map
	end
	if type(entries) == "string" then
		utils.push(lines, spans, entries, "AtlasLogError", PADDING_X)
		return lines, spans, line_map
	end
	if #entries == 0 then
		utils.push(lines, spans, "No changes.", "AtlasTextMutedItalic", PADDING_X)
		return lines, spans, line_map
	end

	local pad = string.rep(" ", PADDING_X)
	local pw = path_width(width)
	local set = viewed_set(pr)
	local max_total = model.max_total(entries)

	table.insert(lines, "")
	push_parts(lines, spans, {
		{ pad .. string.rep(" ", MARKER_W) },
		{ ljust("FILE", pw), "AtlasTextMuted" },
		{ rjust("ADD", ADD_W), "AtlasTextMuted" },
		{ rjust("DEL", DEL_W), "AtlasTextMuted" },
		{ string.rep(" ", GAP_BAR) },
		{ "CHANGE", "AtlasTextMuted" },
	})

	for _, entry in ipairs(entries) do
		local is_viewed = set[entry.path] == true
		local added = tonumber(entry.lines_added) or 0
		local removed = tonumber(entry.lines_removed) or 0
		local dir, name = model.split_path(entry.path, pw)
		local green, red = model.bar_cells(added, removed, max_total)
		local parts = {
			{ pad },
			{ is_viewed and "✓" or "○", is_viewed and "AtlasGreen" or "AtlasYellow" },
			{ string.rep(" ", MARKER_W - 1) },
			{ dir, "AtlasTextMuted" },
			{ name, is_viewed and "AtlasTextMuted" or "AtlasTextBright" },
			{ string.rep(" ", pw - strip.width(dir .. name)) },
			{ rjust("+" .. added, ADD_W), "AtlasGreen" },
			{ rjust(MINUS .. removed, DEL_W), "AtlasRed" },
			{ string.rep(" ", GAP_BAR) },
			{ string.rep(BAR_CELL, green), "AtlasGreen" },
			{ string.rep(BAR_CELL, red), "AtlasRed" },
			{ string.rep(BAR_CELL, model.BAR_CELLS - green - red), "AtlasProgressEmpty" },
		}
		push_parts(lines, spans, parts)
		line_map[#lines] = { kind = "file", path = entry.path, entry = entry }
	end

	local rule_w = PADDING_X + MARKER_W + pw + ADD_W + DEL_W + GAP_BAR + model.BAR_CELLS - PADDING_X
	push_parts(lines, spans, { { pad }, { string.rep("─", rule_w), "AtlasBorder" } })
	local added, removed = model.totals(entries)
	local summary = string.format("%d file%s changed", #entries, #entries == 1 and "" or "s")
	push_parts(lines, spans, {
		{ pad .. string.rep(" ", MARKER_W) },
		{ ljust(summary, pw), "AtlasTextMuted" },
		{ rjust("+" .. added, ADD_W), { "AtlasGreen", "AtlasTextBold" } },
		{ rjust(MINUS .. removed, DEL_W), { "AtlasRed", "AtlasTextBold" } },
	})

	return lines, spans, line_map
end

---@return boolean
function M.is_loading()
	return detail.diffstat == "loading"
end

---@param _lnum integer
---@param entry table
---@return boolean
function M.is_selectable_line(_lnum, entry)
	return entry.kind == "file"
end

--- `⏎` on a file: the MR's diff, same as `gd` (the diff viewer is redesigned
--- separately; opening at the selected file comes with that).
---@param pr PullRequest
---@param entry table
---@return boolean
function M.on_enter(pr, entry)
	if entry.kind ~= "file" or detail.provider == nil then
		return false
	end
	require("atlas.pulls.actions").run("open_diff", {
		provider = detail.provider,
		pr = pr,
		details = detail.current_details,
		buf = detail.buf,
		notify = function(level, message, duration)
			notify.show(level, message, { timeout = duration })
		end,
	})
	return true
end

---@type fun()|nil
local refresh_view = nil

---@return table[]
local function keymap_items()
	local items = {}
	utils.insert_if(
		items,
		resolver.item("pulls.toggle_file_viewed", {
			desc = "Toggle file viewed",
			hint = false,
			opts = { nowait = true, silent = true },
			callback = function()
				local pr = detail.current_pr
				local win = detail.win
				if pr == nil or win == nil or not vim.api.nvim_win_is_valid(win) then
					return
				end
				local entry = (detail.line_map or {})[vim.api.nvim_win_get_cursor(win)[1]]
				if entry == nil or entry.kind ~= "file" then
					return
				end
				viewed.toggle(viewed.key_for(pr), entry.path)
				if refresh_view then
					refresh_view()
				end
			end,
		})
	)
	return items
end

---@param buf integer
---@param refresh fun()|nil
function M.activate(buf, refresh)
	if not (buf and vim.api.nvim_buf_is_valid(buf)) then
		return
	end
	refresh_view = refresh
	help.register("Detail", keymap_items(), { index = 212, buffer = buf })
end

---@param buf integer
function M.deactivate(buf)
	refresh_view = nil
	if not (buf and vim.api.nvim_buf_is_valid(buf)) then
		return
	end
	local items = {}
	utils.insert_if(items, resolver.remove_item("pulls.toggle_file_viewed"))
	help.remove("Detail", items, { buffer = buf })
end

return M
