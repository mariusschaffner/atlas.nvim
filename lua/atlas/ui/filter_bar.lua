-- Unified filter bar: replaces the old "Issues | Pulls" domain tab strip
-- (dashboard_tabs.lua) and the per-domain filter row that used to be
-- duplicated in issues/pulls renderer.lua. One bordered box, always
-- visible, showing the active domain's filter_text (which always includes
-- a live-editable `view:<domain>` token) plus the notification/refresh
-- hints in the remaining width.
local M = {}

local bordered_box = require("atlas.ui.components.bordered_box")
local icons = require("atlas.ui.shared.icons")
local resolver = require("atlas.core.keymaps")

local STATE_MODULES = {
	issues = "atlas.issues.state",
	pulls = "atlas.pulls.state",
}

---@param domain string|nil
---@return table|nil
local function active_provider(domain)
	local mod = domain and STATE_MODULES[domain]
	return mod and require(mod).provider or nil
end

---@param domain string|nil
---@return table[]
local function build_actions(domain)
	local actions = {}
	local provider = active_provider(domain)
	if provider and provider.capabilities and provider.capabilities.notifications then
		local notif_state = require("atlas.ui.notifications.state")
		local count = notif_state.unread_count or 0
		local bell, bell_hl = icons.general(count > 0 and "bell_unread" or "bell")
		local label = count > 0 and string.format("%s %d", bell, count) or bell
		local notif_keys = resolver.resolve("ui.notifications.open")
		if notif_keys and notif_keys[1] then
			label = string.format("%s (%s)", label, notif_keys[1])
		end
		table.insert(actions, {
			label = label,
			hl_group = bell_hl,
		})
	end

	local keys = resolver.resolve("ui.refresh_view")
	local refresh_key = keys and keys[1]
	if refresh_key then
		if #actions > 0 then
			table.insert(actions, { label = "|", hl_group = "AtlasTextMuted" })
		end
		table.insert(actions, { label = string.format("Refresh (%s)", refresh_key), hl_group = "AtlasTextMuted" })
	end

	return actions
end

---@param actions table[]
---@return { lines: string[], highlights: table[] }
local function join_actions(actions)
	local line = ""
	local highlights = {}
	local byte_col = 0
	for i, action in ipairs(actions) do
		table.insert(highlights, { start_col = byte_col, end_col = byte_col + #action.label, hl_group = action.hl_group })
		line = line .. action.label
		byte_col = byte_col + #action.label
		if i < #actions then
			line = line .. "  "
			byte_col = byte_col + 2
		end
	end
	return { lines = { line }, highlights = highlights }
end

---@param domain "issues"|"pulls"|nil
---@param width integer
---@return string[] lines
---@return table[] highlights
function M.render(domain, width)
	local mod = domain and STATE_MODULES[domain]
	local filter_text = (mod and require(mod).filter_text) or ""
	local search_icon = icons.general("search")
	local content = string.format("%s %s", search_icon, filter_text)

	return bordered_box.render({
		width = width,
		title = "Filter",
		content_lines = { content },
		content_highlights = { { line = 0, start_col = 0, end_col = #content, hl_group = "AtlasTextMuted" } },
		content_background_hl = "AtlasFilterBarBackground",
		right_content = join_actions(build_actions(domain)),
	})
end

return M
