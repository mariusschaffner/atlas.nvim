-- Shell for the unified issue/milestone/merge-request create view: owns
-- `M.open`, the `:w`/`:q` interception that turns the draft into an actual
-- API call, and the fully generic (type-independent) field editors -- Type,
-- Title, Description. Domain-specific field editors (Assignee/Labels/
-- Milestone/dates for issue+milestone; Source/Target branch/Reviewers/
-- Assignees/Labels/Draft for merge_request) live in
-- `atlas.issues.create.gitlab`/`atlas.pulls.create.gitlab` respectively, and
-- reuse `M.edit_text_field`/`M.edit_completion_field` below instead of each
-- re-implementing the same `inline_field_edit.start({...})` boilerplate.
local M = {}

local detail_ui = require("atlas.ui.detail")
local state = require("atlas.ui.create.state")
local renderer = require("atlas.ui.create.renderer")
local keymaps = require("atlas.ui.create.keymaps")
local notify = require("atlas.core.notify")
local inline_field_edit = require("atlas.ui.inline_field_edit")
local inline_edit = require("atlas.ui.inline_edit")

---@type table<""|"issue"|"milestone"|"merge_request", string[]>
local REQUIRED_FIELDS = {
	issue = { "type", "title" },
	milestone = { "type", "title" },
	merge_request = { "type", "title", "source_branch", "target_branch" },
}

---@type table<string, string>
local FIELD_LABELS = {
	type = "Type",
	title = "Title",
	source_branch = "Source branch",
	target_branch = "Target branch",
}

local function render()
	renderer.render()
end

local function render_if_open()
	if detail_ui.is_showing("create") then
		render()
	end
end
M.render_if_open = render_if_open

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
		for _, name in ipairs({ "issue", "milestone", "merge_request" }) do
			if q == "" or name:find(q, 1, true) == 1 then
				table.insert(items, { name = name })
			end
		end
		on_items(items)
	end,
}

--- Generic single-line field editor with no completion (e.g. dates): looks
--- up the field's region, opens `inline_field_edit`, and writes the trimmed
--- result straight into `state.fields[field_id]`. Never rejects empty text
--- -- like every field here, a required field can sit empty mid-draft; only
--- `:w` enforces the requirement.
---@param field_id string
---@param label string
function M.edit_text_field(field_id, label)
	local buf = state.buf
	local header_win = state.header_win
	local region = state.header_regions and state.header_regions[field_id]
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

	local current = tostring(state.fields[field_id] or "")
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
			state.fields[field_id] = vim.trim(text)
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

--- Generic completion-backed field editor (single or multi-value): looks up
--- the field's region and handles the `keymaps.remove`/`inline_field_edit.
--- start`/`keymaps.register` dance; the caller supplies everything that's
--- actually domain-specific (label for the "field not visible" warning,
--- seed text/resolved values, the completion provider, and `on_save`, which
--- knows how to turn typed text back into the draft's own value shape).
---@param field_id string
---@param opts { label: string, multi_value: boolean|nil, seed_text: string, seed_resolved: string[]|nil, completion: AtlasFieldCompletionProvider|nil, on_save: fun(text: string, done: fun(ok: boolean, err: string|nil)), on_cancel: (fun())|nil }
function M.edit_completion_field(field_id, opts)
	local buf = state.buf
	local header_win = state.header_win
	local region = state.header_regions and state.header_regions[field_id]
	if
		buf == nil
		or not vim.api.nvim_buf_is_valid(buf)
		or header_win == nil
		or not vim.api.nvim_win_is_valid(header_win)
		or region == nil
	then
		notify.warn(opts.label .. " field is not visible")
		return
	end
	if inline_field_edit.is_active() then
		return
	end

	keymaps.remove(buf)
	inline_field_edit.start({
		anchor_win = header_win,
		row = region.row,
		col = region.col,
		width = region.width,
		height = region.height,
		seed_text = opts.seed_text,
		multi_value = opts.multi_value,
		seed_resolved = opts.seed_resolved,
		completion = opts.completion,
		on_save = opts.on_save,
		on_cancel = opts.on_cancel or function() end,
		on_done = function()
			if buf and vim.api.nvim_buf_is_valid(buf) then
				keymaps.register(buf)
			end
			render_if_open()
		end,
	})
end

--- Edits the `Type` field. No-op while another field is already being
--- edited. Switching to a genuinely new type clears every other draft field
--- (title survives) and re-renders with that type's field set; for
--- merge_request, also best-effort-applies local git defaults (current
--- branch, default remote branch) if we're in a suitable repo.
function M.edit_type()
	local current = state.type
	M.edit_completion_field("type", {
		label = "Type",
		seed_text = current,
		seed_resolved = current ~= "" and { current } or {},
		completion = TYPE_COMPLETION,
		on_save = function(text, done)
			local value = vim.trim(text):lower()
			if value == current then
				done(true)
				return
			end
			if value ~= "issue" and value ~= "milestone" and value ~= "merge_request" then
				local message = 'Type must be "issue", "milestone" or "merge_request"'
				notify.warn(message)
				done(false, message)
				return
			end
			state.type = value
			state.clear_type_fields()
			done(true)
			if value == "merge_request" then
				require("atlas.pulls.create.gitlab").try_apply_git_defaults()
			end
		end,
		on_cancel = function()
			notify.info("Type unchanged", { timeout = 1200 })
		end,
	})
end

--- Edits the `Title` field. Required, but (like every other field here)
--- leaving it empty is allowed mid-draft -- only `:w` enforces it.
function M.edit_title()
	M.edit_text_field("title", "Title")
end

--- Edits the Description content box (whole content buffer, like the real
--- milestone/issue/PR detail views' Description tab), for every type.
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

---@return string[]
local function missing_required()
	local missing = {}
	local required = REQUIRED_FIELDS[state.type]
	if required == nil then
		table.insert(missing, "Type")
		return missing
	end
	for _, field_id in ipairs(required) do
		local value = field_id == "type" and state.type or state.fields[field_id]
		if vim.trim(tostring(value or "")) == "" then
			table.insert(missing, FIELD_LABELS[field_id] or field_id)
		end
	end
	return missing
end

--- `:w` handler: validates the type's required fields, then dispatches to
--- the owning domain module's `M.submit()`. Leaves the view open (and
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

	if state.type == "merge_request" then
		require("atlas.pulls.create.gitlab").submit()
	else
		require("atlas.issues.create.gitlab").submit()
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

---@param opts { project_path: string, repo_root: string|nil, initial_type: (""|"issue"|"milestone"|"merge_request")|nil, initial_fields: table|nil, on_done: (fun(result: table|nil, err: string|nil))|nil }
function M.open(opts)
	opts = opts or {}
	local project_path = tostring(opts.project_path or "")
	if project_path == "" then
		notify.error("create.open: project_path is required", { vim_notify = true })
		return
	end

	require("atlas.ui.shared.highlights").setup()
	require("atlas.issues.providers.gitlab.highlights").setup()
	require("atlas.pulls.ui.highlights").setup()

	state.reset()
	state.win, state.buf, state.header_win, state.header_buf = detail_ui.open("create", cleanup, render)
	state.project_path = project_path
	state.repo_root = opts.repo_root
	state.type = REQUIRED_FIELDS[opts.initial_type] ~= nil and opts.initial_type or ""
	state.on_done = opts.on_done
	if type(opts.initial_fields) == "table" then
		for key, value in pairs(opts.initial_fields) do
			state.fields[key] = value
		end
	end

	if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
		vim.bo[state.buf].buftype = "acwrite"
		setup_write_cmd(state.buf)
		setup_quit_cmd(state.buf)
		keymaps.register(state.buf)
	end

	render()

	state.current_user_loading = true
	state.requests.run(function(done)
		return require("atlas.issues.providers.gitlab.api.users").get_user(done)
	end, function(user, err)
		state.current_user_loading = false
		if not err and user then
			state.current_user = user
		end
		render_if_open()
	end)
end

return M
