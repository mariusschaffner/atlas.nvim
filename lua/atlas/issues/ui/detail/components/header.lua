local M = {}

local icons = require("atlas.ui.shared.icons")
local field_box = require("atlas.ui.components.field_box")

---@param issue Issue
---@param width integer
---@param fields IssuesDetailHeaderField[]|nil
---@param secondary_fields IssuesDetailHeaderField[]|nil Rendered as a separate right-hand column, aligned below itself.
---@param status_badge IssuesTitleStatus|nil Border color for the title field (open/closed); its `.text` is unused now that the border color conveys status.
---@return string[], table[]
function M.render(issue, width, fields, secondary_fields, status_badge)
	local title_field = {
		label = issue.key,
		value = issue.title,
		border_hl = status_badge and status_badge.hl or nil,
	}

	if issue.is_subscribed ~= nil then
		local bell_icon, bell_hl
		if issue.is_subscribed then
			bell_icon = icons.general("bell")
			bell_hl = "AtlasLogInfo"
		else
			bell_icon, bell_hl = icons.general("bell_no")
		end
		title_field.right_content = {
			lines = { bell_icon },
			highlights = { { start_col = 0, end_col = #bell_icon, hl_group = bell_hl } },
		}
	end

	return field_box.render_columns(fields or {}, secondary_fields or {}, {
		width = width,
		top_field = title_field,
	})
end

return M
