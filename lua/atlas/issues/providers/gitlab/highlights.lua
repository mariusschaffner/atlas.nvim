local M = {}

---@type table<string, table>
local groups = {
	AtlasGLIssuesTheme = { fg = "#1e1e2e", bg = "#fc6d26", bold = true },
	AtlasGLIssueOpen = { fg = "#a6e3a1", bold = true },
	AtlasGLIssueClosed = { fg = "#dd2b0e", bold = true },
	AtlasGLIssueOpenChip = { fg = "#1e1e2e", bg = "#a6e3a1", bold = true },
	AtlasGLIssueClosedChip = { fg = "#1e1e2e", bg = "#dd2b0e", bold = true },
	AtlasGLMilestone = { fg = "#f9e2af", bold = true },
	-- Detail-view title state pill (DESIGN-detail-view.md §3): purple for
	-- closed, distinct from `AtlasGLIssueClosedChip`'s red (used elsewhere) --
	-- kept as a separate group rather than repurposing that one.
	AtlasGLIssueClosedPillChip = { fg = "#1e1e2e", bg = "#bb9af7", bold = true },
	-- Milestone detail-view title state pill (DESIGN-milestone-view.md §3).
	-- "Closed" reuses AtlasGLIssueClosedPillChip above (same purple). These
	-- three cover the milestone-only states.
	AtlasGLMilestoneActivePillChip = { fg = "#1e1e2e", bg = "#a6e3a1", bold = true },
	AtlasGLMilestoneUpcomingPillChip = { fg = "#1e1e2e", bg = "#8aadf4", bold = true },
	AtlasGLMilestoneOverduePillChip = { fg = "#1e1e2e", bg = "#f38ba8", bold = true },
}

function M.setup()
	for name, opts in pairs(groups) do
		vim.api.nvim_set_hl(0, name, opts)
	end
end

return M
