local M = {}

local icons = require("atlas.ui.shared.icons")

local function columns(conversation, before_reviewer, after_reviewer)
	local function build(title_key, compact)
		local result = {}
		if compact then
			table.insert(result, {
				key = "pr_icon",
				name = "",
				min_width = 1,
				can_grow = false,
				header_hl = "AtlasColumnHeader",
			})
		end
		table.insert(result, { key = title_key, name = "Title", min_width = 42, header_hl = "AtlasColumnHeader" })
		table.insert(result, {
			key = "conversation",
			name = string.format("%s Comments", conversation),
			min_width = 2,
			can_grow = false,
			header_hl = "AtlasColumnHeader",
		})
		vim.list_extend(result, before_reviewer)
		table.insert(result, {
			key = "reviewer",
			name = string.format("%s Reviewer", icons.pulls("review")),
			min_width = 3,
			can_grow = false,
			header_hl = "AtlasColumnHeader",
		})
		vim.list_extend(result, after_reviewer)
		table.insert(result, {
			key = "created",
			name = string.format("%s Created", icons.general("created")),
			can_grow = false,
			header_hl = "AtlasColumnHeader",
		})
		table.insert(result, {
			key = "updated",
			name = string.format("%s Updated", icons.general("updated")),
			can_grow = false,
			header_hl = "AtlasColumnHeader",
		})
		return result
	end

	return {
		compact = build("repo_pr", true),
		list = build("name", false),
	}
end

local function diff_stats(additions, deletions)
	if additions + deletions == 0 then
		return "", {}
	end
	local added = "+" .. tostring(additions)
	local removed = "-" .. tostring(deletions)
	local text = added .. " " .. removed
	return text,
		{
			{ start_col = 0, end_col = #added, hl_group = "AtlasTextPositive" },
			{ start_col = #added + 1, end_col = #text, hl_group = "AtlasLogError" },
		}
end

local function gitlab()
	local pending_statuses = {
		checking = true,
		unchecked = true,
		preparing = true,
		ci_still_running = true,
		external_status_checks = true,
		approvals_syncing = true,
		commits_status = true,
	}
	local check_icon, check_hl = icons.pulls_status("successful")
	local cross_icon, cross_hl = icons.pulls_status("failed")
	local pending_icon, pending_hl = icons.pulls_status("inprogress")

	local mergeable_column = {
		key = "mergeable",
		name = string.format("%s Can Merge", check_icon),
		min_width = 1,
		can_grow = false,
		header_hl = "AtlasColumnHeader",
	}

	return {
		reference = "!",
		columns = columns(icons.general("comment"), { mergeable_column }, {}),
		values = function(pr)
			---@cast pr GitLabPullRequest
			local status = tostring(pr.detailed_merge_status or pr.merge_status or ""):lower()
			if status == "" then
				return { mergeable = "", mergeable_hl = "AtlasTextMuted" }
			end
			if status == "mergeable" then
				return { mergeable = check_icon, mergeable_hl = check_hl }
			end
			if pending_statuses[status] then
				return { mergeable = pending_icon, mergeable_hl = pending_hl }
			end
			return { mergeable = cross_icon, mergeable_hl = cross_hl }
		end,
		highlight = function(row, col, ctx)
			if col.key == "mergeable" then
				local empty = row.kind == "meta" or row.kind == "repo"
				local hl = empty and "" or (row.mergeable_hl or "AtlasTextMuted")
				return { { start_col = 0, end_col = #ctx.padded, hl_group = hl } }
			end
		end,
	}
end

local function default()
	return {
		reference = "#",
		columns = columns(icons.general("conversation"), {}, {}),
		values = function()
			return {}
		end,
		highlight = function() end,
	}
end

local displays = {
	gitlab = gitlab(),
}
local fallback = default()

---@param provider string|nil
---@return table
function M.get(provider)
	return displays[provider] or fallback
end

return M
