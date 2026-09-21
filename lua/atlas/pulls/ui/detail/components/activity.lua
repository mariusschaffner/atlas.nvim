local M = {}

local utils = require("atlas.ui.shared.utils")
local icons = require("atlas.ui.shared.icons")
local highlights = require("atlas.ui.shared.highlights")

local COLLAPSE_KEEP = 3
local COLLAPSE_THRESHOLD = 5

---@param actor {nickname:string?, name:string?}|nil
---@return string
local function actor_name(actor)
	if actor == nil then
		return "Unknown"
	end
	if actor.nickname and actor.nickname ~= "" then
		return actor.nickname
	end
	if actor.name and actor.name ~= "" then
		return actor.name
	end
	return "Unknown"
end

---@param name string|nil
---@return string
local function person_hl(name)
	local normalized = name and vim.trim(name):lower() or ""
	if normalized == "" or normalized == "unknown" or normalized == "none" then
		return "AtlasTextMutedItalic"
	end
	return highlights.dynamic_for(normalized) or "AtlasTextMuted"
end

local EVENT = {
	approval = icons.pulls_status("successful"),
	unapproval = icons.pulls_status("inprogress"),
	changes_requested = icons.pulls_status("inprogress"),
	review = icons.pulls("activity"),
	review_dismissed = icons.pulls_status("stopped"),
	comment = icons.general("user"),
	comment_deleted = icons.general("delete"),
	closed = icons.pulls("declined_pr"),
	merged = icons.pulls("merged_pr"),
	reopened = icons.pulls("pr"),
	committed = icons.pulls("commit"),
	force_pushed = icons.general("edit"),
	labeled = icons.pulls("tag"),
	unlabeled = icons.pulls("tag"),
	assigned = icons.general("user"),
	unassigned = icons.general("user"),
	review_requested = icons.general("user"),
	renamed = icons.general("edit"),
	ready_for_review = icons.pulls("pr"),
	convert_to_draft = icons.pulls("activity"),
	update = icons.pulls("activity"),
}

---@param entry PullsActivityEntry
---@return { icon: string, icon_hl: string|nil, additional: string|nil }
function M.classify(entry)
	local icon = EVENT[entry.kind] or icons.pulls("activity")
	local icon_hl = "AtlasTextMuted"
	if entry.kind == "approval" then
		icon_hl = "AtlasTextPositive"
	elseif entry.kind == "changes_requested" then
		icon_hl = "AtlasTextWarning"
	end
	local label = tostring(entry.label or "")
	return {
		icon = icon,
		icon_hl = icon_hl,
		additional = label ~= "" and label or entry.kind,
	}
end

---Render a list of activities.
---@param entries PullsActivityEntry[]
---@param width integer
---@param opts { padding_x: integer|nil, squash: boolean|nil, run_id: string|nil, has_next: boolean|nil }|nil
---@return string[] lines, table[] spans, table<integer, table>|nil line_map
function M.render(entries, width, opts)
	opts = opts or {}
	local padding_x = opts.padding_x or 1

	local lines, spans, line_map = {}, {}, {}

	local function append(sub_lines, sub_spans, sub_map)
		local base = #lines
		for _, l in ipairs(sub_lines) do
			table.insert(lines, l)
		end
		for _, s in ipairs(sub_spans) do
			s.line = s.line + base
			table.insert(spans, s)
		end
		for lnum, data in pairs(sub_map or {}) do
			line_map[base + lnum] = data
		end
	end

	local function separator()
		if #lines == 0 then
			return
		end
		local line = string.rep(" ", padding_x) .. "│"
		append({ line }, { { line = 0, start_col = padding_x, end_col = padding_x + #"│", hl_group = "AtlasTextMuted" } })
	end

	--- "<icon> <name> - <timestamp> - <action>".
	---@param entry PullsActivityEntry
	---@param has_next boolean
	local function render_entry(entry, has_next)
		separator()

		local prefix = string.rep(" ", padding_x) .. (has_next and "│  " or "   ")
		local classified = M.classify(entry)
		local name = actor_name(entry.actor)
		local timestamp = utils.format_datetime(entry.date)
		local action = classified.additional or ""

		local parts, entry_spans, cursor = {}, {}, 0
		local function add(text, hl)
			if hl then
				table.insert(entry_spans, { start_col = cursor, end_col = cursor + #text, hl_group = hl })
			end
			table.insert(parts, text)
			cursor = cursor + #text
		end

		add(classified.icon .. " ", classified.icon_hl)
		add(name, person_hl(name))
		add(" - ")
		if timestamp ~= "" then
			add(timestamp, "AtlasLogInfo")
			add(" - ")
		end
		add(action, "AtlasTextMuted")

		local line = prefix .. table.concat(parts)
		local line_spans = {}
		for _, span in ipairs(entry_spans) do
			table.insert(line_spans, {
				line = 0,
				start_col = #prefix + span.start_col,
				end_col = #prefix + span.end_col,
				hl_group = span.hl_group,
			})
		end

		append({ line }, line_spans, {
			[1] = { kind = "activity", activity_entry = entry, activity_actor = entry.actor, run_id = opts.run_id },
		})
	end

	local function render_gap(count)
		separator()
		local text = string.format(
			"%s  ... %d more %s",
			icons.general("activity_more"),
			count,
			count == 1 and "activity" or "activities"
		)
		local line = string.rep(" ", padding_x) .. text
		append(
			{ line },
			{ { line = 0, start_col = padding_x, end_col = padding_x + #text, hl_group = "AtlasTextMuted" } },
			opts.run_id and { [1] = { kind = "activity_gap", run_id = opts.run_id } } or nil
		)
	end

	if opts.squash and #entries > COLLAPSE_THRESHOLD then
		render_gap(#entries - COLLAPSE_KEEP)
		for i = #entries - COLLAPSE_KEEP + 1, #entries do
			render_entry(entries[i], i < #entries or opts.has_next == true)
		end
	else
		for i, entry in ipairs(entries) do
			render_entry(entry, i < #entries or opts.has_next == true)
		end
	end

	return lines, spans, line_map
end

return M
