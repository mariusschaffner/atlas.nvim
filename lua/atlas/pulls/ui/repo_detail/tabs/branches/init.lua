local utils = require("atlas.ui.shared.utils")
local icons = require("atlas.ui.shared.icons")
local notify = require("atlas.core.notify")
local detail = require("atlas.pulls.ui.repo_detail.state")
local core_utils = require("atlas.core.utils")
local keymaps = require("atlas.pulls.ui.repo_detail.tabs.branches.keymaps")

local M = require("atlas.pulls.ui.repo_detail.tabs.ref_list").create({
	singular = "branch",
	plural = "branches",
	keymaps = keymaps,
	---@param branch table
	---@param repo PullsRepoDetails
	---@return AtlasThreadV2Item
	to_item = function(branch, repo)
		local msg = branch.message and tostring(branch.message:match("^[^\n\r]*") or "") or nil
		if msg == "" then
			msg = nil
		end
		local author = branch.author and tostring(branch.author) or nil
		if author == "" then
			author = nil
		end
		return {
			icon = icons.pulls("branch"),
			author = tostring(branch.name or ""),
			additional = author,
			right_text = branch.date and utils.relative_time_text(branch.date) or nil,
			content = msg,
			obj = { repo = repo, branch = branch },
		}
	end,
	fetch = function(repository, repo_details, fetch_opts, done)
		return repository.fetch_branches(repo_details, fetch_opts, done)
	end,
})

---@return table|nil
local function cursor_entry()
	local win = detail.win
	if win == nil or not vim.api.nvim_win_is_valid(win) then
		return nil
	end
	local lnum = vim.api.nvim_win_get_cursor(win)[1]
	return detail.line_map[lnum]
end

---@param repo PullsRepo|nil
---@return boolean
local function is_current_repo(repo)
	local current = detail.current_repo
	return current ~= nil and tostring(current.id or "") == tostring(repo and repo.id or "")
end

---@param refresh fun()
function M.delete_current_branch(refresh)
	local provider = detail.provider
	local repository = provider and provider.capabilities.repository
	if repository == nil or not repository.delete_branch then
		notify.error("Branch deletion is not supported by this provider")
		return
	end

	local entry = cursor_entry()
	local branch = entry and entry.item and entry.item.obj and entry.item.obj.branch
	local repo = M.state.repo
	if repo == nil or branch == nil then
		notify.warn("No branch selected")
		return
	end

	local branch_name = tostring(branch.name or "")
	if branch_name == "" then
		notify.warn("Branch name is missing")
		return
	end
	if branch_name == tostring(repo.default_branch or "") then
		notify.warn("Refusing to delete the default branch")
		return
	end

	local current_repo = detail.current_repo
	vim.ui.input({ prompt = string.format("Delete branch '%s'? [y/N]: ", branch_name) }, function(input)
		local confirmed = input and vim.trim(input):lower()
		if (confirmed ~= "y" and confirmed ~= "yes") or not is_current_repo(current_repo) then
			return
		end

		notify.loading(string.format("Deleting branch %s...", branch_name))
		M.stop_requests()
		M.state.requests.run(function(done)
			return repository.delete_branch(repo, branch, done)
		end, function(ok, err)
			if not is_current_repo(current_repo) then
				return
			end
			if err ~= nil then
				notify.error("Delete branch failed: " .. tostring(err))
				return
			end

			if ok then
				local branches = core_utils.as_table(M.state.entries) or {}
				local entries = core_utils.as_table(branches.entries) or {}
				for i, existing in ipairs(entries) do
					if tostring(existing.name or "") == branch_name then
						table.remove(entries, i)
						break
					end
				end
				M.state.entries = { entries = entries }
			end

			notify.success(string.format("Deleted branch %s", branch_name), { timeout = 1200 })
			refresh()
		end)
	end)
end

return M
