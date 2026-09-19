local M = {}

local icons = require("atlas.ui.shared.icons")
local field_box = require("atlas.ui.components.field_box")
local helper = require("atlas.issues.ui.presentation")

---@param issue Issue
---@param width integer
---@param fields IssuesDetailHeaderField[]|nil
---@param secondary_fields IssuesDetailHeaderField[]|nil Rendered after `fields`, in the same stack.
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

	local all_fields = {}
	for _, field in ipairs(fields or {}) do
		table.insert(all_fields, field)
	end
	for _, field in ipairs(secondary_fields or {}) do
		table.insert(all_fields, field)
	end

	local box_lines, box_spans = field_box.render(all_fields, { width = width })

	local lines = { type_key_line, title_line, "" }
	for _, l in ipairs(box_lines) do
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

	for _, span in ipairs(box_spans) do
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
