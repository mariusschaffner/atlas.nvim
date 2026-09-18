local M = {}

local utils = require("atlas.ui.shared.utils")
local spinner = require("atlas.ui.components.spinner")
local notify = require("atlas.core.notify")
local threads = require("atlas.ui.components.threadsv2")
local detail = require("atlas.pulls.ui.repo_detail.state")
local request_scope = require("atlas.core.requests")

local PADDING_X = 1

---@param s string
---@return string
local function cap(s)
	return s:sub(1, 1):upper() .. s:sub(2)
end

--- Builds a PullsRepoDetailTabModule for a simple "list of repo refs" tab
--- (branches, tags, ...): fetch once per selected repo, render as a
--- threadsv2 list, refetch on force-refresh or repo change.
---@class PullsRefListTabOpts
---@field singular string                                    -- e.g. "branch"
---@field plural string                                      -- e.g. "branches"
---@field to_item fun(entry: table, repo: PullsRepoDetails): AtlasThreadV2Item
---@field fetch fun(repository: PullsRepositoryCapability, repo: PullsRepoDetails, opts: PullsFetchOpts, done: fun(result: table|nil, err: string|nil)): { cancel: fun() }|nil
---@field keymaps table|nil                                  -- optional { setup(buf, refresh), teardown(buf) }
---
---@param opts PullsRefListTabOpts
---@return table tab a PullsRepoDetailTabModule, plus `state`/`stop_requests` for entity-specific extensions
function M.create(opts)
	local tab = {}

	---@class PullsRefListTabState
	---@field repo PullsRepoDetails|nil
	---@field entries table|"loading"|string|nil
	---@field requests AtlasRequestScope
	local state = { repo = nil, entries = nil, requests = request_scope.new() }
	tab.state = state

	local function reset_state()
		state.repo = nil
		state.entries = nil
	end

	local function stop_requests()
		state.requests.cancel()
		state.requests = request_scope.new()
	end
	tab.stop_requests = stop_requests

	function tab.reset()
		stop_requests()
		reset_state()
	end

	---@param repo PullsRepoDetails
	---@return AtlasThreadV2Item[]
	local function to_items(repo)
		local items = {}
		for _, entry in ipairs((state.entries or {}).entries or {}) do
			table.insert(items, opts.to_item(entry, repo))
		end
		return items
	end

	---@param _repo PullsRepo
	---@param width integer
	---@return string[], table[], table<integer, table>
	function tab.render(_repo, width)
		local lines, spans, line_map = {}, {}, {}

		if state.entries == nil then
			if detail.current_repo_details == "loading" then
				utils.push(lines, spans, spinner.with_text("Loading repository details..."), "AtlasTextMuted", PADDING_X)
			end
			return lines, spans, line_map
		end

		if state.entries == "loading" then
			utils.push(lines, spans, spinner.with_text("Loading " .. opts.plural .. "..."), "AtlasTextMuted", PADDING_X)
			return lines, spans, line_map
		end
		if type(state.entries) == "string" then
			utils.push(lines, spans, state.entries, "AtlasLogError", PADDING_X)
			return lines, spans, line_map
		end

		local repo = state.repo
		if repo == nil then
			utils.push(lines, spans, "No " .. opts.plural .. " loaded.", "AtlasTextMuted", PADDING_X)
			return lines, spans, line_map
		end

		local entries = state.entries.entries or {}
		if #entries == 0 then
			utils.push(lines, spans, "No " .. opts.plural .. " found.", "AtlasTextMuted", PADDING_X)
			return lines, spans, line_map
		end

		local thread_lines, thread_spans, thread_map = threads.render(to_items(repo), width, {
			padding_x = PADDING_X,
			mode = "linked",
			content_max_lines = 1,
			author_hl = function()
				return "AtlasText"
			end,
			content_hl = function(_, row)
				return { { start_col = 0, end_col = #row, hl_group = "AtlasTextMuted" } }
			end,
		})

		utils.append_block(lines, spans, { lines = thread_lines, highlights = thread_spans })
		line_map = thread_map or {}
		return lines, spans, line_map
	end

	---@param repo PullsRepo|nil
	---@param refresh fun()
	---@param fetch_opts PullsFetchOpts|nil
	function tab.on_select(repo, refresh, fetch_opts)
		fetch_opts = fetch_opts or {}
		local repo_details = detail.current_repo_details
		if repo == nil then
			reset_state()
			refresh()
			return
		end
		if repo_details == "loading" then
			state.entries = "loading"
			refresh()
			return
		end
		if type(repo_details) ~= "table" then
			reset_state()
			refresh()
			return
		end

		local prev_name = state.repo and state.repo.full_name or ""
		local next_name = tostring(repo_details.full_name or "")
		local repo_label = next_name ~= "" and next_name or tostring(repo.name or repo.id or "")
		local should_fetch = fetch_opts.force_refresh == true
			or state.entries == nil
			or state.entries == "loading"
			or prev_name ~= next_name
		state.repo = repo_details
		if not should_fetch then
			refresh()
			return
		end

		stop_requests()
		state.entries = "loading"
		notify.loading(string.format("Loading %s for %s...", opts.plural, repo_label))
		refresh()

		local provider = detail.provider
		local repository = provider and provider.capabilities.repository
		if repository == nil then
			state.entries = { entries = {} }
			notify.error(string.format("%s listing is not supported by this provider", cap(opts.singular)))
			refresh()
			return
		end

		state.requests.run(function(done)
			return opts.fetch(repository, repo_details, {
				force_load = fetch_opts.force_load == true or fetch_opts.force_refresh == true,
				pagelen = fetch_opts.pagelen,
			}, done)
		end, function(result, err)
			local active_detail = detail.current_repo_details
			if type(active_detail) ~= "table" or tostring(active_detail.full_name or "") ~= next_name then
				return
			end
			state.repo = active_detail
			if err then
				state.entries = tostring(err)
				notify.error(string.format("Failed to load %s for %s", opts.plural, repo_label))
			else
				state.entries = result or { entries = {} }
				notify.success(string.format("%s loaded for %s", cap(opts.plural), repo_label), { timeout = 1200 })
			end
			refresh()
		end)
	end

	---@return boolean
	function tab.is_loading()
		return state.entries == "loading"
	end

	---@param _lnum integer
	---@param entry table
	---@return boolean
	function tab.is_selectable_line(_lnum, entry)
		return entry.kind == "header"
	end

	if opts.keymaps then
		function tab.activate(buf, refresh)
			if buf == nil or refresh == nil then
				return
			end
			opts.keymaps.setup(buf, refresh)
		end
	end

	function tab.deactivate(buf)
		stop_requests()
		if opts.keymaps and buf ~= nil then
			opts.keymaps.teardown(buf)
		end
	end

	return tab
end

return M
