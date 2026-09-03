local request_scope = require("atlas.core.requests")

---@class PullsOverviewState
---@field reviewers PullsReviewer[]|"loading"|string|nil
---@field merge_checks PullsMergeCheck[]|"loading"|string|nil
---@field requests AtlasRequestScope
local M = {
	reviewers = nil,
	merge_checks = nil,
	requests = request_scope.new(),
}

function M.reset()
	M.reviewers = nil
	M.merge_checks = nil
	M.requests.cancel()
	M.requests = request_scope.new()
end

return M
