local M = {}

local presentation = require("atlas.pulls.ui.presentation")
local pipeline_utils = require("atlas.pulls.pipelines")
local icons = require("atlas.ui.shared.icons")
local utils = require("atlas.ui.shared.utils")
local spinner = require("atlas.ui.components.spinner")

local render_chips = utils.render_chips

---@param pr PullRequest
---@param opts { width: integer, padding_x?: integer, extra_chips?: PullsDetailChip[], pipelines?: PullsPipeline[]|"loading"|string, loading?: boolean }
---@return string[], table[]
function M.render(pr, opts)
	local chips = {
		{ label = tostring(pr.state or "UNKNOWN"), hl = presentation.pr_state_hl(pr.state) },
	}

	for _, chip in ipairs(opts.extra_chips or {}) do
		table.insert(chips, chip)
	end

	if opts.loading or opts.pipelines == "loading" then
		table.insert(chips, { label = spinner.with_text("Loading..."), hl = "AtlasTextMuted" })
	elseif type(opts.pipelines) == "table" and #opts.pipelines > 0 then
		local status = pipeline_utils.aggregate_state(opts.pipelines):lower()
		if status ~= "unknown" then
			local icon, icon_hl = icons.pulls_status(status)
			table.insert(chips, {
				label = string.format("%s %s%s", icon, status:sub(1, 1):upper(), status:sub(2)),
				hl = icon_hl,
			})
		end
	end

	return render_chips(chips, opts)
end

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
