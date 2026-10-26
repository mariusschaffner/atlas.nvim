local calls

local function load_api()
	package.loaded["atlas.pipelines.providers.gitlab.api.pipelines"] = nil
	return require("atlas.pipelines.providers.gitlab.api.pipelines")
end

describe("GitLab pipelines API (detail view)", function()
	before_each(function()
		calls = {}
		package.loaded["atlas.providers.gitlab.client"] = {
			base_url = function()
				return "https://gitlab.example.com"
			end,
			url_encode = function(s)
				return (s:gsub("/", "%%2F"))
			end,
			request = function(method, endpoint, data, on_done, ctx)
				table.insert(calls, { kind = "rest", method = method, endpoint = endpoint, ctx = ctx })
				on_done({}, nil)
				return { cancel = function() end }
			end,
			request_text = function(method, endpoint, on_done, ctx, opts)
				table.insert(calls, { kind = "text", method = method, endpoint = endpoint, ctx = ctx, opts = opts })
				on_done("body", nil, 206)
				return { cancel = function() end }
			end,
			graphql = function(query, variables, on_done)
				table.insert(calls, { kind = "graphql", query = query, variables = variables })
				on_done({ project = { pipeline = { id = "gid://gitlab/Ci::Pipeline/77", iid = "5", status = "RUNNING" } } }, nil)
				return { cancel = function() end }
			end,
		}
	end)

	after_each(function()
		package.loaded["atlas.providers.gitlab.client"] = nil
		package.loaded["atlas.pipelines.providers.gitlab.api.pipelines"] = nil
		package.loaded["atlas.pulls.providers.gitlab.api.pipelines"] = nil
	end)

	describe("map_pipeline_graph", function()
		it("maps the pipeline, ordered stages and every job flag", function()
			local api = load_api()
			local p = api.map_pipeline_graph({
				id = "gid://gitlab/Ci::Pipeline/77",
				iid = "5",
				status = "RUNNING",
				ref = "test",
				sha = "0123456789abcdef",
				startedAt = "2025-10-26T11:56:55Z",
				duration = vim.NIL,
				path = "/atlas/semesterarbeit/-/pipelines/77",
				user = { name = "Marius", username = "marius.schaffner" },
				commit = { title = "Merge test into master" },
				mergeRequest = { iid = "36", title = "MR title" },
				stages = {
					nodes = {
						{
							name = "Validate",
							status = "success",
							groups = {
								nodes = {
									{ jobs = { nodes = { { id = "gid://gitlab/Ci::Build/11", name = "yamllint", status = "SUCCESS", duration = 12 } } } },
									{ jobs = { nodes = { { id = "gid://gitlab/Ci::Build/12", name = "ansible-lint", status = "SUCCESS", duration = 41 } } } },
								},
							},
						},
						{
							name = "Deploy",
							status = "manual",
							groups = {
								nodes = {
									{
										jobs = {
											nodes = {
												{
													id = "gid://gitlab/Ci::Build/20",
													name = "deploy-staging",
													status = "MANUAL",
													manualJob = true,
													playable = true,
													allowFailure = true,
													webPath = "/atlas/semesterarbeit/-/jobs/20",
												},
											},
										},
									},
								},
							},
						},
					},
				},
			}, "atlas/semesterarbeit")

			assert.are.same(
				{ "77", "5", "running", "test", "01234567", "marius.schaffner", "Merge test into master", 36, "MR title" },
				{ p.id, p.iid, p.status, p.ref, p.short_sha, p.user.username, p.commit_title, p.merge_request.iid, p.merge_request.title }
			)
			assert.equal("https://gitlab.example.com/atlas/semesterarbeit/-/pipelines/77", p.web_url)
			assert.is_nil(p.duration)
			assert.are.same({ "Validate", "Deploy" }, { p.stages[1].name, p.stages[2].name })
			assert.are.same({ "11", "12" }, { p.stages[1].jobs[1].id, p.stages[1].jobs[2].id })
			assert.are.same({ "success", 12 }, { p.stages[1].jobs[1].status, p.stages[1].jobs[1].duration })
			local deploy = p.stages[2].jobs[1]
			assert.are.same({ "20", "manual", true, true, true, false }, {
				deploy.id,
				deploy.status,
				deploy.manual,
				deploy.playable,
				deploy.allow_failure,
				deploy.retryable,
			})
		end)
	end)

	it("queries the pipeline by iid", function()
		local api = load_api()
		local result
		api.fetch_pipeline_graph("atlas/semesterarbeit", "5", function(p)
			result = p
		end)
		assert.are.same({ path = "atlas/semesterarbeit", iid = "5" }, calls[1].variables)
		assert.truthy(calls[1].query:find("pipeline%(iid:%$iid%)"))
		assert.equal("77", result.id)
	end)

	it("retries the graph query without mergeRequest on older instances", function()
		local api = load_api()
		local client = package.loaded["atlas.providers.gitlab.client"]
		local attempts = 0
		client.graphql = function(query, _, on_done)
			attempts = attempts + 1
			if query:find("mergeRequest", 1, true) then
				on_done(nil, "Field 'mergeRequest' doesn't exist on type 'Pipeline'")
			else
				on_done({ project = { pipeline = { id = "77", status = "SUCCESS" } } }, nil)
			end
			return { cancel = function() end }
		end
		local result
		api.fetch_pipeline_graph("g/p", "5", function(p)
			result = p
		end)
		assert.equal(2, attempts)
		assert.equal("success", result.status)
	end)

	it("asks for the trace from a byte offset", function()
		local api = load_api()
		local status
		api.fetch_job_trace("atlas/semesterarbeit", "20", 128, function(_, _, s)
			status = s
		end)
		assert.equal("/projects/atlas%2Fsemesterarbeit/jobs/20/trace", calls[1].endpoint)
		assert.are.same({ Range = "bytes=128-" }, calls[1].opts.headers)
		assert.equal(206, status)

		api.fetch_job_trace("atlas/semesterarbeit", "20", 0, function() end)
		assert.is_nil(calls[2].opts)
	end)

	it("posts to the action endpoints", function()
		local api = load_api()
		local function ok() end
		api.retry_pipeline("g/p", "77", ok)
		api.cancel_pipeline("g/p", "77", ok)
		api.retry_job("g/p", "20", ok)
		api.cancel_job("g/p", "20", ok)
		api.play_job("g/p", "20", ok)
		local endpoints = {}
		for _, call in ipairs(calls) do
			assert.equal("POST", call.method)
			table.insert(endpoints, call.endpoint)
		end
		assert.are.same({
			"/projects/g%2Fp/pipelines/77/retry",
			"/projects/g%2Fp/pipelines/77/cancel",
			"/projects/g%2Fp/jobs/20/retry",
			"/projects/g%2Fp/jobs/20/cancel",
			"/projects/g%2Fp/jobs/20/play",
		}, endpoints)
	end)

	it("rejects actions without an id or project", function()
		local api = load_api()
		local errs = {}
		local function collect(_, err)
			table.insert(errs, err)
		end
		api.retry_pipeline("g/p", nil, collect)
		api.play_job("g/p", "x", collect)
		api.cancel_job("", "20", collect)
		assert.are.same({ "Missing pipeline ID", "Missing pipeline job ID", "Missing project" }, errs)
		assert.equal(0, #calls)
	end)

	it("keeps the MR Pipelines tab's pr-based actions on the same endpoints", function()
		package.loaded["atlas.pulls.pipelines"] = package.loaded["atlas.pulls.pipelines"] or { aggregate_state = function() end }
		package.loaded["atlas.pulls.providers.gitlab.api.pipelines"] = nil
		local pulls_api = require("atlas.pulls.providers.gitlab.api.pipelines")
		local pr = { repo_full_name = "g/p" }
		local function ok() end
		pulls_api.retry(pr, { id = "77" }, ok)
		pulls_api.cancel(pr, { id = "77" }, ok)
		pulls_api.retry_job(pr, { id = "20" }, ok)
		pulls_api.cancel_job(pr, { id = "20" }, ok)
		local endpoints = {}
		for _, call in ipairs(calls) do
			table.insert(endpoints, call.endpoint)
		end
		assert.are.same({
			"/projects/g%2Fp/pipelines/77/retry",
			"/projects/g%2Fp/pipelines/77/cancel",
			"/projects/g%2Fp/jobs/20/retry",
			"/projects/g%2Fp/jobs/20/cancel",
		}, endpoints)
	end)
end)
