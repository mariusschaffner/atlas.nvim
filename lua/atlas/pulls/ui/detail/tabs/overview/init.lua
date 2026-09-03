local M = {}

local utils = require("atlas.ui.shared.utils")
local spinner = require("atlas.ui.components.spinner")
local detail = require("atlas.pulls.ui.detail.state")

local PADDING_X = 1
local PADDING = string.rep(" ", PADDING_X)

---@param details PullRequestDetails
---@param width integer
---@param lines string[]
---@param spans table[]
local function render_description(details, width, lines, spans)
	utils.push(lines, spans, "Description", "AtlasColumnHeader", PADDING_X)

	local desc_text = utils.strip_markup(details.description)
	if desc_text == "" then
		utils.push(lines, spans, "No description provided.", "AtlasTextMuted", PADDING_X)
		table.insert(lines, "")
		return
	end

	local desc_lines = utils.sanitize_lines(desc_text)
	while #desc_lines > 0 and vim.trim(desc_lines[#desc_lines]) == "" do
		table.remove(desc_lines)
	end

	for _, line in ipairs(desc_lines) do
		table.insert(lines, PADDING .. line)
	end

	table.insert(lines, "")
end

---@param _pr PullRequest
---@param details PullRequestDetails|nil
---@param width integer
---@return string[], table[], table<integer, table>|nil
function M.render(_pr, details, width)
	local lines = {}
	local spans = {}

	if details then
		render_description(details, width, lines, spans)
	elseif detail.details_loading then
		utils.push(lines, spans, spinner.with_text("Loading description..."), "AtlasTextMuted", PADDING_X)
	else
		utils.push(lines, spans, "Pull request details unavailable.", "AtlasTextMuted", PADDING_X)
	end

	return lines, spans, {}
end

---@param buf integer
function M.activate(buf)
	if not (buf and vim.api.nvim_buf_is_valid(buf)) then
		return
	end
	vim.api.nvim_set_option_value("filetype", "markdown", { buf = buf })
	vim.api.nvim_set_option_value("syntax", "markdown", { buf = buf })
end

---@param buf integer
function M.deactivate(buf)
	if not (buf and vim.api.nvim_buf_is_valid(buf)) then
		return
	end
	vim.api.nvim_set_option_value("filetype", "atlas.detail", { buf = buf })
	vim.api.nvim_set_option_value("syntax", "OFF", { buf = buf })
	pcall(vim.treesitter.stop, buf)
end

return M
