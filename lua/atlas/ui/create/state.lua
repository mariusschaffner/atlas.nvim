local request_scope = require("atlas.core.requests")

---@class CreateDraftFields
---@field title string
---@field description string
---@field start_date string
---@field due_date string
---@field assignees IssueUser[]|PullsAuthor[]
---@field labels IssueLabel[]|PullsLabel[]
---@field milestone IssueMilestone|nil issue-only: attaches to an *existing* milestone.
---@field source_branch string merge_request-only.
---@field target_branch string merge_request-only.
---@field reviewers PullsAuthor[] merge_request-only.
---@field draft boolean merge_request-only.

---@return CreateDraftFields
local function empty_fields()
	return {
		title = "",
		description = "",
		start_date = "",
		due_date = "",
		assignees = {},
		labels = {},
		milestone = nil,
		source_branch = "",
		target_branch = "",
		reviewers = {},
		draft = false,
	}
end

---@class CreateViewState
---@field win integer|nil
---@field buf integer|nil
---@field header_win integer|nil
---@field header_buf integer|nil
---@field header_regions table<string, AtlasFieldBoxRegion>
---@field project_path string|nil GitLab project/repo path ("group/project"), used by all three types.
---@field repo_root string|nil Local git repo root -- merge_request-only (needed to push the source branch).
---@field type ""|"issue"|"milestone"|"merge_request"
---@field fields CreateDraftFields
---@field current_user IssueUser|nil The signed-in user, shown read-only as the issue-type Author field.
---@field current_user_loading boolean
---@field requests AtlasRequestScope
---@field on_done (fun(result: table|nil, err: string|nil))|nil
---@field submitting boolean
local M = {
	win = nil,
	buf = nil,
	header_win = nil,
	header_buf = nil,
	header_regions = {},
	project_path = nil,
	repo_root = nil,
	type = "",
	fields = empty_fields(),
	current_user = nil,
	current_user_loading = false,
	requests = request_scope.new(),
	on_done = nil,
	submitting = false,
}

function M.reset()
	M.win = nil
	M.buf = nil
	M.header_win = nil
	M.header_buf = nil
	M.header_regions = {}
	M.project_path = nil
	M.repo_root = nil
	M.type = ""
	M.fields = empty_fields()
	M.current_user = nil
	M.current_user_loading = false
	M.on_done = nil
	M.submitting = false
	M.requests.cancel()
	M.requests = request_scope.new()
end

--- Clears every field that doesn't belong to the newly selected type, so
--- switching `Type` mid-draft doesn't silently carry over values the new
--- type will never submit (e.g. a milestone's start date surviving a switch
--- to `Type=issue`). `title` is shared by every type and kept as-is.
function M.clear_type_fields()
	local title = M.fields.title
	M.fields = empty_fields()
	M.fields.title = title
end

return M
