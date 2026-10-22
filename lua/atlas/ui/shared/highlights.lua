local M = {}

local dynamic_palette = {
	"#91d7e3",
	"#7dc4e4",
	"#8bd5ca",
	"#eed49f",
	"#f5a97f",
	"#f5bde6",
	"#c6a0f6",
	"#8aadf4",
	"#b7bdf8",
	"#f0c6c6",
	"#f4dbd6",
}

---@param text string
---@return integer
local function hash_string(text)
	local h = 0
	for i = 1, #text do
		h = (h * 31 + string.byte(text, i)) % 2147483647
	end
	return h
end

---@param identifier string
---@return integer
local function palette_index(identifier)
	return (hash_string(identifier) % #dynamic_palette) + 1
end

---@type table<string, table>
local groups = {
	AtlasTabInactive = { link = "CursorLine" },
	AtlasColumnHeader = { fg = "#7f849c", bold = true },
	AtlasSectionHeader = { fg = "#7f849c", bold = true, underline = true },
	AtlasBorder = { fg = "#585b70" },

	AtlasTextMuted = { fg = "#7f849c" },
	AtlasTextMutedItalic = { fg = "#7f849c", italic = true },
	AtlasTextMutedStrikethrough = { fg = "#7f849c", strikethrough = true },
	AtlasTextPositive = { fg = "#a6da95", bold = true },
	AtlasTextNote = { fg = "#f5bde6", bold = true },
	AtlasTextWarning = { fg = "#f9e2af", bold = true },

	AtlasLogInfo = { fg = "#89b4fa", bold = true },
	AtlasLogWarn = { fg = "#f9e2af", bold = true },
	AtlasLogError = { fg = "#f38ba8", bold = true },

	AtlasFooterBackground = { bg = "#1f1f28" },
	AtlasFooterText = { fg = "#7f849c", bg = "#1f1f28" },
	AtlasFooterInfo = { fg = "#89b4fa", bg = "#1f1f28", bold = true },
	AtlasFooterNote = { fg = "#f5bde6", bg = "#1f1f28", bold = true },
	AtlasFooterWarning = { fg = "#f9e2af", bg = "#1f1f28", bold = true },
	AtlasFooterError = { fg = "#f38ba8", bg = "#1f1f28", bold = true },
	AtlasFooterSuccess = { fg = "#a6da95", bg = "#1f1f28", bold = true },

	AtlasChipActive = { fg = "#1e1e2e", bg = "#89b4fa", bold = true },

	AtlasFilterActive = { fg = "#89b4fa", bold = true, underline = true },
	AtlasFilterBarBackground = { bg = "#313244" },
	AtlasFilterBarBorder = { fg = "#89b4fa" },

	AtlasFieldBoxBorder = { fg = "#585b70" },
	AtlasFieldBoxBorderEditable = { fg = "#89b4fa" },
	AtlasFieldBoxBorderEditing = { fg = "#f5a97f", bold = true },
	AtlasFieldBoxBorderRequired = { fg = "#ff3b30", bold = true },

	AtlasDetailTabActive = { fg = "#c8c093", bold = true },

	-- Generic detail-view theme tokens (DESIGN-detail-view.md §8): named so
	-- view code never hard-codes hex. Reuse AtlasTextMuted/AtlasTextPositive/
	-- AtlasTextWarning/AtlasBorder above for dim/green/yellow-ish/border where
	-- those already match; the tokens below cover what has no existing
	-- equivalent. Not GitLab-specific, so they live here rather than in a
	-- provider's highlights file.
	AtlasAccent = { fg = "#7aa2f7", bold = true },
	AtlasTextBright = { fg = "#e6eaff", bold = true },
	AtlasTextDone = { fg = "#a9b1d6" },
	AtlasOrange = { fg = "#ff9e64" },
	AtlasPurple = { fg = "#bb9af7", bold = true },
	AtlasCyan = { fg = "#7dcfff", bold = true },
	AtlasKeyHint = { fg = "#e0af68" },
	AtlasProgressFill = { fg = "#9ece6a" },
	AtlasProgressEmpty = { fg = "#3b4261" },
	AtlasTextBrightRegular = { fg = "#e6eaff" },

	-- Issues detail view's own in-buffer tab bar (borderless layout) -- a
	-- separate group from `AtlasDetailTabActive` above (shared by every other
	-- split-kind's native-title tab bar) so its accent-colored underline
	-- doesn't bleed into pulls/milestone/pipelines/create's tabs.
	AtlasDetailTabActiveUnderline = { fg = "#e6eaff", sp = "#7aa2f7", bold = true, underline = true },
}

function M.setup()
	for name, opts in pairs(groups) do
		vim.api.nvim_set_hl(0, name, opts)
	end

	for idx, color in ipairs(dynamic_palette) do
		local fg_name = string.format("AtlasDynColor%02d", idx)
		local bg_name = string.format("AtlasDynBgColor%02d", idx)
		vim.api.nvim_set_hl(0, fg_name, { fg = color })
		vim.api.nvim_set_hl(0, bg_name, { fg = "#1e1e2e", bg = color })
	end
end

---Returns a stable dynamic highlight group for an identifier.
---Same identifier always maps to the same palette color.
---Groups are shared by color index (e.g. AtlasDynColor03), not by namespace.
---@param identifier string|nil
---@return string|nil
function M.dynamic_for(identifier)
	if identifier == nil or identifier == "" then
		return nil
	end

	local idx = palette_index(identifier)
	return string.format("AtlasDynColor%02d", idx)
end

---Returns a stable dynamic background highlight group for an identifier.
---Same identifier always maps to the same palette color.
---@param identifier string|nil
---@return string|nil
function M.dynamic_for_bg(identifier)
	if identifier == nil or identifier == "" then
		return nil
	end

	local idx = palette_index(identifier)
	return string.format("AtlasDynBgColor%02d", idx)
end

--- Defines (and returns the name of) a highlight group for a GitLab label
--- color hex string, choosing a readable foreground by luminance. Returns
--- fallback_hl unchanged for an invalid/missing hex.
---@param hex string|nil
---@param group_prefix string e.g. "AtlasGLLabel_"
---@param fallback_hl string
---@return string
function M.label_hl(hex, group_prefix, fallback_hl)
	local clean = tostring(hex or ""):lower():gsub("[^0-9a-f]", "")
	if #clean ~= 6 then
		return fallback_hl
	end
	local name = group_prefix .. clean
	local r = tonumber(clean:sub(1, 2), 16) or 0
	local g = tonumber(clean:sub(3, 4), 16) or 0
	local b = tonumber(clean:sub(5, 6), 16) or 0
	local lum = (0.299 * r + 0.587 * g + 0.114 * b) / 255
	local fg = lum > 0.6 and "#1e1e2e" or "#ffffff"
	vim.api.nvim_set_hl(0, name, { fg = fg, bg = "#" .. clean, bold = true })
	return name
end

--- Same as label_hl but colors only the foreground (no background fill).
---@param hex string|nil
---@param group_prefix string e.g. "AtlasGLLabelFg_"
---@param fallback_hl string
---@return string
function M.label_fg_hl(hex, group_prefix, fallback_hl)
	local clean = tostring(hex or ""):lower():gsub("[^0-9a-f]", "")
	if #clean ~= 6 then
		return fallback_hl
	end
	local name = group_prefix .. clean
	vim.api.nvim_set_hl(0, name, { fg = "#" .. clean, bold = true })
	return name
end

return M
