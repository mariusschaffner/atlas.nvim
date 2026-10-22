-- Turns an issue's system activity entries (GitLab system notes) into the
-- display model `atlas.ui.components.timeline.event_row` renders: an icon
-- picked from the provider's event-type hint (falling back to the text
-- itself), and the note text split into colored segments -- dim verbs,
-- bright objects (**bold** text, @handles) and cyan issue/MR references.
local M = {}

local utils = require("atlas.ui.shared.utils")

---@class IssuesActivityIcon
---@field icon string
---@field hl string

---@type table<string, IssuesActivityIcon>
local ICONS = {
	assign = { icon = "@", hl = "AtlasTimelineIconAssign" },
	move = { icon = "⇄", hl = "AtlasTimelineIconMove" },
	edit = { icon = "✎", hl = "AtlasTimelineIconEdit" },
	task_done = { icon = "☑", hl = "AtlasTimelineIconTask" },
	task_open = { icon = "☐", hl = "AtlasTimelineIconDefault" },
	label = { icon = "◈", hl = "AtlasTimelineIconLabel" },
	milestone = { icon = "◆", hl = "AtlasCyan" },
	closed = { icon = "✕", hl = "AtlasTimelineIconLabel" },
	reopened = { icon = "↺", hl = "AtlasTimelineIconState" },
	reference = { icon = "↗", hl = "AtlasTimelineIconMove" },
	link = { icon = "⇢", hl = "AtlasTimelineIconMove" },
	time = { icon = "◷", hl = "AtlasTimelineIconDefault" },
	date = { icon = "▦", hl = "AtlasTimelineIconDefault" },
	branch = { icon = "⎇", hl = "AtlasTimelineIconMove" },
	lock = { icon = "⊘", hl = "AtlasTimelineIconDefault" },
	confidential = { icon = "◌", hl = "AtlasTimelineIconDefault" },
	default = { icon = "•", hl = "AtlasTimelineIconDefault" },
}

--- GitLab `systemNoteIconName` values -> icon kind.
---@type table<string, string>
local BY_ICON_NAME = {
	user = "assign",
	users = "assign",
	["arrow-right"] = "move",
	documents = "move",
	pencil = "edit",
	["list-task"] = "task_done",
	label = "label",
	milestone = "milestone",
	clock = "milestone",
	status_closed = "closed",
	["issue-close"] = "closed",
	status_open = "reopened",
	["issue-open-m"] = "reopened",
	["comment-dots"] = "reference",
	link = "link",
	timer = "time",
	calendar = "date",
	branch = "branch",
	lock = "lock",
	["lock-open"] = "lock",
	["eye-slash"] = "confidential",
	eye = "confidential",
}

--- Text fallbacks for notes without (or with an unknown) icon hint, tried in order.
---@type { [1]: string, [2]: string }[]
local BY_TEXT = {
	{ "^assigned", "assign" },
	{ "^unassigned", "assign" },
	{ "^moved", "move" },
	{ "^cloned", "move" },
	{ "^changed the description", "edit" },
	{ "^changed title", "edit" },
	{ "as incomplete", "task_open" },
	{ "^marked the .- as completed", "task_done" },
	{ "label", "label" },
	{ "milestone", "milestone" },
	{ "^closed", "closed" },
	{ "^reopened", "reopened" },
	{ "^mentioned in", "reference" },
	{ "^marked this issue as related", "link" },
	{ "^removed the relation", "link" },
	{ "time spent", "time" },
	{ "time estimate", "time" },
	{ "due date", "date" },
	{ "branch", "branch" },
	{ "^locked", "lock" },
	{ "^unlocked", "lock" },
	{ "confidential", "confidential" },
}

---@param entry IssueActivityEntry
---@param text string
---@return IssuesActivityIcon
local function icon_for(entry, text)
	local lower = text:lower()
	-- A checklist note's icon hint is the same whether checked or unchecked.
	if lower:find("^unchecked ") or lower:find("as incomplete", 1, true) then
		return ICONS.task_open
	end
	local kind = entry.icon_name and BY_ICON_NAME[entry.icon_name]
	if kind == nil then
		for _, rule in ipairs(BY_TEXT) do
			if lower:find(rule[1]) then
				kind = rule[2]
				break
			end
		end
	end
	return ICONS[kind or "default"] or ICONS.default
end

--- First line of the note, with markup links/HTML stripped.
---@param label string|nil
---@return string
local function summary_line(label)
	local text = utils.strip_markup(label or "")
	text = text:gsub("<[^>]+>", "")
	text = vim.split(text, "\n", { plain = true })[1] or ""
	return vim.trim(text)
end

--- Rewrites GitLab's checklist phrasing to the timeline's shorter form:
--- "marked the checklist item **X** as completed" -> "checked **X**".
---@param text string
---@return string
local function shorten(text)
	local item = text:match("^marked the checklist item (.+) as completed$")
		or text:match("^marked the task (.+) as completed$")
	if item then
		return "checked " .. item
	end
	item = text:match("^marked the checklist item (.+) as incomplete$")
		or text:match("^marked the task (.+) as incomplete$")
	if item then
		return "unchecked " .. item
	end
	return text
end

local TOKEN_PATTERNS = {
	{ pattern = "@[%w_%-%.]*[%w_]", hl = "AtlasTimelineObject" },
	{ pattern = "[%w_%.%-/]*[#!&]%d+", hl = "AtlasTimelineRef" },
}

--- Splits plain (non-bold) text into verb/mention/reference segments.
---@param text string
---@param out AtlasTimelineEventSegment[]
local function split_tokens(text, out)
	local cursor = 1
	while cursor <= #text do
		local best_s, best_e, best_hl
		for _, token in ipairs(TOKEN_PATTERNS) do
			local s, e = text:find(token.pattern, cursor)
			if s and (best_s == nil or s < best_s) then
				best_s, best_e, best_hl = s, e, token.hl
			end
		end
		if best_s == nil then
			table.insert(out, { text:sub(cursor), "AtlasTimelineVerb" })
			return
		end
		if best_s > cursor then
			table.insert(out, { text:sub(cursor, best_s - 1), "AtlasTimelineVerb" })
		end
		table.insert(out, { text:sub(best_s, best_e), best_hl })
		cursor = best_e + 1
	end
end

--- Splits the note text into colored segments: **bold** runs become bright
--- objects (markers dropped), the rest goes through `split_tokens`.
---@param text string
---@return AtlasTimelineEventSegment[]
function M.segments(text)
	local out = {}
	local bold = false
	for _, chunk in ipairs(vim.split(text, "**", { plain = true })) do
		if chunk ~= "" then
			if bold then
				table.insert(out, { chunk, "AtlasTimelineObject" })
			else
				split_tokens(chunk, out)
			end
		end
		bold = not bold
	end
	return out
end

---@param actor IssueUser|nil
---@return string
local function actor_name(actor)
	if actor == nil then
		return "Unknown"
	end
	if actor.display_name and actor.display_name ~= "" then
		return actor.display_name
	end
	return tostring(actor.account_id or "Unknown")
end

---@param entry IssueActivityEntry
---@return AtlasTimelineEvent
function M.to_event(entry)
	local text = shorten(summary_line(entry.label ~= nil and entry.label ~= "" and entry.label or entry.kind))
	local icon = icon_for(entry, text)
	return {
		icon = icon.icon,
		icon_hl = icon.hl,
		actor = actor_name(entry.actor),
		segments = M.segments(text),
		time = utils.local_time(entry.date),
	}
end

return M
