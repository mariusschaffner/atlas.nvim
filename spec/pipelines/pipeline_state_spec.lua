local pipeline_state = require("atlas.pipelines.pipeline_state")

--- Fake timers: `every` records handles; `fire(name)` runs one tick.
local function fake_timers()
	local t = { now_value = 1000, handles = {} }
	function t.every(ms, fn)
		local handle = { ms = ms, fn = fn, stopped = false }
		handle.stop = function()
			handle.stopped = true
		end
		table.insert(t.handles, handle)
		return handle
	end
	function t.now()
		return t.now_value
	end
	function t.live(ms)
		local out = {}
		for _, h in ipairs(t.handles) do
			if not h.stopped and (ms == nil or h.ms == ms) then
				table.insert(out, h)
			end
		end
		return out
	end
	return t
end

--- Fake detail API: every call is recorded and answered later via `resolve`.
local function fake_api()
	local api = { calls = {} }
	local function record(name)
		return function(...)
			local args = { ... }
			local call = { name = name, args = args, done = args[#args] }
			table.insert(api.calls, call)
			return { cancel = function() end }
		end
	end
	for _, name in ipairs({
		"fetch_pipeline",
		"fetch_pipeline_graph",
		"fetch_job_trace",
		"retry_pipeline",
		"cancel_pipeline",
		"retry_job",
		"cancel_job",
		"play_job",
	}) do
		api[name] = record(name)
	end
	function api.pending(name)
		local out = {}
		for _, call in ipairs(api.calls) do
			if call.name == name and not call.resolved then
				table.insert(out, call)
			end
		end
		return out
	end
	function api.resolve(name, ...)
		local call = api.pending(name)[1]
		assert(call, "no pending " .. name)
		call.resolved = true
		call.done(...)
		return call
	end
	return api
end

local function pipeline(status_value, jobs)
	return {
		id = "77",
		iid = "5",
		status = status_value,
		stages = { { name = "test", status = status_value, jobs = jobs } },
	}
end

--- `extra.started_at = false` means the job never started.
local function job(id, status_value, extra)
	local j = { id = id, name = "job" .. id, status = status_value, started_at = "2025-10-26T11:00:00Z" }
	for k, v in pairs(extra or {}) do
		j[k] = v
	end
	if j.started_at == false then
		j.started_at = nil
	end
	return j
end

local function new_store(api, timers)
	return pipeline_state.new({
		api = api,
		project_path = "atlas/semesterarbeit",
		pipeline_id = "77",
		iid = "5",
		timers = timers,
	})
end

describe("atlas.pipelines.pipeline_state", function()
	describe("trace_delta", function()
		it("appends a 206 partial body", function()
			assert.are.same({ "append", "more" }, { pipeline_state.trace_delta(10, "more", 206) })
		end)

		it("cuts the known prefix off a 200 full body", function()
			assert.are.same({ "append", "def" }, { pipeline_state.trace_delta(3, "abcdef", 200) })
		end)

		it("treats a 200 without new bytes as nothing new", function()
			assert.are.same({ "none", "" }, { pipeline_state.trace_delta(6, "abcdef", 200) })
		end)

		it("replaces the trace when the full body got shorter", function()
			assert.are.same({ "reset", "ab" }, { pipeline_state.trace_delta(6, "ab", 200) })
		end)

		it("treats 416 and empty bodies as nothing new", function()
			assert.are.same({ "none", "" }, { pipeline_state.trace_delta(6, "", 416) })
			assert.are.same({ "none", "" }, { pipeline_state.trace_delta(6, "", 206) })
		end)

		it("takes the whole first response", function()
			assert.are.same({ "append", "abc" }, { pipeline_state.trace_delta(0, "abc", 200) })
		end)
	end)

	describe("default_job", function()
		it("prefers a running job, then a failed one, then the first", function()
			local p = {
				stages = {
					{ jobs = { job("1", "success"), job("2", "failed", { allow_failure = true }) } },
					{ jobs = { job("3", "failed"), job("4", "running") } },
				},
			}
			assert.equal("4", pipeline_state.default_job(p).id)
			p.stages[2].jobs[2].status = "success"
			assert.equal("3", pipeline_state.default_job(p).id)
			p.stages[2].jobs[1].status = "success"
			assert.equal("1", pipeline_state.default_job(p).id)
		end)
	end)

	describe("polling", function()
		it("resolves the iid first when it isn't known", function()
			local api, timers = fake_api(), fake_timers()
			local store = pipeline_state.new({ api = api, project_path = "g/p", pipeline_id = "77", timers = timers })
			store:start()
			api.resolve("fetch_pipeline", { id = "77", iid = "5", status = "running" }, nil)
			local graph = api.pending("fetch_pipeline_graph")[1]
			assert.are.same({ "g/p", "5" }, { graph.args[1], graph.args[2] })
		end)

		it("polls while running and stops every timer once the pipeline finishes", function()
			local api, timers = fake_api(), fake_timers()
			local store = new_store(api, timers)
			local events = {}
			store:subscribe(function(event)
				table.insert(events, event)
			end)
			store:start()
			api.resolve("fetch_pipeline_graph", pipeline("running", { job("1", "running") }), nil)

			assert.equal(1, #timers.live(pipeline_state.PIPELINE_POLL_MS))
			assert.equal(1, #timers.live(pipeline_state.TRACE_POLL_MS))
			assert.equal(1, #timers.live(pipeline_state.TICK_MS))
			assert.are.same({ "poll", "tick", "trace" }, store:active_timers())
			assert.equal("1", store.selected_job_id)
			assert.equal("pipeline", events[#events])

			-- Next poll: the job and pipeline finished.
			api.resolve("fetch_job_trace", "line 1\n", nil, 200)
			timers.live(pipeline_state.PIPELINE_POLL_MS)[1].fn()
			api.resolve("fetch_pipeline_graph", pipeline("success", { job("1", "success", { duration = 5 }) }), nil)

			assert.are.same({}, timers.live())
			assert.are.same({}, store:active_timers())
		end)

		it("skips a poll while the previous fetch is still in flight", function()
			local api, timers = fake_api(), fake_timers()
			local store = new_store(api, timers)
			store:start()
			api.resolve("fetch_pipeline_graph", pipeline("running", { job("1", "pending", { started_at = false }) }), nil)
			local poll = timers.live(pipeline_state.PIPELINE_POLL_MS)[1]
			poll.fn()
			poll.fn()
			poll.fn()
			assert.equal(1, #api.pending("fetch_pipeline_graph"))
		end)

		it("doesn't poll a finished pipeline at all", function()
			local api, timers = fake_api(), fake_timers()
			local store = new_store(api, timers)
			store:start()
			api.resolve("fetch_pipeline_graph", pipeline("failed", { job("1", "failed", { duration = 3 }) }), nil)
			assert.are.same({}, timers.live())
		end)

		it("stops everything on stop()", function()
			local api, timers = fake_api(), fake_timers()
			local store = new_store(api, timers)
			store:start()
			api.resolve("fetch_pipeline_graph", pipeline("running", { job("1", "running") }), nil)
			store:stop()
			assert.are.same({}, timers.live())
		end)
	end)

	describe("traces", function()
		it("requests only new bytes and appends them", function()
			local api, timers = fake_api(), fake_timers()
			local store = new_store(api, timers)
			store:start()
			api.resolve("fetch_pipeline_graph", pipeline("running", { job("1", "running") }), nil)

			local first = api.resolve("fetch_job_trace", "abc\n", nil, 200)
			assert.equal(0, first.args[3])
			timers.live(pipeline_state.TRACE_POLL_MS)[1].fn()
			local second = api.resolve("fetch_job_trace", "def\n", nil, 206)
			assert.equal(4, second.args[3])
			timers.live(pipeline_state.TRACE_POLL_MS)[1].fn()
			api.resolve("fetch_job_trace", "", nil, 416)

			local trace = store:selected_trace()
			assert.equal("abc\ndef\n", trace.raw)
			assert.equal(8, trace.offset)
		end)

		it("fetches the finished job's tail once, then stops", function()
			local api, timers = fake_api(), fake_timers()
			local store = new_store(api, timers)
			store:start()
			api.resolve("fetch_pipeline_graph", pipeline("running", { job("1", "running"), job("2", "running") }), nil)
			api.resolve("fetch_job_trace", "abc\n", nil, 200)

			timers.live(pipeline_state.PIPELINE_POLL_MS)[1].fn()
			api.resolve("fetch_pipeline_graph", pipeline("running", { job("1", "success"), job("2", "running") }), nil)

			local final = api.pending("fetch_job_trace")
			assert.equal(1, #final)
			assert.equal(4, final[1].args[3])
			api.resolve("fetch_job_trace", "done\n", nil, 206)
			assert.is_true(store:selected_trace().complete)
			assert.equal(0, #timers.live(pipeline_state.TRACE_POLL_MS))
		end)

		it("switches traces on select and reuses a complete one", function()
			local api, timers = fake_api(), fake_timers()
			local store = new_store(api, timers)
			store:start()
			api.resolve(
				"fetch_pipeline_graph",
				pipeline("success", { job("1", "success", { duration = 1 }), job("2", "success", { duration = 1 }) }),
				nil
			)
			api.resolve("fetch_job_trace", "one\n", nil, 200)
			store:select_job("2")
			api.resolve("fetch_job_trace", "two\n", nil, 200)
			store:select_job("1")
			assert.equal(0, #api.pending("fetch_job_trace"))
			assert.equal("one\n", store:selected_trace().raw)
		end)

		it("doesn't request a trace for a job that never started", function()
			local api, timers = fake_api(), fake_timers()
			local store = new_store(api, timers)
			store:start()
			api.resolve(
				"fetch_pipeline_graph",
				pipeline("manual", { job("1", "manual", { manual = true, playable = true, started_at = false }) }),
				nil
			)
			assert.equal(0, #api.pending("fetch_job_trace"))
		end)
	end)

	describe("actions", function()
		it("restarts polling after an action on a finished pipeline", function()
			local api, timers = fake_api(), fake_timers()
			local store = new_store(api, timers)
			store:start()
			api.resolve("fetch_pipeline_graph", pipeline("failed", { job("1", "failed", { duration = 2 }) }), nil)
			api.resolve("fetch_job_trace", "boom\n", nil, 200)
			assert.are.same({}, timers.live())

			local result
			store:retry_failed(function(ok)
				result = ok
			end)
			local call = api.resolve("retry_pipeline", true, nil)
			assert.are.same({ "atlas/semesterarbeit", "77" }, { call.args[1], call.args[2] })
			assert.is_true(result)
			assert.equal(1, #api.pending("fetch_pipeline_graph"))
			assert.equal(1, #timers.live(pipeline_state.PIPELINE_POLL_MS))

			-- Still "failed" inside the grace window: keep polling.
			api.resolve("fetch_pipeline_graph", pipeline("failed", { job("1", "failed", { duration = 2 }) }), nil)
			assert.equal(1, #timers.live(pipeline_state.PIPELINE_POLL_MS))
			-- After it: stop.
			timers.now_value = timers.now_value + pipeline_state.ACTION_GRACE_SECONDS + 1
			timers.live(pipeline_state.PIPELINE_POLL_MS)[1].fn()
			api.resolve("fetch_pipeline_graph", pipeline("failed", { job("1", "failed", { duration = 2 }) }), nil)
			assert.are.same({}, timers.live())
		end)

		it("passes job ids to job actions and follows a retried job to its new id", function()
			local api, timers = fake_api(), fake_timers()
			local store = new_store(api, timers)
			store:start()
			api.resolve("fetch_pipeline_graph", pipeline("failed", { job("1", "failed", { duration = 2 }) }), nil)
			api.resolve("fetch_job_trace", "boom\n", nil, 200)

			store:retry_job("1")
			local call = api.resolve("retry_job", true, nil)
			assert.equal("1", call.args[2])
			local retried = job("9", "running")
			retried.name = "job1"
			api.resolve("fetch_pipeline_graph", pipeline("running", { retried }), nil)
			assert.equal("9", store.selected_job_id)
		end)

		it("reports a failed action without refreshing", function()
			local api, timers = fake_api(), fake_timers()
			local store = new_store(api, timers)
			store:start()
			api.resolve("fetch_pipeline_graph", pipeline("manual", {}), nil)
			local err
			store:play_job("4", function(_, e)
				err = e
			end)
			api.resolve("play_job", false, "HTTP 403")
			assert.equal("HTTP 403", err)
			assert.equal(0, #api.pending("fetch_pipeline_graph"))
		end)
	end)
end)
