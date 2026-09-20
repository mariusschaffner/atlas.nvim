local M = {}

local state = require("atlas.pulls.ui.detail.state")

--- Kicks off the 5 parallel, independently-loading pieces of a PR detail
--- view's secondary data (diffstat, pipelines, reviewers, merge checks,
--- closing issues).
--- Split out of atlas.pulls.ui.detail so that module can stay focused on
--- panel lifecycle (tabs, spinner, open/select/refresh orchestration).
---@param pr PullRequest
---@param force_refresh boolean
---@param same_ref fun(left: PullRequestRef|nil, right: PullRequestRef|nil): boolean
---@param tab_refresh fun()
function M.load_pr(pr, force_refresh, same_ref, tab_refresh)
	local provider = state.provider
	if provider == nil then
		return
	end
	local core = provider.capabilities.core

	if core.fetch_diffstat then
		state.diffstat = "loading"
		state.requests.run(function(done)
			return core.fetch_diffstat(pr, { force_refresh = force_refresh }, done)
		end, function(entries, err)
			if not same_ref(state.current_pr, pr) then
				return
			end
			state.diffstat = err and err or (entries or {})
			tab_refresh()
		end)
	end

	local pipelines = provider.capabilities.pipelines
	if pipelines then
		state.pipelines = "loading"
		state.requests.run(function(done)
			return pipelines.fetch(pr, { force_refresh = force_refresh }, done)
		end, function(items, err)
			if not same_ref(state.current_pr, pr) then
				return
			end
			state.pipelines = err and err or (items or {})
			tab_refresh()
		end)
	end

	if core.fetch_reviewers then
		state.reviewers = "loading"
		state.requests.run(function(done)
			return core.fetch_reviewers(pr, { force_refresh = force_refresh }, done)
		end, function(reviewers, err)
			if not same_ref(state.current_pr, pr) then
				return
			end
			state.reviewers = err and err or (reviewers or {})
			tab_refresh()
		end)
	end

	if core.fetch_merge_checks then
		state.merge_checks = "loading"
		state.requests.run(function(done)
			return core.fetch_merge_checks(pr, { force_refresh = force_refresh }, done)
		end, function(checks, err)
			if not same_ref(state.current_pr, pr) then
				return
			end
			state.merge_checks = err and err or (checks or {})
			tab_refresh()
		end)
	end

	if core.fetch_closing_issues then
		state.closing_issues = "loading"
		state.requests.run(function(done)
			return core.fetch_closing_issues(pr, { force_refresh = force_refresh }, done)
		end, function(issues, err)
			if not same_ref(state.current_pr, pr) then
				return
			end
			state.closing_issues = err and err or (issues or {})
			tab_refresh()
		end)
	end
end

return M
