local M = {}

local utils = require("atlas.ui.shared.utils")
local render_chips = utils.render_chips

---@param opts { width: integer, padding_x?: integer, extra_chips?: IssuesDetailChip[] }
---@return string[], table[]
function M.render(opts)
	local chips = {}

	for _, chip in ipairs(opts.extra_chips or {}) do
		table.insert(chips, chip)
	end

	if #chips == 0 then
		return {}, {}
	end

	return render_chips(chips, opts)
end

return M
