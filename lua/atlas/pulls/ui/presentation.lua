local M = {}

local highlights = require("atlas.ui.shared.highlights")

---@param name string|nil
---@return string
function M.author_hl(name)
	if name == nil then
		return "AtlasTextMutedItalic"
	end
	local lower = vim.trim(name):lower()
	if lower == "" or lower == "unknown" or lower == "none" then
		return "AtlasTextMutedItalic"
	end
	return highlights.dynamic_for(lower) or "AtlasTextMuted"
end

---@param user { name: string?, nickname: string?, username: string? }|nil
---@return string
function M.user_handle(user)
	if user == nil then
		return "Unknown"
	end
	if user.nickname and user.nickname ~= "" then
		return user.nickname
	end
	if user.username and user.username ~= "" then
		return user.username
	end
	return (user.name and user.name ~= "") and user.name or "Unknown"
end

---@param repo string|nil
---@return string
function M.repo_hl(repo)
	if repo == nil then
		return "AtlasTextMutedItalic"
	end
	local lower = vim.trim(repo):lower()
	if lower == "" or lower == "none" then
		return "AtlasTextMutedItalic"
	end
	return highlights.dynamic_for(lower) or "AtlasTextMuted"
end

---@param pr_state string|nil
---@return string
function M.pr_state_hl(pr_state)
	local lower = tostring(pr_state or ""):lower()
	if lower == "open" then
		return "AtlasPROpenChip"
	end
	if lower == "merged" then
		return "AtlasPRMergedChip"
	end
	if lower == "declined" then
		return "AtlasPRDeclinedChip"
	end
	if lower == "draft" then
		return "AtlasPRDraftChip"
	end
	return "AtlasTextMuted"
end

---@param pr_state string|nil
---@return string
function M.pr_state_label(pr_state)
	local lower = tostring(pr_state or ""):lower()
	if lower == "open" then
		return "Open"
	end
	if lower == "merged" then
		return "Merged"
	end
	if lower == "declined" then
		return "Declined"
	end
	if lower == "draft" then
		return "Draft"
	end
	return pr_state and tostring(pr_state) or ""
end

--- Same as pr_state_hl but foreground-only, no chip background fill — used
--- for the title field's border color rather than as a standalone pill.
--- Merged is red here (same as a closed issue), not the blue used for the
--- merged chip/icon elsewhere.
---@param pr_state string|nil
---@return string
function M.pr_state_fg_hl(pr_state)
	local lower = tostring(pr_state or ""):lower()
	if lower == "open" then
		return "AtlasPROpen"
	end
	if lower == "merged" then
		return "AtlasPRMergedBorder"
	end
	if lower == "declined" then
		return "AtlasPRDeclined"
	end
	if lower == "draft" then
		return "AtlasPRDraft"
	end
	return "AtlasTextMuted"
end

--- Whether a PR is still actionable (open or draft) -- the shared gate for
--- every header field that stops being editable once a PR is merged or
--- declined (title, reviewers, assignees, delete-source-branch). Labels are
--- deliberately excluded from this everywhere it's used -- editing labels
--- stays available regardless of PR state.
---@param pr PullRequest|nil
---@return boolean
function M.is_open_or_draft(pr)
	local state = pr and tostring(pr.state or ""):lower() or ""
	return state == "open" or state == "draft"
end

---@param pr PullRequest
---@return PullsRepo
function M.repo(pr)
	return {
		id = pr.repo_full_name,
		name = pr.repo_full_name,
		full_name = pr.repo_full_name,
		owner = pr.workspace,
		workspace = pr.workspace,
		repo_name = pr.repo,
	}
end

return M
