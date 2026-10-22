local dependencies = {
	"atlas.providers.gitlab.client",
	"atlas.pulls.pipelines",
	"atlas.pulls.providers.gitlab.api.pipelines",
}

local previous = { loaded = {}, preload = {} }

local function load_checks(stubs)
	for name, value in pairs(stubs) do
		previous.loaded[name] = package.loaded[name]
		previous.preload[name] = package.preload[name]
		package.loaded[name] = nil
		package.preload[name] = function()
			return value
		end
	end
	package.loaded["atlas.pulls.providers.gitlab.api.checks"] = nil
	return require("atlas.pulls.providers.gitlab.api.checks")
end

describe("GitLab merge checks", function()
	after_each(function()
		package.loaded["atlas.pulls.providers.gitlab.api.checks"] = nil
		for _, name in ipairs(dependencies) do
			package.loaded[name] = previous.loaded[name]
			package.preload[name] = previous.preload[name]
		end
		previous = { loaded = {}, preload = {} }
	end)

	it("fetches merge state and head pipeline together", function()
		local query, variables, merge_done
		local checks = load_checks({
			["atlas.providers.gitlab.client"] = {
				get_memory_cache = function()
					return nil, false
				end,
				set_memory_cache = function() end,
				graphql = function(q, vars, done)
					query, variables, merge_done = q, vars, done
					return { cancel = function() end }
				end,
			},
			["atlas.pulls.pipelines"] = {
				to_merge_check = function()
					return nil
				end,
			},
			["atlas.pulls.providers.gitlab.api.pipelines"] = {
				to_pipeline_state = function()
					return "SUCCESSFUL"
				end,
			},
		})

		local result
		checks.fetch({ id = 7, repo_full_name = "group/project", state = "open" }, nil, function(value)
			result = value
		end)

		assert.same({ path = "group/project", iid = "7" }, variables)
		for _, field in ipairs({ "detailedMergeStatus", "mergeableDiscussionsState", "conflicts", "headPipeline" }) do
			assert.is_truthy(query:find(field, 1, true))
		end
		for _, field in ipairs({ "description", "labels", "assignees", "reviewers" }) do
			assert.is_nil(query:find(field, 1, true))
		end

		merge_done({
			project = {
				mergeRequest = {
					draft = false,
					detailed_merge_status = "mergeable",
					blocking_discussions_resolved = true,
					has_conflicts = false,
					head_pipeline = { status = "SUCCESS" },
				},
			},
		}, nil)

		assert.equal("conflicts", result[1].key)
		assert.equal("successful", result[1].state)
	end)

	it("keeps the readiness fields and falls back to the base query on a schema error", function()
		local calls = {}
		local checks = load_checks({
			["atlas.providers.gitlab.client"] = {
				get_memory_cache = function()
					return nil, false
				end,
				set_memory_cache = function() end,
				graphql = function(q, _, done)
					table.insert(calls, { query = q, done = done })
					return { cancel = function() end }
				end,
			},
			["atlas.pulls.pipelines"] = {
				to_merge_check = function()
					return nil
				end,
			},
			["atlas.pulls.providers.gitlab.api.pipelines"] = {
				to_pipeline_state = function()
					return "SUCCESSFUL"
				end,
			},
		})

		local result, err
		checks.fetch({ id = 7, repo_full_name = "group/project", state = "open" }, nil, function(value, e)
			result, err = value, e
		end)
		assert.is_truthy(calls[1].query:find("resolvableDiscussionsCount", 1, true))

		calls[1].done(nil, "Field 'resolvableDiscussionsCount' doesn't exist on type 'MergeRequest'")
		assert.equal(2, #calls)
		assert.is_nil(calls[2].query:find("resolvableDiscussionsCount", 1, true))
		assert.is_nil(result)

		calls[2].done({
			project = {
				mergeRequest = {
					draft = false,
					detailed_merge_status = "NOT_APPROVED",
					blocking_discussions_resolved = false,
					has_conflicts = false,
					head_pipeline = { status = "RUNNING" },
				},
			},
		}, nil)
		assert.is_nil(err)
		assert.equal("NOT_APPROVED", result.status.detailed_merge_status)
		assert.equal("RUNNING", result.status.pipeline_status)
		assert.is_false(result.status.blocking_discussions_resolved)
		assert.is_nil(result.status.resolvable_threads)
	end)

	it("exposes approval and thread counts when the schema has them", function()
		local done_fn
		local checks = load_checks({
			["atlas.providers.gitlab.client"] = {
				get_memory_cache = function()
					return nil, false
				end,
				set_memory_cache = function() end,
				graphql = function(_, _, done)
					done_fn = done
					return { cancel = function() end }
				end,
			},
			["atlas.pulls.pipelines"] = {
				to_merge_check = function()
					return nil
				end,
			},
			["atlas.pulls.providers.gitlab.api.pipelines"] = {
				to_pipeline_state = function()
					return "SUCCESSFUL"
				end,
			},
		})
		local result
		checks.fetch({ id = 7, repo_full_name = "group/project", state = "open" }, nil, function(value)
			result = value
		end)
		done_fn({
			project = {
				mergeRequest = {
					draft = false,
					detailed_merge_status = "MERGEABLE",
					blocking_discussions_resolved = true,
					has_conflicts = false,
					head_pipeline = vim.NIL,
					approved = true,
					resolvable_threads = 3,
					resolved_threads = 2,
				},
			},
		}, nil)
		assert.is_true(result.status.approved)
		assert.equal(3, result.status.resolvable_threads)
		assert.equal(2, result.status.resolved_threads)
		assert.is_nil(result.status.pipeline_status)
	end)
end)
