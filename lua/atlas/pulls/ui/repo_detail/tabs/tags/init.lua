local utils = require("atlas.ui.shared.utils")
local icons = require("atlas.ui.shared.icons")

local M = require("atlas.pulls.ui.repo_detail.tabs.ref_list").create({
	singular = "tag",
	plural = "tags",
	---@param tag table
	---@param repo PullsRepoDetails
	---@return AtlasThreadV2Item
	to_item = function(tag, repo)
		local first_line = tag.message and tostring(tag.message:match("^[^\n\r]*") or "") or nil
		if first_line == "" then
			first_line = nil
		end
		local author_str = tag.author and tostring(tag.author) or nil
		if author_str == "" then
			author_str = nil
		end
		local content = nil
		if author_str and first_line then
			content = author_str .. "  " .. first_line
		elseif first_line then
			content = first_line
		elseif author_str then
			content = author_str
		end
		return {
			icon = icons.pulls("tag"),
			author = tostring(tag.name or ""),
			additional = tag.hash and tostring(tag.hash):sub(1, 8) or nil,
			right_text = tag.date and utils.relative_time_text(tag.date) or nil,
			content = content,
			obj = { repo = repo, tag = tag },
		}
	end,
	fetch = function(repository, repo_details, fetch_opts, done)
		return repository.fetch_tags(repo_details, fetch_opts, done)
	end,
})

return M
