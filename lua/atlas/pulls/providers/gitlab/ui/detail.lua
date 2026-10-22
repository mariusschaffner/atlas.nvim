---@type PullsProviderDetail
local M = {}

local icons = require("atlas.ui.shared.icons")
local highlights = require("atlas.ui.shared.highlights")

--- Tinted chip highlight for a label's own colour (sidebar LABELS field).
---@param hex string|nil
---@return string
function M.label_chip_hl(hex)
	return highlights.label_hl(hex, "AtlasGLPRLabelChip_", "AtlasChipActive")
end

--- Fg-only variant of `label_chip_hl`, for a rounded chip's end-cap glyphs.
---@param hex string|nil
---@return string
function M.label_cap_hl(hex)
	return highlights.label_fg_hl(hex, "AtlasGLPRLabelCap_", "AtlasChipActive")
end

---@return PullsDetailTab[]
function M.tabs()
	local overview_icon, overview_hl = icons.general("overview")
	local pipeline_icon, pipeline_hl = icons.pulls("pipeline")
	local conversation_icon, conversation_hl = icons.general("conversation")
	local changes_icon, changes_hl = icons.pulls("review")
	local commit_icon, commit_hl = icons.pulls("commit")
	return {
		{
			key = "overview",
			label = "Description",
			icon = { icon = overview_icon, hl_group = overview_hl },
			mod = require("atlas.pulls.ui.detail.tabs.overview"),
		},
		{
			key = "conversation",
			label = "Activity",
			icon = { icon = conversation_icon, hl_group = conversation_hl },
			mod = require("atlas.pulls.ui.detail.tabs.conversation"),
		},
		{
			key = "changes",
			label = "Changes",
			icon = { icon = changes_icon, hl_group = changes_hl },
			mod = require("atlas.pulls.ui.detail.tabs.changes"),
		},
		{
			key = "commits",
			label = "Commits",
			icon = { icon = commit_icon, hl_group = commit_hl },
			mod = require("atlas.pulls.ui.detail.tabs.commits"),
		},
		{
			key = "pipelines",
			label = "Pipelines",
			icon = { icon = pipeline_icon, hl_group = pipeline_hl },
			mod = require("atlas.pulls.ui.detail.tabs.pipelines"),
		},
	}
end

return M
