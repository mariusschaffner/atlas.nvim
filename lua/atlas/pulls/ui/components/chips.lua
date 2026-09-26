local M = {}

local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")
local spinner = require("atlas.ui.components.spinner")

local render_chips = utils.render_chips

---@param repo PullsRepoDetails
---@param opts { width: integer, padding_x?: integer, extra_chips?: PullsDetailChip[] }
---@return string[], table[]
function M.render_repo(repo, opts)
	local chips = {
		{
			label = string.format("%s %s", icons.pulls("file"), utils.human_size(repo.size)),
			hl = "AtlasTabInactive",
		},
		{
			label = string.format("%s %s", icons.pulls("branch"), tostring(repo.default_branch or "-")),
			hl = "AtlasGLPRRef",
		},
		repo.is_private == true and { label = "private", hl = "AtlasGLPRDraft" }
			or { label = "public", hl = "AtlasTextPositive" },
	}

	for _, chip in ipairs(opts.extra_chips or {}) do
		table.insert(chips, chip)
	end

	return render_chips(chips, opts)
end

---@param text string|nil
---@param opts { width: integer, padding_x?: integer }
---@return string[], table[]
function M.render_loading(text, opts)
	return render_chips({ { label = spinner.with_text(text or "Loading..."), hl = "AtlasTextMuted" } }, opts)
end

return M
