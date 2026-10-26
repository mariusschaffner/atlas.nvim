-- Keys of the pipeline detail view (DESIGN-pipeline-view.md §5). The shared
-- detail host keeps focus in the log float, so the graph and the log are two
-- key "modes" on the log buffer: graph mode maps stage/job navigation and the
-- job actions; log mode leaves j/k/h/l etc. to Neovim (scrolling) and maps
-- the key back to the graph. Pipeline-level keys work in both.
local M = {}

local help = require("atlas.ui.popups.help")
local resolver = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")

local GENERAL = "General"
local GRAPH = "Pipeline graph"
local LOG = "Job log"

local function detail()
	return require("atlas.pipelines.ui.detail")
end

---@param action_id string
---@param desc string
---@param callback fun()
---@return table|nil
local function item(action_id, desc, callback)
	return resolver.item(action_id, {
		desc = desc,
		hint = false,
		opts = { nowait = true, silent = true },
		callback = function()
			if not help.is_open() then
				callback()
			end
		end,
	})
end

local GENERAL_ACTIONS = {
	{
		"ui.help",
		"Toggle help",
		function(buf)
			help.toggle({ buffer = buf })
		end,
	},
	{ "ui.close", "Close pipeline", "close" },
	{ "pipelines.follow", "Follow the log", "follow" },
	{ "pipelines.fullscreen", "Toggle fullscreen log", "toggle_fullscreen" },
	{ "ui.toggle_fold", "Toggle log section", "toggle_fold" },
}

local GRAPH_ACTIONS = {
	{ "pipelines.previous_stage", "Previous stage", "previous_stage" },
	{ "pipelines.next_stage", "Next stage", "next_stage" },
	{ "ui.next_item", "Next job", "next_job" },
	{ "ui.previous_item", "Previous job", "previous_job" },
	{ "ui.select", "Show output (focus the log)", "focus_log" },
}

local LOG_ACTIONS = {
	{ "pipelines.focus_graph", "Back to the graph", "focus_graph" },
}

---@param actions table[]
---@param buf integer
---@return table[]
local function items_for(actions, buf)
	local items = {}
	for _, action in ipairs(actions) do
		local target = action[3]
		local callback = type(target) == "function" and function()
			target(buf)
		end or function()
			detail()[target]()
		end
		if action[1] == "ui.help" then
			-- Help toggles itself even while open.
			utils.insert_if(
				items,
				resolver.item(action[1], {
					desc = action[2],
					hint = false,
					opts = { nowait = true, silent = true },
					callback = callback,
				})
			)
		else
			utils.insert_if(items, item(action[1], action[2], callback))
		end
	end
	return items
end

---@param actions table[]
---@return table[]
local function removals(actions)
	local items = {}
	for _, action in ipairs(actions) do
		utils.insert_if(items, resolver.remove_item(action[1]))
	end
	return items
end

--- Maps the keys of `mode` ("graph"|"log") and unmaps the other mode's.
---@param buf integer
---@param mode "graph"|"log"
function M.set_mode(buf, mode)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	help.remove(GRAPH, removals(GRAPH_ACTIONS), { buffer = buf })
	help.remove(LOG, removals(LOG_ACTIONS), { buffer = buf })
	if mode == "graph" then
		help.register(GRAPH, items_for(GRAPH_ACTIONS, buf), { index = 310, buffer = buf })
	else
		help.register(LOG, items_for(LOG_ACTIONS, buf), { index = 310, buffer = buf })
	end
end

---@param buf integer
function M.register(buf)
	M.remove(buf)
	help.register(GENERAL, items_for(GENERAL_ACTIONS, buf), { index = 300, buffer = buf })
	M.set_mode(buf, "graph")
end

---@param buf integer
function M.remove(buf)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	help.remove(GENERAL, removals(GENERAL_ACTIONS), { buffer = buf })
	help.remove(GRAPH, removals(GRAPH_ACTIONS), { buffer = buf })
	help.remove(LOG, removals(LOG_ACTIONS), { buffer = buf })
end

return M
