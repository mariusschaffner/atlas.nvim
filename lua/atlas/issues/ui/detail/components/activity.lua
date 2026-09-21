local M = {}

local utils = require("atlas.ui.shared.utils")
local icons = require("atlas.ui.shared.icons")
local presentation = require("atlas.issues.ui.presentation")

local COLLAPSE_KEEP = 2
local COLLAPSE_THRESHOLD = 4

---@param actor IssueUser|nil
---@return string
local function actor_name(actor)
	if actor == nil then
		return "Unknown"
	end
	if actor.display_name and actor.display_name ~= "" then
		return actor.display_name
	end
	if actor.account_id and actor.account_id ~= "" then
		return actor.account_id
	end
	return "Unknown"
end

---@param entry IssueActivityEntry
---@return { additional: string }
function M.classify(entry)
	local raw = tostring(entry.label or "")
	return { additional = raw ~= "" and raw or entry.kind }
end

---@param entries IssueActivityEntry[]
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
		append(
			{ line },
			{ { line = 0, start_col = padding_x, end_col = padding_x + #"│", hl_group = "AtlasBorder" } }
		)
	end

	--- "<username> - <timestamp> - <action>", e.g. "Jane - 14:05 - 15.03.2024 - changed the description".
	---@param entry IssueActivityEntry
	---@param has_next boolean
	local function render_entry(entry, has_next)
		separator()

		local prefix = string.rep(" ", padding_x) .. (has_next and "│  " or "   ")
		local name = actor_name(entry.actor)
		local timestamp = utils.format_datetime(entry.date)
		local action = M.classify(entry).additional or ""

		local parts, entry_spans, cursor = {}, {}, 0
		local function add(text, hl)
			if hl then
				table.insert(entry_spans, { start_col = cursor, end_col = cursor + #text, hl_group = hl })
			end
			table.insert(parts, text)
			cursor = cursor + #text
		end

		add(name, presentation.person_hl(name))
		add(" - ")
		if timestamp ~= "" then
			add(timestamp, "AtlasLogInfo")
			add(" - ")
		end
		add(action, "AtlasTextMuted")

		local line = prefix .. table.concat(parts)
		local line_spans = {}
		if has_next then
			table.insert(
				line_spans,
				{ line = 0, start_col = padding_x, end_col = padding_x + #"│", hl_group = "AtlasBorder" }
			)
		end
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
		for i = 1, COLLAPSE_KEEP do
			render_entry(entries[i], true)
		end
		render_gap(#entries - (COLLAPSE_KEEP * 2))
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
