local request_scope = require("atlas.core.requests")

---@class CreateDraftFields
---@field title string
---@field description string
---@field start_date string
---@field due_date string
---@field assignees IssueUser[]
---@field labels IssueLabel[]
---@field milestone IssueMilestone|nil

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
	}
end

---@class CreateViewState
---@field win integer|nil
---@field buf integer|nil
---@field header_win integer|nil
---@field header_buf integer|nil
---@field header_regions table<string, AtlasFieldBoxRegion>
---@field project_path string|nil
---@field type ""|"issue"|"milestone"
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
--- to `Type=issue`). `title` is shared by both types and kept as-is.
function M.clear_type_fields()
	local title = M.fields.title
	M.fields = empty_fields()
	M.fields.title = title
end

return M
