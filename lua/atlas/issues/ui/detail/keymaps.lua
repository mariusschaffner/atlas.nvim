local M = {}

local help = require("atlas.ui.popups.help")
local resolver = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local actions = require("atlas.issues.actions")
local state = require("atlas.issues.ui.detail.state")
local notify = require("atlas.core.notify")

---@param text string
---@return string
local function slugify(text)
	local slug = tostring(text or ""):lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
	if #slug > 50 then
		slug = slug:sub(1, 50):gsub("%-+$", "")
	end
	return slug
end

---@param issue Issue
---@return string
local function default_branch_name(issue)
	local iid = tostring(issue.key or ""):match("#(%d+)$") or ""
	local slug = slugify(issue.title)
	if iid ~= "" and slug ~= "" then
		return iid .. "-" .. slug
	end
	return slug ~= "" and slug or ("issue-" .. iid)
end

---@param issue Issue
---@return boolean
local function is_current_issue(issue)
	local current = state.current_issue
	return current ~= nil and tostring(current.key or "") == tostring(issue.key or "")
end

---@param mr IssueLinkedMergeRequest
local function open_linked_mr(mr)
	local providers = require("atlas.providers")
	local pulls_provider = providers.load("gitlab", "pulls")
	if pulls_provider == nil then
		notify.error("Pull request provider unavailable")
		return
	end
	require("atlas.pulls.ui.detail").open({ id = mr.id, repo_full_name = mr.repo_full_name }, {
		provider = pulls_provider,
	})
end

---@param issue Issue
---@param on_update (fun(issue: Issue|nil, result: IssuesActionResult|nil))|nil
---@param result IssuesActionResult|nil
local function complete_action(issue, on_update, result)
	if not result or not result.issue_key then
		return
	end
	if on_update then
		on_update(issue, result)
		return
	end

	local detail = require("atlas.issues.ui.detail")
	if result.removed then
		detail.close()
	else
		detail.refresh()
	end
end

---@param buf integer
---@param opts { navigation: boolean|nil }|nil
function M.register(buf, opts)
	opts = opts or {}
	local items = {}
	local nav = require("atlas.issues.ui.detail.navigation")
	local provider = assert(state.provider)
	local function context(issue)
		return { provider = provider, issue = issue }
	end

	if opts.navigation ~= false then
		utils.insert_if(
			items,
			resolver.item("ui.next_item", {
				desc = "Next item",
				opts = { nowait = true, silent = true },
				hidden = true,
				hint = false,
				callback = function()
					nav.move_cursor("down")
				end,
			})
		)
		utils.insert_if(
			items,
			resolver.item("ui.previous_item", {
				desc = "Previous item",
				opts = { nowait = true, silent = true },
				hidden = true,
				hint = false,
				callback = function()
					nav.move_cursor("up")
				end,
			})
		)
	end
	if provider.capabilities.actions then
		utils.insert_if(
			items,
			resolver.item("ui.open_actions", {
				desc = "Open issue actions",
				hint = false,
				callback = function()
					local issue = state.current_issue
					if issue == nil then
						return
					end
					local on_update = state.on_update
					actions.open(context(issue), function(result)
						complete_action(issue, on_update, result)
					end)
				end,
			})
		)
	end

	---@param action_id string
	---@return boolean
	local function supports(action_id)
		if not provider.capabilities.actions then
			return false
		end
		for _, action in ipairs(provider.capabilities.actions.items or {}) do
			if action.id == action_id then
				return true
			end
		end
		return false
	end

	if supports("assign") then
		utils.insert_if(
			items,
			resolver.item("issues.change_assignee", {
				desc = "Change assignee",
				hint_desc = "Change Assignee",
				callback = function()
					local issue = state.current_issue
					if issue == nil then
						return
					end
					local on_update = state.on_update
					actions.run("assign", context(issue), function(result)
						complete_action(issue, on_update, result)
					end)
				end,
			})
		)
	end

	if supports("reporter") then
		utils.insert_if(
			items,
			resolver.item("issues.change_reporter", {
				desc = "Change reporter",
				hint_desc = "Change Reporter",
				callback = function()
					local issue = state.current_issue
					if issue == nil then
						return
					end
					local on_update = state.on_update
					actions.run("reporter", context(issue), function(result)
						complete_action(issue, on_update, result)
					end)
				end,
			})
		)
	end

	if supports("edit_issue") then
		utils.insert_if(
			items,
			resolver.item("issues.edit_issue", {
				desc = "Edit issue",
				hint_desc = "Edit",
				callback = function()
					local issue = state.current_issue
					if issue == nil then
						return
					end
					local on_update = state.on_update
					actions.run("edit_issue", context(issue), function(result)
						complete_action(issue, on_update, result)
					end)
				end,
			})
		)
	end

	if supports("labels") then
		utils.insert_if(
			items,
			resolver.item("issues.change_label", {
				desc = "Change labels",
				hint_desc = "Change Label",
				callback = function()
					local issue = state.current_issue
					if issue == nil then
						return
					end
					local on_update = state.on_update
					actions.run("labels", context(issue), function(result)
						complete_action(issue, on_update, result)
					end)
				end,
			})
		)
	end

	local core = provider.capabilities.core

	if core.create_branch and core.fetch_project_branches then
		utils.insert_if(
			items,
			resolver.item("issues.create_branch", {
				desc = "Create branch from issue",
				hint_desc = "New Branch",
				callback = function()
					local issue = state.current_issue
					if issue == nil then
						return
					end

					local function create_from(source_ref)
						vim.ui.input({ prompt = "Branch name: ", default = default_branch_name(issue) }, function(input)
							local name = input and vim.trim(input) or ""
							if name == "" then
								return
							end
							notify.loading("Creating branch...")
							core.create_branch(issue, name, source_ref, function(branch, err)
								if not is_current_issue(issue) then
									return
								end
								if not branch then
									notify.error("Create branch failed: " .. tostring(err or "Unknown error"))
									return
								end
								local existing = type(state.linked_branches) == "table" and state.linked_branches or {}
								table.insert(existing, branch)
								state.linked_branches = existing
								notify.success(
									string.format("Branch created: %s (from %s)", tostring(branch.name), source_ref),
									{ timeout = 1500 }
								)
								require("atlas.issues.ui.detail").rerender()
							end)
						end)
					end

					notify.loading("Loading branches...")
					core.fetch_project_branches(issue, {}, function(branches, err)
						if not is_current_issue(issue) then
							return
						end
						if not branches then
							notify.error("Failed to load branches: " .. tostring(err or "Unknown error"))
							return
						end
						if #branches == 0 then
							notify.error("No branches found")
							return
						end

						table.sort(branches, function(a, b)
							if a.default ~= b.default then
								return a.default
							end
							return a.name < b.name
						end)

						require("atlas.ui.picker").select({
							title = "Create branch from...",
							items = branches,
							kind = "atlas_issues_source_branch",
							format_item = function(branch)
								return branch.default and (branch.name .. "  (default)") or branch.name
							end,
							on_select = function(branch)
								if branch then
									create_from(branch.name)
								end
							end,
						})
					end)
				end,
			})
		)
	end

	if core.fetch_linked_merge_requests then
		utils.insert_if(
			items,
			resolver.item("issues.go_to_pull", {
				desc = "Go to linked pull request",
				hint_desc = "Go to PR",
				callback = function()
					local linked = state.linked_merge_requests
					if type(linked) ~= "table" or #linked == 0 then
						notify.warn("No linked merge requests")
						return
					end
					if #linked == 1 then
						open_linked_mr(linked[1])
						return
					end
					require("atlas.ui.picker").select({
						title = "Linked merge requests",
						items = linked,
						kind = "atlas_issues_linked_mrs",
						format_item = function(mr)
							return string.format("!%d %s", mr.id, mr.title)
						end,
						on_select = function(mr)
							if mr then
								open_linked_mr(mr)
							end
						end,
					})
				end,
			})
		)
	end

	M.remove(buf)
	local general = items

	utils.insert_if(
		general,
		resolver.item("ui.next_panel_tab", {
			desc = "Next detail tab",
			hint = false,
			opts = { nowait = true },
			callback = function()
				require("atlas.issues.ui.detail").next_tab()
			end,
		})
	)

	utils.insert_if(
		general,
		resolver.item("ui.previous_panel_tab", {
			desc = "Previous detail tab",
			hint = false,
			opts = { nowait = true },
			callback = function()
				require("atlas.issues.ui.detail").prev_tab()
			end,
		})
	)

	utils.insert_if(
		general,
		resolver.item("ui.help", {
			desc = "Toggle help",
			hint = false,
			opts = { nowait = true, silent = true },
			callback = function()
				help.toggle({ buffer = buf })
			end,
		})
	)

	utils.insert_if(
		general,
		resolver.item("ui.toggle_panel", {
			desc = "Toggle detail panel",
			hint = false,
			callback = function()
				require("atlas.issues.ui.detail").close()
			end,
		})
	)

	utils.insert_if(
		general,
		resolver.item("ui.close", {
			desc = "Close detail panel",
			hint = false,
			opts = { nowait = true, silent = true },
			callback = function()
				if not help.is_open() then
					require("atlas.issues.ui.detail").close()
				end
			end,
		})
	)

	help.register("General", general, { index = 300, buffer = buf })
end

---@param buf integer
function M.remove(buf)
	local general = {}
	utils.insert_if(general, resolver.remove_item("ui.next_item"))
	utils.insert_if(general, resolver.remove_item("ui.previous_item"))
	utils.insert_if(general, resolver.remove_item("ui.open_actions"))
	utils.insert_if(general, resolver.remove_item("issues.change_assignee"))
	utils.insert_if(general, resolver.remove_item("issues.change_reporter"))
	utils.insert_if(general, resolver.remove_item("issues.change_label"))
	utils.insert_if(general, resolver.remove_item("issues.edit_issue"))
	utils.insert_if(general, resolver.remove_item("issues.create_branch"))
	utils.insert_if(general, resolver.remove_item("issues.go_to_pull"))
	utils.insert_if(general, resolver.remove_item("ui.next_panel_tab"))
	utils.insert_if(general, resolver.remove_item("ui.previous_panel_tab"))
	utils.insert_if(general, resolver.remove_item("ui.help"))
	utils.insert_if(general, resolver.remove_item("ui.toggle_panel"))
	utils.insert_if(general, resolver.remove_item("ui.close"))
	help.remove("General", general, { buffer = buf })
end

return M
