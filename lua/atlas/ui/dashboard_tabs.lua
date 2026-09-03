local M = {}

local icons = require("atlas.ui.shared.icons")

local ITEMS = { "issues", "pulls" }
local LABELS = { issues = "Issues", pulls = "Pulls" }

---@param active_domain string|nil
---@param width integer
---@return string[], table[]
function M.render(active_domain, width)
	local lines, spans = {}, {}

	local line = "  "
	local col = #line
	for _, key in ipairs(ITEMS) do
		local active = key == active_domain
		local icon = key == "issues" and icons.issues("issue") or icons.pulls("pr")
		local label = string.format("  %s  %s  ", icon, LABELS[key])
		line = line .. label
		table.insert(spans, {
			line = 1,
			start_col = col,
			end_col = col + #label,
			hl_group = active and "AtlasChipActive" or "AtlasTabInactive",
		})
		col = col + #label + 2
		line = line .. "  "
	end

	table.insert(lines, "")
	table.insert(lines, line)
	table.insert(lines, "")

	local divider = string.rep("━", math.max(1, width))
	table.insert(lines, divider)
	table.insert(spans, { line = 3, start_col = 0, end_col = #divider, hl_group = "AtlasBorder" })

	return lines, spans
end

return M
