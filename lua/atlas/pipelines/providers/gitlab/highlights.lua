local M = {}

---@type table<string, table>
local groups = {
	AtlasGLPipelineTheme = { fg = "#1e1e2e", bg = "#fc6d26", bold = true },
	AtlasGLPipelineSuccessChip = { fg = "#1e1e2e", bg = "#a6da95", bold = true },
	AtlasGLPipelineFailedChip = { fg = "#1e1e2e", bg = "#f38ba8", bold = true },
	AtlasGLPipelineRunningChip = { fg = "#1e1e2e", bg = "#f9e2af", bold = true },
	AtlasGLPipelineMutedChip = { fg = "#1e1e2e", bg = "#7f849c", bold = true },
}

function M.setup()
	for name, opts in pairs(groups) do
		vim.api.nvim_set_hl(0, name, opts)
	end
end

return M
