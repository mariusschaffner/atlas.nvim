local M = {}

local state = require("atlas.pulls.ui.detail.state")
local readiness = require("atlas.pulls.ui.detail.readiness")
local presentation = require("atlas.pulls.ui.presentation")

--- Kicks off the 4 parallel, independently-loading pieces of a PR detail
--- view's secondary data (diffstat, pipelines, reviewers, merge checks).
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
			state.merge_status = checks and checks.status or nil
			tab_refresh()
		end)
	end
end

--- The readiness strip's gates for the current PR (DESIGN-merge-request-view.md
--- §4), or nil while the merge status/reviewers are still loading (or failed).
---@return AtlasReadiness|nil
function M.readiness()
	local pr = state.current_pr
	local status = state.merge_status
	if pr == nil or status == nil or type(state.reviewers) == "string" or state.reviewers == "loading" then
		return nil
	end
	local reviewers = {}
	for _, reviewer in ipairs(type(state.reviewers) == "table" and state.reviewers or {}) do
		-- Approvers who aren't requested reviewers still count for the review gate.
		if reviewer.role ~= "participant" or reviewer.decision == "approved" then
			table.insert(reviewers, { name = presentation.user_handle(reviewer), decision = reviewer.decision })
		end
	end
	---@cast pr GitLabPullRequest
	return readiness.derive({
		state = pr.state,
		draft = status.draft,
		target_branch = pr.destination and pr.destination.branch or nil,
		detailed_merge_status = status.detailed_merge_status or pr.detailed_merge_status,
		pipeline_status = status.pipeline_status,
		has_conflicts = status.has_conflicts,
		blocking_discussions_resolved = status.blocking_discussions_resolved,
		resolvable_threads = status.resolvable_threads,
		resolved_threads = status.resolved_threads,
		approved = status.approved,
		reviewers = reviewers,
	})
end

--- Opens one of the PR's pipelines in the pipeline detail view (the
--- pipelines domain's own view, same one its dashboard opens). Closing that
--- view (`q`) comes back to this PR, on the tab it was opened from.
---@param pipeline PullsPipeline
function M.open_pipeline(pipeline)
	local pr = state.current_pr
	if pr == nil then
		return
	end
	local provider = require("atlas.providers").load(pr.provider or "gitlab", "pipelines")
	if provider == nil then
		require("atlas.core.notify").error("Pipelines provider unavailable")
		return
	end
	local path = tostring(pr.repo_full_name or "")
	-- Only what identifies the pipeline: its ref/sha/user/times are loaded by
	-- the pipeline view itself (the MR's head ref/sha aren't an older
	-- pipeline's).
	---@type Pipeline
	local target = {
		id = tostring(pipeline.id or ""),
		key = string.format("%s!%s", path, tostring(pipeline.id or "")),
		project_path = path,
		status = pipeline.provider_state or "",
		state = pipeline.state,
		ref = "",
		sha = "",
		merge_request_iid = tonumber(pr.id),
		web_url = pipeline.url,
		duration = pipeline.duration,
		stages = {},
	}
	for _, stage in ipairs(pipeline.stages or {}) do
		table.insert(target.stages, { name = stage.name or "Stage", state = stage.state, jobs = {} })
	end

	-- Opening the pipeline view replaces this one (and its cleanup wipes
	-- this state), so capture what's needed to come back first.
	local pulls_provider, on_update, tab = state.provider, state.on_update, state.current_tab
	require("atlas.pipelines.ui.detail").open(target, {
		provider = provider,
		merge_request = { iid = tonumber(pr.id), title = pr.title },
		return_to = function()
			local detail = require("atlas.pulls.ui.detail")
			detail.open(pr, { provider = pulls_provider, on_update = on_update })
			if tab then
				detail.select_tab(tab)
			end
		end,
	})
end

--- The PR's most recent pipeline, or nil (none, or not loaded yet).
---@return PullsPipeline|nil
function M.latest_pipeline()
	local pipelines = state.pipelines
	if type(pipelines) ~= "table" then
		return nil
	end
	local latest
	for _, pipeline in ipairs(pipelines) do
		if latest == nil or (tonumber(pipeline.id) or 0) > (tonumber(latest.id) or 0) then
			latest = pipeline
		end
	end
	return latest
end

return M
