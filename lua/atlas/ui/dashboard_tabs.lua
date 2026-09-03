local M = {}

local navbar = require("atlas.ui.components.navbar")
local icons = require("atlas.ui.shared.icons")
local resolver = require("atlas.core.keymaps")

local ITEMS = { "issues", "pulls" }
local LABELS = { issues = "Issues", pulls = "Pulls" }

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
		table.insert(actions, {
			label = count > 0 and string.format("%s %d", bell, count) or bell,
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

---@param active_domain string|nil
---@param width integer
---@return string[], table[]
function M.render(active_domain, width)
	local items = {}
	for _, key in ipairs(ITEMS) do
		local icon = key == "issues" and icons.issues("issue") or icons.pulls("pr")
		table.insert(items, {
			label = LABELS[key],
			icon = icon,
			active = key == active_domain,
		})
	end

	local rendered = navbar.render({
		width = width,
		items = items,
		actions = build_actions(active_domain),
		active_hl = "AtlasChipActive",
		inactive_hl = "AtlasTabInactive",
	})

	local lines = { "" }
	vim.list_extend(lines, rendered.lines)
	table.insert(lines, "")

	local spans = {}
	for _, span in ipairs(rendered.highlights) do
		table.insert(spans, {
			line = span.line + 1,
			start_col = span.start_col,
			end_col = span.end_col,
			hl_group = span.hl_group,
		})
	end

	local divider = string.rep("━", math.max(1, width))
	table.insert(lines, divider)
	table.insert(spans, { line = #lines - 1, start_col = 0, end_col = #divider, hl_group = "AtlasBorder" })

	return lines, spans
end

return M
