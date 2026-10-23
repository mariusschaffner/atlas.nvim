local readiness = require("atlas.pulls.ui.detail.readiness")

---@param gates AtlasReadinessGate[]
---@return string[]
local function keys(gates)
	local out = {}
	for _, gate in ipairs(gates) do
		table.insert(out, gate.key .. ":" .. gate.state)
	end
	return out
end

-- `nil` can't be passed through a table literal; NONE clears a default.
local NONE = {}

local function base(overrides)
	local input = {
		state = "open",
		target_branch = "master",
		detailed_merge_status = "mergeable",
		pipeline_status = "SUCCESS",
		has_conflicts = false,
		blocking_discussions_resolved = true,
		reviewers = { { name = "mose.mueller", decision = "approved" } },
	}
	for k, v in pairs(overrides or {}) do
		if v == NONE then
			input[k] = nil
		else
			input[k] = v
		end
	end
	return input
end

describe("pulls.ui.detail.readiness.derive", function()
	it("is ready to merge when every gate passed", function()
		local r = readiness.derive(base())
		assert.are.same({ "pipeline:passed", "conflicts:passed", "review:passed" }, keys(r.gates))
		assert.is_nil(r.blocking)
		assert.are.equal("ready", r.merge.state)
		assert.are.equal("Ready to merge", r.merge.label)
		assert.is_true(r.mergeable)
		assert.are.equal("Approved · mose.mueller", r.gates[3].label)
	end)

	it("labels a pending review with the reviewers and blocks on it", function()
		local r = readiness.derive(base({
			detailed_merge_status = "not_approved",
			reviewers = { { name = "mose.mueller", decision = "pending" } },
		}))
		assert.are.same({ "pipeline:passed", "conflicts:passed", "review:pending" }, keys(r.gates))
		assert.are.equal(3, r.blocking)
		assert.are.equal("Review · mose.mueller", r.gates[3].label)
		assert.are.equal("waiting for approval", r.gates[3].reason)
		assert.are.equal("blocked", r.merge.state)
		assert.are.equal("Merge into master", r.merge.label)
		assert.is_false(r.mergeable)
	end)

	it("keeps review pending while approvals are still missing", function()
		local r = readiness.derive(base({
			detailed_merge_status = "not_approved",
			reviewers = {
				{ name = "a", decision = "approved" },
				{ name = "b", decision = "pending" },
			},
		}))
		assert.are.equal("review:pending", keys(r.gates)[3])
		assert.are.equal("Review · b", r.gates[3].label)
	end)

	it("fails review when changes are requested", function()
		local r = readiness.derive(base({
			detailed_merge_status = "requested_changes",
			reviewers = { { name = "x", decision = "changes_requested" }, { name = "y", decision = "approved" } },
		}))
		assert.are.equal("review:failed", keys(r.gates)[3])
		assert.are.equal("Changes requested · x", r.gates[3].label)
		assert.are.equal(3, r.blocking)
	end)

	it("maps pipeline states", function()
		assert.are.equal("Pipeline running", readiness.derive(base({ pipeline_status = "running" })).gates[1].label)
		assert.are.equal("pending", readiness.derive(base({ pipeline_status = "PENDING" })).gates[1].state)
		local failed = readiness.derive(base({ pipeline_status = "FAILED", detailed_merge_status = "ci_must_pass" }))
		assert.are.equal("pipeline:failed", keys(failed.gates)[1])
		assert.are.equal("Pipeline failed", failed.gates[1].label)
		assert.are.equal(1, failed.blocking)
	end)

	it("hides gates that don't apply", function()
		local r = readiness.derive(base({ pipeline_status = NONE, reviewers = {} }))
		assert.are.same({ "conflicts:passed" }, keys(r.gates))
		assert.is_true(r.mergeable)
	end)

	it("shows a required pipeline even without a head pipeline", function()
		local r = readiness.derive(base({ pipeline_status = NONE, detailed_merge_status = "ci_must_pass" }))
		assert.are.equal("pipeline:failed", keys(r.gates)[1])
		assert.are.equal(1, r.blocking)
	end)

	it("reports conflicts against the target branch", function()
		local r = readiness.derive(base({ has_conflicts = true, detailed_merge_status = "conflict" }))
		assert.are.equal("conflicts:failed", keys(r.gates)[2])
		assert.are.equal("Conflicts with master", r.gates[2].label)
		assert.are.equal(2, r.blocking)
	end)

	it("shows conflicts as pending while GitLab is checking", function()
		local r = readiness.derive(base({ detailed_merge_status = "checking" }))
		assert.are.equal("conflicts:pending", keys(r.gates)[2])
		assert.are.equal("Checking…", r.gates[2].label)
		assert.are.equal(2, r.blocking)
	end)

	it("shows the threads gate only when there are resolvable threads", function()
		local none = readiness.derive(base({ resolvable_threads = 0, resolved_threads = 0 }))
		assert.are.equal(3, #none.gates)

		local open = readiness.derive(base({
			resolvable_threads = 3,
			resolved_threads = 1,
			detailed_merge_status = "discussions_not_resolved",
		}))
		assert.are.equal("threads:failed", keys(open.gates)[4])
		assert.are.equal("2 unresolved threads", open.gates[4].label)
		assert.are.equal(4, open.blocking)

		local done = readiness.derive(base({ resolvable_threads = 2, resolved_threads = 2 }))
		assert.are.equal("threads:passed", keys(done.gates)[4])
		assert.are.equal("Threads resolved", done.gates[4].label)
	end)

	it("doesn't block on open threads GitLab says are mergeable", function()
		local r = readiness.derive(base({
			detailed_merge_status = "mergeable",
			blocking_discussions_resolved = true,
			resolvable_threads = 2,
			resolved_threads = 1,
			reviewers = { { name = "r", decision = "approved" } },
		}))
		assert.are.same({ "pipeline:passed", "conflicts:passed", "review:passed" }, keys(r.gates))
		assert.is_true(r.mergeable)
	end)

	it("goes by the counts when GitLab gives no thread verdict", function()
		local r = readiness.derive(base({
			detailed_merge_status = NONE,
			blocking_discussions_resolved = NONE,
			resolvable_threads = 1,
			resolved_threads = 0,
		}))
		assert.are.equal("threads:failed", keys(r.gates)[4])
		assert.are.equal("1 unresolved thread", r.gates[4].label)
	end)

	it("falls back to the blocking-discussions flag without counts", function()
		local r = readiness.derive(base({ blocking_discussions_resolved = false }))
		assert.are.equal("threads:failed", keys(r.gates)[4])
		assert.are.equal("Unresolved threads", r.gates[4].label)
	end)

	it("adds a draft gate for drafts", function()
		local r = readiness.derive(base({ state = "draft", detailed_merge_status = "draft_status" }))
		assert.are.equal("draft:failed", keys(r.gates)[#r.gates])
		assert.are.equal("Marked as draft", r.gates[#r.gates].label)
		assert.are.equal(#r.gates, r.blocking)
	end)

	it("lets detailed_merge_status pick the blocking gate over gate order", function()
		local r = readiness.derive(base({
			pipeline_status = "running",
			detailed_merge_status = "not_approved",
			reviewers = { { name = "r", decision = "pending" } },
		}))
		assert.are.equal("pipeline:pending", keys(r.gates)[1])
		assert.are.equal(3, r.blocking)
	end)

	it("blocks the merge node itself for statuses without a gate", function()
		local r = readiness.derive(base({ detailed_merge_status = "need_rebase" }))
		assert.is_nil(r.blocking)
		assert.are.equal("blocked", r.merge.state)
		assert.are.equal("needs rebase", r.merge.reason)
		assert.is_false(r.mergeable)
	end)

	it("turns every gate green once merged", function()
		local r = readiness.derive(base({
			state = "merged",
			pipeline_status = "failed",
			detailed_merge_status = "not_open",
			reviewers = { { name = "r", decision = "pending" } },
		}))
		assert.are.same({ "pipeline:passed", "conflicts:passed", "review:passed" }, keys(r.gates))
		assert.are.equal("Pipeline", r.gates[1].label)
		assert.are.equal("Review", r.gates[3].label)
		assert.are.equal("merged", r.merge.state)
		assert.are.equal("Merged into master", r.merge.label)
		assert.is_nil(r.blocking)
	end)

	it("marks closed merge requests as closed", function()
		local r = readiness.derive(base({ state = "declined", detailed_merge_status = "not_open" }))
		assert.are.equal("closed", r.merge.state)
		assert.is_false(r.mergeable)
	end)
end)

describe("pulls.ui.detail.readiness.blocked_message", function()
	it("is nil when mergeable", function()
		assert.is_nil(readiness.blocked_message(readiness.derive(base())))
	end)

	it("names the blocking gate and its reason", function()
		local r = readiness.derive(base({
			detailed_merge_status = "not_approved",
			reviewers = { { name = "mose.mueller", decision = "pending" } },
		}))
		assert.are.equal("Can't merge yet: Review · mose.mueller (waiting for approval)", readiness.blocked_message(r))
	end)

	it("names merge-node blockers", function()
		local r = readiness.derive(base({ detailed_merge_status = "need_rebase" }))
		assert.are.equal("Can't merge yet: needs rebase", readiness.blocked_message(r))
	end)

	it("explains merged and closed states", function()
		assert.are.equal("Already merged", readiness.blocked_message(readiness.derive(base({ state = "merged" }))))
		assert.are.equal(
			"Merge request is closed",
			readiness.blocked_message(readiness.derive(base({ state = "declined" })))
		)
	end)
end)

describe("pulls.ui.detail.readiness.compact", function()
	it("builds the narrow one-liner segments", function()
		local r = readiness.derive(base({
			detailed_merge_status = "not_approved",
			reviewers = { { name = "m", decision = "pending" } },
		}))
		local texts = {}
		for _, seg in ipairs(readiness.compact(r, "gM")) do
			table.insert(texts, (seg.glyph and (seg.glyph .. " ") or "") .. seg.text)
		end
		assert.are.same({ "✓ pipeline", "✓ no conflicts", "◷ review", "gM blocked" }, texts)
	end)

	it("says merge when ready", function()
		local segs = readiness.compact(readiness.derive(base()), "gM")
		assert.are.equal("gM merge", segs[#segs].text)
	end)
end)
