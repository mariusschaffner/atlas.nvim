local M = {}

--- Opens a new tab and captures its window state, for a diff adapter's
--- reload_view to hand to session.reload() once the old viewer is closed.
--- Shared by the codediff/diffview adapters, whose reload_view otherwise
--- differs (how they close the underlying viewer, and whether/how they
--- report a close failure).
---@return { tabpage: integer, buf: integer, win: integer, number: boolean, relativenumber: boolean, statuscolumn: string, winbar: string }
function M.open_reload_target()
	vim.cmd("tabnew")
	local win = vim.api.nvim_get_current_win()
	return {
		tabpage = vim.api.nvim_get_current_tabpage(),
		buf = vim.api.nvim_get_current_buf(),
		win = win,
		number = vim.wo[win].number,
		relativenumber = vim.wo[win].relativenumber,
		statuscolumn = vim.wo[win].statuscolumn,
		winbar = vim.wo[win].winbar,
	}
end

return M
