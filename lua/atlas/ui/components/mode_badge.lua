-- The " INSERT " / " NORMAL " block shown in composer footers, tracking the
-- editing float's actual Vim mode.
local M = {}

---@param mode string Raw `vim.fn.mode()` / `ModeChanged` value.
---@return string text
---@return string hl_group
function M.render(mode)
	if tostring(mode or ""):sub(1, 1) == "i" then
		return " INSERT ", "AtlasModeInsert"
	end
	return " NORMAL ", "AtlasModeNormal"
end

return M
