local M = {}

local presentation = require("atlas.pulls.ui.presentation")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")

local function add(rows, label, value, hl_group)
	if value == nil or value == "" then
		return
	end
	rows[#rows + 1] = { label, tostring(value), hl_group or "AtlasTextMuted" }
end

local function generic_rows(pr)
	local state = tostring(pr.state or "-")
	local author = presentation.user_handle(pr.author)
	local repo = tostring(pr.repo_full_name or "")
	local branch = tostring((pr.source or {}).branch or "?")
		.. " → "
		.. tostring((pr.destination or {}).branch or "?")
	return {
		{ "State", state, presentation.pr_state_hl(state) },
		{ "Author", author, presentation.author_hl(author) },
		{ "Repo", repo ~= "" and repo or "-", repo ~= "" and presentation.repo_hl(repo) or "AtlasTextMuted" },
		{ "Branch", branch, "AtlasTextMuted" },
		{ "Comments", tostring(pr.comments_count or 0), "AtlasTextMuted" },
		{ "Created", utils.relative_time(pr.created_on), "AtlasTextMuted" },
		{ "Updated", utils.relative_time(pr.updated_on), "AtlasTextMuted" },
	}
end

local function gitlab_rows(pr)
	---@cast pr GitLabPullRequest
	local rows = {}
	local merge_status = tostring(pr.detailed_merge_status or pr.merge_status or ""):lower()
	if merge_status ~= "" then
		local kind = "unknown"
		if merge_status == "mergeable" or merge_status == "can_be_merged" then
			kind = "successful"
		elseif
			merge_status == "conflict"
			or merge_status == "cannot_be_merged"
			or merge_status == "ci_must_pass"
			or merge_status == "discussions_not_resolved"
			or merge_status == "blocked_status"
			or merge_status == "merge_request_blocked"
			or merge_status == "need_rebase"
			or merge_status == "requested_changes"
			or merge_status == "status_checks_must_pass"
			or merge_status == "security_policy_violations"
			or merge_status == "policies_denied"
		then
			kind = "failed"
		elseif merge_status == "draft_status" or merge_status == "not_open" then
			kind = "stopped"
		else
			kind = "inprogress"
		end
		local value, hl_group = icons.pulls_status(kind)
		add(rows, "Merge", value, hl_group)
	end

	local reviewers = {}
	for _, reviewer in ipairs(pr.reviewers or {}) do
		local name = presentation.user_handle(reviewer)
		if name ~= "" then
			reviewers[#reviewers + 1] = "@" .. name
		end
	end
	add(rows, "Reviewers", table.concat(reviewers, ", "))
	return rows
end

local provider_rows = {
	gitlab = gitlab_rows,
}

local function render(pr, rows)
	local id = tostring(pr.id or "")
	local marker = pr.provider == "gitlab" and "!" or "#"

	local lines = { string.format(" %s%s: %s", marker, id, tostring(pr.title or "")), "" }
	---@type AtlasUIHighlight[]
	local highlights = {}
	if id ~= "" then
		table.insert(highlights, { line = 0, start_col = 2, end_col = 2 + #id, hl_group = "AtlasTextMuted" })
	end

	for _, row in ipairs(rows) do
		local line = #lines
		table.insert(lines, string.format(" %-10s %s", row[1] .. ":", row[2]))
		table.insert(highlights, { line = line, start_col = 1, end_col = 11, hl_group = "AtlasTextMuted" })
		table.insert(highlights, {
			line = line,
			start_col = 12,
			end_col = #lines[line + 1],
			hl_group = row[3],
		})
	end

	local width = 1
	for _, line in ipairs(lines) do
		width = math.max(width, vim.fn.strdisplaywidth(line))
	end
	lines[2] = " " .. ("━"):rep(math.max(1, width - 1))
	table.insert(highlights, { line = 1, start_col = 0, end_col = #lines[2], hl_group = "AtlasTextMuted" })

	return lines, highlights
end

---@param pr PullRequest
---@return string[], AtlasUIHighlight[]
function M.content(pr)
	local rows = generic_rows(pr)
	local extend = provider_rows[pr.provider]
	if extend then
		vim.list_extend(rows, extend(pr))
	end
	return render(pr, rows)
end

return M
