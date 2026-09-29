-- GitLab-specific half of the unified issue/milestone create view: owns the
-- per-field inline editors (writing into the draft in `create.state` instead
-- of PUTing to GitLab, unlike every other caller of `inline_field_edit`/
-- `inline_edit`), the `:w`/`:q` interception that turns the draft into an
-- actual `POST`, and the final API calls themselves.
local M = {}

local detail_ui = require("atlas.ui.detail")
local state = require("atlas.issues.create.state")
local renderer = require("atlas.issues.create.renderer")
local keymaps = require("atlas.issues.create.keymaps")
local notify = require("atlas.core.notify")
local inline_field_edit = require("atlas.ui.inline_field_edit")
local inline_edit = require("atlas.ui.inline_edit")
local users_api = require("atlas.issues.providers.gitlab.api.users")
local labels_api = require("atlas.issues.providers.gitlab.api.labels")
local milestones_api = require("atlas.issues.providers.gitlab.api.milestones")
local issues_api = require("atlas.issues.providers.gitlab.api.issues")
local users_completion = require("atlas.providers.gitlab.completion.users")
local labels_completion = require("atlas.providers.gitlab.completion.labels")
local milestones_completion = require("atlas.providers.gitlab.completion.milestones")

---@type table<string, IssueUser>
local assignee_by_username = {}
---@type table<string, IssueMilestone>
local milestone_by_title = {}

local function render()
	renderer.render()
end

local function render_if_open()
	if detail_ui.is_showing("create") then
		render()
	end
end

---@return boolean
function M.is_open()
	return detail_ui.is_showing("create")
end

function M.rerender()
	render_if_open()
end

function M.close()
	if M.is_open() then
		detail_ui.close()
	end
end

local TYPE_COMPLETION = {
	fetch = function(query, on_items)
		local q = vim.trim(query):lower()
		local items = {}
		for _, name in ipairs({ "issue", "milestone" }) do
			if q == "" or name:find(q, 1, true) == 1 then
				table.insert(items, { name = name })
			end
		end
		on_items(items)
	end,
}

--- Edits the `Type` field. No-op while another field is already being
--- edited. Switching to a genuinely new type clears every other draft field
--- (title survives) and re-renders with that type's field set.
function M.edit_type()
	local buf = state.buf
	local header_win = state.header_win
	local region = state.header_regions and state.header_regions.type
	if
		buf == nil
		or not vim.api.nvim_buf_is_valid(buf)
		or header_win == nil
		or not vim.api.nvim_win_is_valid(header_win)
		or region == nil
	then
		notify.warn("Type field is not visible")
		return
	end
	if inline_field_edit.is_active() then
		return
	end

	local current = state.type
	keymaps.remove(buf)
	inline_field_edit.start({
		anchor_win = header_win,
		row = region.row,
		col = region.col,
		width = region.width,
		height = region.height,
		seed_text = current,
		seed_resolved = current ~= "" and { current } or {},
		completion = TYPE_COMPLETION,
		on_save = function(text, done)
			local value = vim.trim(text):lower()
			if value == current then
				done(true)
				return
			end
			if value ~= "issue" and value ~= "milestone" then
				local message = 'Type must be "issue" or "milestone"'
				notify.warn(message)
				done(false, message)
				return
			end
			state.type = value
			state.clear_type_fields()
			done(true)
		end,
		on_cancel = function()
			notify.info("Type unchanged", { timeout = 1200 })
		end,
		on_done = function()
			if buf and vim.api.nvim_buf_is_valid(buf) then
				keymaps.register(buf)
			end
			render_if_open()
		end,
	})
end

--- Edits the `Title` field. Required, but (like every other field here)
--- leaving it empty is allowed mid-draft -- only `:w` enforces it.
function M.edit_title()
	local buf = state.buf
	local header_win = state.header_win
	local region = state.header_regions and state.header_regions.title
	if
		buf == nil
		or not vim.api.nvim_buf_is_valid(buf)
		or header_win == nil
		or not vim.api.nvim_win_is_valid(header_win)
		or region == nil
	then
		notify.warn("Title field is not visible")
		return
	end
	if inline_field_edit.is_active() then
		return
	end

	local current = state.fields.title
	keymaps.remove(buf)
	inline_field_edit.start({
		anchor_win = header_win,
		row = region.row,
		col = region.col,
		width = region.width,
		height = region.height,
		seed_text = current,
		seed_resolved = current ~= "" and { current } or {},
		on_save = function(text, done)
			state.fields.title = vim.trim(text)
			done(true)
		end,
		on_cancel = function() end,
		on_done = function()
			if buf and vim.api.nvim_buf_is_valid(buf) then
				keymaps.register(buf)
			end
			render_if_open()
		end,
	})
end

---@param field "start_date"|"due_date"
---@param label string
local function edit_date_field(field, label)
	local buf = state.buf
	local header_win = state.header_win
	local region = state.header_regions and state.header_regions[field]
	if
		buf == nil
		or not vim.api.nvim_buf_is_valid(buf)
		or header_win == nil
		or not vim.api.nvim_win_is_valid(header_win)
		or region == nil
	then
		notify.warn(label .. " field is not visible")
		return
	end
	if inline_field_edit.is_active() then
		return
	end

	local current = state.fields[field]
	keymaps.remove(buf)
	inline_field_edit.start({
		anchor_win = header_win,
		row = region.row,
		col = region.col,
		width = region.width,
		height = region.height,
		seed_text = current,
		seed_resolved = current ~= "" and { current } or {},
		on_save = function(text, done)
			state.fields[field] = vim.trim(text)
			done(true)
		end,
		on_cancel = function() end,
		on_done = function()
			if buf and vim.api.nvim_buf_is_valid(buf) then
				keymaps.register(buf)
			end
			render_if_open()
		end,
	})
end

function M.edit_start_date()
	edit_date_field("start_date", "Start date")
end

function M.edit_due_date()
	edit_date_field("due_date", "Due date")
end

--- Edits the Description content box (whole content buffer, like the real
--- milestone/issue detail views' Description tab), for either type.
function M.edit_description()
	local buf = state.buf
	if buf == nil or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	if inline_edit.is_active(buf) then
		return
	end

	local current = state.fields.description
	keymaps.remove(buf)
	inline_edit.start({
		buf = buf,
		text = current,
		on_save = function(text, done)
			state.fields.description = text or ""
			done(true)
		end,
		on_cancel = function() end,
		on_done = function()
			if buf and vim.api.nvim_buf_is_valid(buf) then
				keymaps.register(buf)
			end
			render_if_open()
		end,
	})
end

--- Browses/inserts a GitLab issue template into the Description field.
--- Issue-type only (there's no milestone-template concept).
function M.edit_templates()
	if state.type ~= "issue" then
		return
	end
	require("atlas.issues.templates").open({
		get_description = function()
			return state.fields.description
		end,
		set_description = function(description)
			state.fields.description = description or ""
			render_if_open()
		end,
		menu_kind = "atlas_gitlab_templates_menu",
	})
end

--- Edits the Assignee field (issue-type only). Draft-local mirror of
--- `issues/providers/gitlab/actions/registry.lua`'s `assign` action: same
--- completion source, but `on_save` writes into the draft instead of
--- PUTing to GitLab.
function M.edit_assignees()
	local buf = state.buf
	local path = state.project_path
	local header_win = state.header_win
	local region = state.header_regions and state.header_regions.assignee
	if
		buf == nil
		or not vim.api.nvim_buf_is_valid(buf)
		or not path
		or path == ""
		or header_win == nil
		or not vim.api.nvim_win_is_valid(header_win)
		or region == nil
	then
		notify.warn("Assignee field is not visible")
		return
	end
	if inline_field_edit.is_active() then
		return
	end

	local seed_names = {}
	for _, a in ipairs(state.fields.assignees) do
		local username = tostring(a.account_id or "")
		if username ~= "" then
			table.insert(seed_names, username)
			assignee_by_username[username:lower()] = a
		end
	end

	local completion = users_completion.for_project(users_api.list_members, path, function(user)
		local username = tostring(user.account_id or "")
		if username == "" then
			return nil
		end
		return {
			name = username,
			display = string.format("%s (@%s)", user.display_name or username, username),
			menu = "member",
		}
	end, function(users)
		for _, user in ipairs(users) do
			local username = tostring(user.account_id or "")
			if username ~= "" then
				assignee_by_username[username:lower()] = user
			end
		end
	end)

	keymaps.remove(buf)
	inline_field_edit.start({
		anchor_win = header_win,
		row = region.row,
		col = region.col,
		width = region.width,
		height = region.height,
		seed_text = table.concat(seed_names, ", "),
		multi_value = true,
		seed_resolved = seed_names,
		completion = completion,
		on_save = function(text, done)
			local selected = {}
			for _, segment in ipairs(vim.split(text, ",", { plain = true })) do
				local trimmed = vim.trim(segment)
				if trimmed ~= "" then
					local user = assignee_by_username[trimmed:lower()]
					if user then
						table.insert(selected, user)
					end
				end
			end
			state.fields.assignees = selected
			done(true)
		end,
		on_cancel = function() end,
		on_done = function()
			if buf and vim.api.nvim_buf_is_valid(buf) then
				keymaps.register(buf)
			end
			render_if_open()
		end,
	})
end

--- Edits the Labels field (issue-type only).
function M.edit_labels()
	local buf = state.buf
	local path = state.project_path
	local header_win = state.header_win
	local region = state.header_regions and state.header_regions.labels
	if
		buf == nil
		or not vim.api.nvim_buf_is_valid(buf)
		or not path
		or path == ""
		or header_win == nil
		or not vim.api.nvim_win_is_valid(header_win)
		or region == nil
	then
		notify.warn("Labels field is not visible")
		return
	end
	if inline_field_edit.is_active() then
		return
	end

	local seed_names = {}
	for _, l in ipairs(state.fields.labels) do
		local name = tostring(l.name or "")
		if name ~= "" then
			table.insert(seed_names, name)
		end
	end

	local completion = labels_completion.for_project(labels_api.list, path)

	keymaps.remove(buf)
	inline_field_edit.start({
		anchor_win = header_win,
		row = region.row,
		col = region.col,
		width = region.width,
		height = region.height,
		seed_text = table.concat(seed_names, ", "),
		multi_value = true,
		seed_resolved = seed_names,
		completion = completion,
		on_save = function(text, done)
			local selected = {}
			for _, segment in ipairs(vim.split(text, ",", { plain = true })) do
				local trimmed = vim.trim(segment)
				if trimmed ~= "" then
					table.insert(selected, { name = trimmed })
				end
			end
			state.fields.labels = selected
			done(true)
		end,
		on_cancel = function() end,
		on_done = function()
			if buf and vim.api.nvim_buf_is_valid(buf) then
				keymaps.register(buf)
			end
			render_if_open()
		end,
	})
end

--- Edits the Milestone field (issue-type only) -- attaches the new issue to
--- an *existing* milestone. Unrelated to the create view's own `Type` field.
function M.edit_milestone()
	local buf = state.buf
	local path = state.project_path
	local header_win = state.header_win
	local region = state.header_regions and state.header_regions.milestone
	if
		buf == nil
		or not vim.api.nvim_buf_is_valid(buf)
		or not path
		or path == ""
		or header_win == nil
		or not vim.api.nvim_win_is_valid(header_win)
		or region == nil
	then
		notify.warn("Milestone field is not visible")
		return
	end
	if inline_field_edit.is_active() then
		return
	end

	local current = state.fields.milestone
	local current_title = current and tostring(current.title or "") or ""

	local completion = milestones_completion.for_project(milestones_api.list, path, function(milestones)
		for _, item in ipairs(milestones) do
			local title = tostring(item.title or "")
			if title ~= "" and tonumber(item.id) then
				milestone_by_title[title:lower()] = item
			end
		end
	end)

	keymaps.remove(buf)
	inline_field_edit.start({
		anchor_win = header_win,
		row = region.row,
		col = region.col,
		width = region.width,
		height = region.height,
		seed_text = current_title,
		seed_resolved = current_title ~= "" and { current_title } or {},
		completion = completion,
		on_save = function(text, done)
			local trimmed = vim.trim(text)
			if trimmed == "" then
				state.fields.milestone = nil
				done(true)
				return
			end
			local milestone = milestone_by_title[trimmed:lower()]
			if milestone == nil then
				done(false, "Unknown milestone: " .. trimmed)
				return
			end
			state.fields.milestone = milestone
			done(true)
		end,
		on_cancel = function() end,
		on_done = function()
			if buf and vim.api.nvim_buf_is_valid(buf) then
				keymaps.register(buf)
			end
			render_if_open()
		end,
	})
end

---@return string[]
local function missing_required()
	local missing = {}
	if state.type == "" then
		table.insert(missing, "Type")
	end
	if vim.trim(state.fields.title) == "" then
		table.insert(missing, "Title")
	end
	return missing
end

---@return table
local function build_issue_payload()
	local label_names = {}
	for _, l in ipairs(state.fields.labels) do
		table.insert(label_names, l.name)
	end
	local assignee_ids = {}
	for _, a in ipairs(state.fields.assignees) do
		local id = tonumber(a.id)
		if id then
			table.insert(assignee_ids, id)
		end
	end
	return {
		project_path = state.project_path,
		title = vim.trim(state.fields.title),
		description = state.fields.description ~= "" and state.fields.description or nil,
		labels = label_names,
		assignee_ids = assignee_ids,
		milestone_id = state.fields.milestone and state.fields.milestone.id or nil,
		due_date = state.fields.due_date ~= "" and state.fields.due_date or nil,
	}
end

--- `:w` handler: validates the two required fields, then fires the actual
--- `create_issue`/`create_milestone` API call. Leaves the view open (and
--- 'modified') on failure so the user can fix something and `:w` again.
local function attempt_submit()
	if not M.is_open() or state.submitting then
		return
	end

	local missing = missing_required()
	if #missing > 0 then
		local plural = #missing > 1 and "are" or "is"
		notify.warn(table.concat(missing, ", ") .. " " .. plural .. " required")
		return
	end

	state.submitting = true

	if state.type == "milestone" then
		notify.loading("Creating milestone...")
		state.requests.run(function(done)
			return milestones_api.create(state.project_path, {
				title = vim.trim(state.fields.title),
				description = state.fields.description ~= "" and state.fields.description or nil,
				start_date = state.fields.start_date ~= "" and state.fields.start_date or nil,
				due_date = state.fields.due_date ~= "" and state.fields.due_date or nil,
			}, done)
		end, function(milestone, err)
			state.submitting = false
			if err or milestone == nil then
				notify.error("Create milestone failed: " .. tostring(err or "Unknown error"))
				return
			end
			local on_done = state.on_done
			notify.success("Milestone created: " .. tostring(milestone.title), { timeout = 1200 })
			M.close()
			if on_done then
				on_done({ refresh = true }, nil)
			end
		end)
	else
		notify.loading("Creating issue...")
		state.requests.run(function(done)
			return issues_api.create_issue(build_issue_payload(), done)
		end, function(result, err)
			state.submitting = false
			if err or result == nil then
				notify.error("Create issue failed: " .. tostring(err or "Unknown error"))
				return
			end
			local on_done = state.on_done
			notify.success("Issue created: " .. tostring(result.key), { timeout = 1200 })
			M.close()
			if on_done then
				on_done({ issue_key = result.key, refresh = true }, nil)
			end
		end)
	end
end

---@param buf integer
local function setup_write_cmd(buf)
	local group = vim.api.nvim_create_augroup("AtlasCreateWrite" .. tostring(buf), { clear = true })
	vim.api.nvim_create_autocmd("BufWriteCmd", { group = group, buffer = buf, callback = attempt_submit })
end

---@param buf integer
local function setup_quit_cmd(buf)
	pcall(vim.api.nvim_buf_del_user_command, buf, "AtlasCreateQuit")
	vim.api.nvim_buf_create_user_command(buf, "AtlasCreateQuit", M.close, { desc = "Discard Atlas creation draft" })
	vim.api.nvim_buf_call(buf, function()
		vim.cmd("silent! cunabbrev <buffer> q")
		vim.cmd("silent! cunabbrev <buffer> quit")
		vim.cmd("cnoreabbrev <buffer> q AtlasCreateQuit")
		vim.cmd("cnoreabbrev <buffer> quit AtlasCreateQuit")
	end)
end

local function cleanup()
	local buf = state.buf
	if buf and vim.api.nvim_buf_is_valid(buf) then
		keymaps.remove(buf)
	end
	state.reset()
end

---@param opts { project_path: string, initial_type: (""|"issue"|"milestone")|nil, on_done: (fun(result: table|nil, err: string|nil))|nil }
function M.open(opts)
	opts = opts or {}
	local project_path = tostring(opts.project_path or "")
	if project_path == "" then
		notify.error("create.open: project_path is required", { vim_notify = true })
		return
	end

	require("atlas.ui.shared.highlights").setup()
	require("atlas.issues.providers.gitlab.highlights").setup()

	assignee_by_username = {}
	milestone_by_title = {}

	state.reset()
	state.win, state.buf, state.header_win, state.header_buf = detail_ui.open("create", cleanup, render)
	state.project_path = project_path
	state.type = (opts.initial_type == "issue" or opts.initial_type == "milestone") and opts.initial_type or ""
	state.on_done = opts.on_done

	if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
		vim.bo[state.buf].buftype = "acwrite"
		setup_write_cmd(state.buf)
		setup_quit_cmd(state.buf)
		keymaps.register(state.buf)
	end

	render()
end

return M
