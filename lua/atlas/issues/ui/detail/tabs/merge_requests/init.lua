-- "Merge requests" tab (DESIGN-detail-view.md §5/§7): lists the merge
-- requests already linked to this issue. Pure presentation -- reuses
-- `state.linked_merge_requests`, which the detail view's `init.lua` already
-- fetches (via the provider's `fetch_linked_merge_requests`) for the sidebar
-- Development field, so this tab triggers no fetch of its own.
local M = {}

local utils = require("atlas.ui.shared.utils")
local spinner = require("atlas.ui.components.spinner")
local detail_state = require("atlas.issues.ui.detail.state")

local PADDING_X = 1

---@param mr IssueLinkedMergeRequest
---@return string
local function state_hl(mr)
	if mr.state == "merged" then
		return "AtlasTextPositive"
	end
	if mr.state == "closed" then
		return "AtlasLogError"
	end
	return "AtlasTextMuted"
end

---@param _issue Issue
---@param _details IssueDetails|nil
---@param _width integer
---@return string[] lines
---@return AtlasUIHighlight[] highlights
---@return table<integer, table> line_map
function M.render(_issue, _details, _width)
	local lines, spans = {}, {}
	local value = detail_state.linked_merge_requests

	if value == nil or value == "loading" then
		utils.push(lines, spans, spinner.with_text("Loading merge requests..."), "AtlasTextMuted", PADDING_X)
		return lines, spans, {}
	end
	if type(value) == "string" then
		utils.push(lines, spans, value, "AtlasLogError", PADDING_X)
		return lines, spans, {}
	end
	if #value == 0 then
		utils.push(lines, spans, "No linked merge requests", "AtlasTextMutedItalic", PADDING_X)
		return lines, spans, {}
	end

	for _, mr in ipairs(value) do
		local text = string.format("!%d %s", mr.id, tostring(mr.title or ""))
		utils.push(lines, spans, text, state_hl(mr), PADDING_X)
	end
	return lines, spans, {}
end

return M
