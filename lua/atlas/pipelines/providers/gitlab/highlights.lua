local M = {}

---@type table<string, table>
local groups = {
	AtlasGLPipelineTheme = { fg = "#1e1e2e", bg = "#fc6d26", bold = true },
	AtlasGLPipelineSuccessChip = { fg = "#1e1e2e", bg = "#a6da95", bold = true },
	AtlasGLPipelineFailedChip = { fg = "#1e1e2e", bg = "#f38ba8", bold = true },
	AtlasGLPipelineRunningChip = { fg = "#1e1e2e", bg = "#f9e2af", bold = true },
	AtlasGLPipelineMutedChip = { fg = "#1e1e2e", bg = "#7f849c", bold = true },
	-- Detail-view state pills (DESIGN-pipeline-view.md §2), in the same style
	-- as the issue/milestone/MR pills.
	AtlasGLPipelineRunningPillChip = { fg = "#1e1e2e", bg = "#7dcfff", bold = true },
	AtlasGLPipelinePendingPillChip = { fg = "#1e1e2e", bg = "#e0af68", bold = true },
	AtlasGLPipelinePassedPillChip = { fg = "#1e1e2e", bg = "#a6e3a1", bold = true },
	AtlasGLPipelineFailedPillChip = { fg = "#1e1e2e", bg = "#f7768e", bold = true },
	AtlasGLPipelineCanceledPillChip = { fg = "#1e1e2e", bg = "#6c7086", bold = true },
	AtlasGLPipelineManualPillChip = { fg = "#1e1e2e", bg = "#e0af68", bold = true },
}

function M.setup()
	for name, opts in pairs(groups) do
		vim.api.nvim_set_hl(0, name, opts)
	end
end

return M
