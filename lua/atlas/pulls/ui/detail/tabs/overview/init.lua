local M = {}

local utils = require("atlas.ui.shared.utils")
local spinner = require("atlas.ui.components.spinner")
local detail = require("atlas.pulls.ui.detail.state")
local help = require("atlas.ui.popups.help")
local keymaps = require("atlas.core.keymaps")
local notify = require("atlas.core.notify")
local inline_edit = require("atlas.ui.inline_edit")
local presentation = require("atlas.pulls.ui.presentation")
local issue_presentation = require("atlas.issues.ui.presentation")
local providers = require("atlas.providers")
local request_scope = require("atlas.core.requests")
local markdown_lines = require("atlas.ui.components.markdown_lines")
local ui_utils = require("atlas.ui.utils")
local closing_refs = require("atlas.pulls.ui.detail.closing_refs")

---@return string|string[]|nil
local function edit_description_keys()
	local provider = detail.provider
	local capability = provider and provider.capabilities.actions
	local supported = false
	for _, action in ipairs(capability and capability.items or {}) do
		if action.id == "edit_description" then
			supported = true
			break
		end
	end
	if not supported then
		return nil
	end
	return keymaps.resolve("ui.edit_description")
end

local PADDING_X = 1
local PADDING = string.rep(" ", PADDING_X)

-- Closing-issue cards' issues, keyed "<project>#<iid>": the Issue, "loading",
-- or an error string. Filled lazily the first time a card is rendered.
---@type table<string, Issue|string>
local cards = {}
local requests = request_scope.new()
---@type fun()|nil
local refresh_view = nil

---@param pr PullRequest
---@param ref AtlasClosingRef
---@return string
local function card_key(pr, ref)
	return string.format("%s#%d", ref.project or tostring(pr.repo_full_name or ""), ref.iid)
end

--- Fetches the issues behind `keys` in one request (through the issues
--- provider's own `fetch_by_refs`), re-rendering once they're in.
---@param pr PullRequest
---@param keys string[]
local function load_cards(pr, keys)
	local provider = providers.load(pr.provider or "gitlab", "issues")
	local core = provider and provider.capabilities.core
	if core == nil or core.fetch_by_refs == nil then
		for _, key in ipairs(keys) do
			cards[key] = "unavailable"
		end
		return
	end
	local refs = {}
	for _, key in ipairs(keys) do
		table.insert(refs, { key = key })
	end
	requests.run(function(done)
		return core.fetch_by_refs(refs, {}, done)
	end, function(issues, err)
		local found = {}
		for _, issue in ipairs(issues or {}) do
			found[issue.key] = issue
		end
		for _, key in ipairs(keys) do
			cards[key] = found[key] or tostring(err or "not found")
		end
		if refresh_view then
			refresh_view()
		end
	end)
end

---@param issue Issue
---@return IssueLabel|nil
local function wf_label(issue)
	for _, label in ipairs(issue.labels or {}) do
		if tostring(label.name or ""):match("^WF:") then
			return label
		end
	end
	return nil
end

---@param label IssueLabel
---@param width integer
---@return string chip
---@return table[] spans Relative to `chip`.
local function label_chip(label, width)
	local provider_detail = detail.provider and detail.provider.capabilities.ui and detail.provider.capabilities.ui.detail
	local hl = provider_detail and provider_detail.label_chip_hl and provider_detail.label_chip_hl(label.color)
		or "AtlasChipActive"
	local cap_hl = provider_detail and provider_detail.label_cap_hl and provider_detail.label_cap_hl(label.color) or hl
	local chip_lines, chip_spans = utils.render_chips(
		{ { label = tostring(label.name or ""), hl = hl, cap_hl = cap_hl } },
		{ width = width, padding_x = 0, rounded = true }
	)
	return chip_lines[1] or "", chip_spans
end

--- One closing-issue card line: state dot, "#n", title, WF label chip
--- (DESIGN-merge-request-view.md §6), on a subtle background.
---@param pr PullRequest
---@param ref AtlasClosingRef
---@param width integer
---@param lines string[]
---@param spans table[]
---@param line_map table<integer, table>
local function render_card(pr, ref, width, lines, spans, line_map)
	local key = card_key(pr, ref)
	local issue = cards[key]
	local row = #lines
	local line = PADDING .. " "
	local row_spans = {}
	---@param text string
	---@param hl string|nil
	local function add(text, hl)
		if hl then
			table.insert(row_spans, { line = row, start_col = #line, end_col = #line + #text, hl_group = hl })
		end
		line = line .. text
	end

	local dot_hl = "AtlasTextMuted"
	if type(issue) == "table" then
		dot_hl = issue_presentation.is_open(issue) and "AtlasGreen" or "AtlasPurple"
	end
	add("●", dot_hl)
	add(" ")
	add((ref.project and (ref.project .. "#") or "#") .. ref.iid, "AtlasAccent")
	add("  ")
	if type(issue) == "table" then
		local label = wf_label(issue)
		local chip, chip_spans = "", {}
		if label then
			chip, chip_spans = label_chip(label, width)
		end
		local room = width - ui_utils.text_width(line) - (chip ~= "" and (ui_utils.text_width(chip) + 2) or 0) - 1
		local title = tostring(issue.title or "")
		if ui_utils.text_width(title) > room then
			title = utils.truncate(title, math.max(1, room))
		end
		add(title, "AtlasTextBright")
		if chip ~= "" then
			add("  ")
			local offset = #line
			line = line .. chip
			for _, s in ipairs(chip_spans) do
				table.insert(
					row_spans,
					{ line = row, start_col = offset + s.start_col, end_col = offset + s.end_col, hl_group = s.hl_group }
				)
			end
		end
	elseif issue == "loading" then
		add(spinner.with_text("Loading..."), "AtlasTextMuted")
	else
		add(ref.keyword, "AtlasTextMuted")
	end
	line = line .. string.rep(" ", math.max(0, width - 1 - ui_utils.text_width(line)))
	table.insert(lines, line)
	-- Card background first, so the text highlights layer on top of it.
	table.insert(spans, { line = row, start_col = PADDING_X, end_col = #line, hl_group = "AtlasBgHighlight" })
	vim.list_extend(spans, row_spans)
	line_map[#lines] = { kind = "issue_card", key = key, issue = type(issue) == "table" and issue or nil }
end

---@param text string
---@param width integer
---@param lines string[]
---@param spans table[]
local function render_markdown(text, width, lines, spans)
	local rendered_lines, rendered_spans = markdown_lines.render(text, { width = width - PADDING_X - 1 })
	local base = #lines
	for _, line in ipairs(rendered_lines) do
		table.insert(lines, PADDING .. line)
	end
	for _, span in ipairs(rendered_spans) do
		if span.line_hl_group ~= nil then
			table.insert(spans, { line = base + span.line, line_hl_group = span.line_hl_group })
		else
			table.insert(spans, {
				line = base + span.line,
				start_col = span.start_col + PADDING_X,
				end_col = span.end_col + PADDING_X,
				hl_group = span.hl_group,
			})
		end
	end
end

---@param pr PullRequest
---@param lines string[]
---@param spans table[]
local function render_empty(pr, lines, spans)
	local text = "No description."
	local line = PADDING .. text
	local row = #lines
	table.insert(spans, { line = row, start_col = PADDING_X, end_col = #line, hl_group = "AtlasTextMutedItalic" })
	local keys = edit_description_keys()
	if keys and presentation.is_open_or_draft(pr) then
		local key = type(keys) == "table" and keys[1] or keys
		local key_col = #line + 2
		line = line .. "  " .. key .. " add one"
		table.insert(spans, { line = row, start_col = key_col, end_col = key_col + #key, hl_group = "AtlasKeyHint" })
		table.insert(spans, { line = row, start_col = key_col + #key, end_col = #line, hl_group = "AtlasTextMuted" })
	end
	table.insert(lines, line)
end

--- The description as markdown (same renderer as the issue view), with each
--- "Closes #n"/"Fixes #n" line replaced by issue cards.
---@param pr PullRequest
---@param details PullRequestDetails
---@param width integer
---@param lines string[]
---@param spans table[]
---@param line_map table<integer, table>
local function render_description(pr, details, width, lines, spans, line_map)
	local description = tostring(details.description or "")
	if vim.trim(description) == "" then
		render_empty(pr, lines, spans)
		return
	end

	local refs_by_line = {}
	for _, ref in ipairs(closing_refs.parse(description)) do
		refs_by_line[ref.line] = refs_by_line[ref.line] or {}
		table.insert(refs_by_line[ref.line], ref)
	end

	local missing = {}
	local chunk = {}
	local in_fence = false
	local function flush()
		if #chunk > 0 then
			render_markdown(table.concat(chunk, "\n"), width, lines, spans)
			chunk = {}
		end
	end
	local lnum = 0
	for source in (description .. "\n"):gmatch("([^\n]*)\n") do
		lnum = lnum + 1
		if source:match("^%s*```") or source:match("^%s*~~~") then
			in_fence = not in_fence
		end
		local refs = not in_fence and refs_by_line[lnum] or nil
		if refs then
			flush()
			for _, ref in ipairs(refs) do
				local key = card_key(pr, ref)
				if cards[key] == nil then
					cards[key] = "loading"
					table.insert(missing, key)
				end
				render_card(pr, ref, width, lines, spans, line_map)
			end
		else
			table.insert(chunk, source)
		end
	end
	flush()

	if #missing > 0 then
		-- Not from inside a render: the fetch may answer synchronously (cache).
		vim.schedule(function()
			if detail.current_pr == pr then
				load_cards(pr, missing)
			end
		end)
	end
end

---@param pr PullRequest
---@param details PullRequestDetails|nil
---@param width integer
---@return string[], table[], table<integer, table>|nil
function M.render(pr, details, width)
	local lines = { "" }
	local spans = {}
	local line_map = {}

	if details then
		render_description(pr, details, width, lines, spans, line_map)
	elseif detail.details_loading then
		utils.push(lines, spans, spinner.with_text("Loading description..."), "AtlasTextMuted", PADDING_X)
	else
		utils.push(lines, spans, "Pull request details unavailable.", "AtlasTextMuted", PADDING_X)
	end

	return lines, spans, line_map
end

---@param _lnum integer
---@param entry table
---@return boolean
function M.is_selectable_line(_lnum, entry)
	return entry.kind == "issue_card"
end

--- `⏎` on an issue card opens that issue's detail view.
---@param pr PullRequest
---@param entry table
---@return boolean
function M.on_enter(pr, entry)
	if entry.kind ~= "issue_card" then
		return false
	end
	local provider = providers.load(pr.provider or "gitlab", "issues")
	if provider == nil then
		notify.error("Issues provider unavailable")
		return true
	end
	if entry.issue then
		require("atlas.issues.ui.detail").open(entry.issue, { provider = provider })
	else
		require("atlas.issues.ui.detail").open_ref({ key = entry.key }, { provider = provider })
	end
	return true
end

---@param _pr PullRequest
---@param refresh fun()
function M.on_select(_pr, refresh)
	refresh_view = refresh
end

function M.reset()
	requests.cancel()
	requests = request_scope.new()
	cards = {}
	refresh_view = nil
end

---@param buf integer
---@param refresh fun()|nil
local function register_edit_keymap(buf, refresh)
	local keys = edit_description_keys()
	if keys == nil then
		return
	end

	help.register("Detail", {
		{
			key = #keys == 1 and keys[1] or keys,
			desc = "Edit PR description",
			hint = false, -- no hint shown; the content box's editable border color is the only affordance
			opts = { nowait = true, silent = true },
			callback = function()
				local pr = detail.current_pr
				local details = detail.current_details
				local provider = detail.provider
				if pr == nil or details == nil or provider == nil or inline_edit.is_active(buf) then
					return
				end
				if not presentation.is_open_or_draft(pr) then
					notify.warn("PR is not open")
					return
				end

				local core = provider.capabilities.core

				local function begin_edit(current)
					require("atlas.pulls.ui.detail.keymaps").remove(buf)
					help.remove("Detail", { { key = #keys == 1 and keys[1] or keys } }, { buffer = buf })

					inline_edit.start({
						buf = buf,
						text = current,
						on_save = function(text, done)
							local updated = text or ""
							if updated == current then
								done(true)
								return
							end
							notify.loading("Updating description...")
							core.update_description(pr, updated, function(ok, err)
								if not ok then
									notify.error("Description update failed: " .. tostring(err or "Unknown error"))
									done(false, err)
									return
								end
								details.description = updated
								notify.success("Description updated", { timeout = 1200 })
								done(true)
							end)
						end,
						on_cancel = function()
							notify.info("Description unchanged", { timeout = 1200 })
						end,
						on_done = function()
							if buf and vim.api.nvim_buf_is_valid(buf) then
								require("atlas.pulls.ui.detail.keymaps").register(buf)
								register_edit_keymap(buf, refresh)
							end
							if refresh then
								refresh()
							end
						end,
					})
				end

				-- Always edit against the remote description so a stale panel
				-- does not silently revert someone else's concurrent edit.
				if core.fetch_description then
					notify.loading("Loading description...")
					core.fetch_description(pr, { force_refresh = true }, function(description, err)
						if detail.current_pr ~= pr then
							return
						end
						if err then
							notify.error("Failed to load description: " .. tostring(err))
							return
						end
						details.description = description or details.description
						begin_edit(tostring(details.description or ""))
					end)
				else
					begin_edit(tostring(details.description or ""))
				end
			end,
		},
	}, { index = 212, buffer = buf })
end

---@param buf integer
---@param refresh fun()|nil
function M.activate(buf, refresh)
	if not (buf and vim.api.nvim_buf_is_valid(buf)) then
		return
	end
	refresh_view = refresh
	register_edit_keymap(buf, refresh)
end

---@param buf integer
function M.deactivate(buf)
	if not (buf and vim.api.nvim_buf_is_valid(buf)) then
		return
	end
	local keys = edit_description_keys()
	if keys ~= nil then
		help.remove("Detail", { { key = #keys == 1 and keys[1] or keys } }, { buffer = buf })
	end
end

return M
