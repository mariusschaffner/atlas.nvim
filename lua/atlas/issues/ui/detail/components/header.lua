local M = {}

local icons = require("atlas.ui.shared.icons")
local table_tree = require("atlas.ui.components.table_tree")
local helper = require("atlas.issues.ui.presentation")

---@param text string
---@param hl string|table[]|nil
---@return table[]|nil
local function value_hl_spans(text, hl)
	if type(hl) == "table" then
		return #hl > 0 and hl or nil
	end
	if type(hl) == "string" and hl ~= "" then
		return { { start_col = 0, end_col = #text, hl_group = hl } }
	end
	return nil
end

---@param issue Issue
---@param width integer
---@param fields IssuesDetailHeaderField[]|nil
---@param secondary_fields IssuesDetailHeaderField[]|nil Rendered as a second column alongside `fields`.
---@return string[], table[]
function M.render(issue, width, fields, secondary_fields)
	local issue_type = issue.type and issue.type.name or "Issue"
	local key = issue.key
	local title = issue.title

	local type_icon, type_icon_hl = icons.issues_type(issue_type)
	if type_icon == "" then
		type_icon, type_icon_hl = icons.issues("issue")
	end

	local type_key_line = string.format(" %s %s %s", type_icon, issue_type, key)
	local title_line = " " .. title

	local bell_icon, bell_hl
	if issue.is_subscribed ~= nil then
		if issue.is_subscribed then
			bell_icon = icons.general("bell")
			bell_hl = "AtlasLogInfo"
		else
			bell_icon, bell_hl = icons.general("bell_no")
		end
		local line_w = vim.api.nvim_strwidth(type_key_line)
		local bell_w = vim.api.nvim_strwidth(bell_icon)
		local pad = math.max(1, width - line_w - bell_w - 1)
		type_key_line = type_key_line .. string.rep(" ", pad) .. bell_icon
	end

	local primary = fields or {}
	local secondary = secondary_fields or {}

	local table_lines, table_spans = {}, {}
	if #secondary == 0 then
		-- No second column to show: keep the original single-column layout
		-- exactly as before, rather than reserving empty space for a k2/v2
		-- pair that would never have content.
		local rows = {}
		for _, field in ipairs(primary) do
			table.insert(rows, {
				k1 = field.label .. ":",
				v1 = field.value,
				v1_hl = field.hl,
			})
		end

		if #rows > 0 then
			local rendered_lines, _, rendered_spans = table_tree.render({
				columns = {
					{ key = "k1", name = "", can_grow = false },
					{ key = "v1", name = "", can_grow = true, grow_last = true },
				},
				rows = rows,
				width = width,
				margin = 1,
				show_header = false,
				column_gap = 2,
				fill = true,
				cell_hl = function(row, col)
					if col.key == "k1" then
						return {
							{ start_col = 0, end_col = #row.k1, hl_group = "AtlasTextMuted" },
						}
					end
					if col.key == "v1" then
						return value_hl_spans(row.v1, row.v1_hl)
					end
					return nil
				end,
			})
			table_lines = rendered_lines
			table_spans = rendered_spans
		end
	else
		local row_count = math.max(#primary, #secondary)
		local rows = {}
		for i = 1, row_count do
			local first = primary[i]
			local second = secondary[i]
			table.insert(rows, {
				k1 = first and (first.label .. ":") or "",
				v1 = first and first.value or "",
				v1_hl = first and first.hl or nil,
				k2 = second and (second.label .. ":") or "",
				v2 = second and second.value or "",
				v2_hl = second and second.hl or nil,
			})
		end

		local rendered_lines, _, rendered_spans = table_tree.render({
			columns = {
				{ key = "k1", name = "", can_grow = false },
				{ key = "v1", name = "", can_grow = true },
				{ key = "k2", name = "", can_grow = false },
				{ key = "v2", name = "", can_grow = true, grow_last = true },
			},
			rows = rows,
			width = width,
			margin = 1,
			show_header = false,
			column_gap = 2,
			fill = true,
			cell_hl = function(row, col)
				if col.key == "k1" or col.key == "k2" then
					local label = col.key == "k1" and row.k1 or row.k2
					return { { start_col = 0, end_col = #label, hl_group = "AtlasTextMuted" } }
				end
				if col.key == "v1" then
					return value_hl_spans(row.v1, row.v1_hl)
				end
				if col.key == "v2" then
					return value_hl_spans(row.v2, row.v2_hl)
				end
				return nil
			end,
		})
		table_lines = rendered_lines
		table_spans = rendered_spans
	end

	local lines = { type_key_line, title_line, "" }
	for _, l in ipairs(table_lines) do
		table.insert(lines, l)
	end
	table.insert(lines, "")

	local spans = {
		{ line = 0, line_hl_group = "AtlasTabInactive" },
		{ line = 1, line_hl_group = "AtlasTabInactive" },
		{
			line = 0,
			start_col = 1,
			end_col = #(string.format("%s %s", type_icon, issue_type)) + 1,
			hl_group = type_icon_hl,
		},
		{ line = 1, start_col = 1, end_col = #title_line, hl_group = "Normal" },
	}

	if bell_icon then
		table.insert(spans, {
			line = 0,
			start_col = #type_key_line - #bell_icon,
			end_col = #type_key_line,
			hl_group = bell_hl,
		})
	end

	if key ~= "" then
		local ks = type_key_line:find(key, 1, true)
		if ks then
			table.insert(spans, {
				line = 0,
				start_col = ks - 1,
				end_col = ks - 1 + #key,
				hl_group = helper.issue_hl(key),
			})
		end
	end

	for _, span in ipairs(table_spans) do
		table.insert(spans, {
			line = span.line + 3,
			start_col = span.start_col,
			end_col = span.end_col,
			hl_group = span.hl_group,
		})
	end

	return lines, spans
end

return M
