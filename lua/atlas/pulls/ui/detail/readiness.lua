-- Merge readiness gates for the MR detail view's readiness strip
-- (DESIGN-merge-request-view.md §4). Pure: takes plain MR/merge-status data,
-- returns the gates to draw, which one is blocking, and the merge node. No
-- vim.api, no state -- the renderer turns the result into strip nodes.
local M = {}

---@alias AtlasReadinessState "passed"|"pending"|"failed"

---@class AtlasReadinessReviewer
---@field name string
---@field decision "approved"|"changes_requested"|"reviewed"|"pending"|nil

---@class AtlasReadinessInput
---@field state string|nil "open"|"draft"|"merged"|"declined"|"closed"
---@field draft boolean|nil
---@field target_branch string|nil
---@field detailed_merge_status string|nil GitLab's detailed_merge_status (any case).
---@field pipeline_status string|nil Head pipeline status (GitLab names, any case); nil = no pipeline.
---@field has_conflicts boolean|nil
---@field blocking_discussions_resolved boolean|nil
---@field resolvable_threads integer|nil
---@field resolved_threads integer|nil
---@field approved boolean|nil GitLab's "all required approvals given".
---@field reviewers AtlasReadinessReviewer[]|nil

---@class AtlasReadinessGate
---@field key "pipeline"|"conflicts"|"review"|"threads"|"draft"
---@field state AtlasReadinessState
---@field label string
---@field short string Compact (narrow-terminal) label, e.g. "pipeline".
---@field reason string|nil Why it blocks, shown under the node while blocking.

---@class AtlasReadinessMerge
---@field state "ready"|"blocked"|"merged"|"closed"
---@field label string
---@field reason string|nil Blocker that has no gate of its own (e.g. "needs rebase").

---@class AtlasReadiness
---@field gates AtlasReadinessGate[]
---@field blocking integer|nil Index into `gates` of the gate holding the merge back.
---@field merge AtlasReadinessMerge
---@field mergeable boolean

local PIPELINE_STATES = {
	success = "passed",
	skipped = "passed",
	failed = "failed",
	canceled = "failed",
	cancelled = "failed",
}

-- detailed_merge_status -> the gate it points at. Statuses without a gate
-- here (need_rebase, merge_request_blocked, ...) block the merge node itself.
local DMS_GATE = {
	ci_must_pass = "pipeline",
	ci_still_running = "pipeline",
	conflict = "conflicts",
	checking = "conflicts",
	unchecked = "conflicts",
	preparing = "conflicts",
	approvals_syncing = "review",
	not_approved = "review",
	requested_changes = "review",
	discussions_not_resolved = "threads",
	draft_status = "draft",
}

local DMS_REASON = {
	need_rebase = "needs rebase",
	merge_request_blocked = "blocked by a dependency",
	jira_association_missing = "Jira issue missing",
	external_status_checks = "external checks pending",
	broken_status = "merge status broken",
	not_open = "not open",
	locked_paths = "locked paths",
	locked_lfs_files = "locked LFS files",
	security_policy_violations = "security policy",
	commits_status = "commits status",
	title_regex = "title doesn't match",
}

---@param list string[]
---@return string
local function join(list)
	return table.concat(list, ", ")
end

---@param input AtlasReadinessInput
---@param dms string
---@return AtlasReadinessGate|nil
local function pipeline_gate(input, dms)
	local status = input.pipeline_status and tostring(input.pipeline_status):lower() or nil
	if status == nil or status == "" then
		-- No pipeline configured: not applicable, unless GitLab says CI must pass.
		if dms == "ci_must_pass" or dms == "ci_still_running" then
			return {
				key = "pipeline",
				state = dms == "ci_still_running" and "pending" or "failed",
				label = dms == "ci_still_running" and "Pipeline running" or "Pipeline required",
				short = "pipeline",
				reason = dms == "ci_still_running" and "waiting for pipeline" or "pipeline must pass",
			}
		end
		return nil
	end
	local state = PIPELINE_STATES[status] or "pending"
	local labels = { passed = "Pipeline passed", pending = "Pipeline running", failed = "Pipeline failed" }
	local reasons = { pending = "waiting for pipeline", failed = "pipeline must pass" }
	return { key = "pipeline", state = state, label = labels[state], short = "pipeline", reason = reasons[state] }
end

---@param input AtlasReadinessInput
---@param dms string
---@return AtlasReadinessGate
local function conflicts_gate(input, dms)
	local target = input.target_branch or "target"
	if input.has_conflicts == true or dms == "conflict" then
		return {
			key = "conflicts",
			state = "failed",
			label = "Conflicts with " .. target,
			short = "conflicts",
			reason = "resolve conflicts",
		}
	end
	if dms == "checking" or dms == "unchecked" or dms == "preparing" then
		return {
			key = "conflicts",
			state = "pending",
			label = "Checking…",
			short = "conflicts",
			reason = "checking mergeability",
		}
	end
	return { key = "conflicts", state = "passed", label = "No conflicts", short = "no conflicts" }
end

---@param input AtlasReadinessInput
---@param dms string
---@return AtlasReadinessGate|nil
local function review_gate(input, dms)
	local reviewers = input.reviewers or {}
	if #reviewers == 0 then
		return nil
	end
	local approved, requested, pending = {}, {}, {}
	for _, reviewer in ipairs(reviewers) do
		local name = tostring(reviewer.name or "")
		if reviewer.decision == "approved" then
			table.insert(approved, name)
		elseif reviewer.decision == "changes_requested" then
			table.insert(requested, name)
		else
			table.insert(pending, name)
		end
	end
	if #requested > 0 or dms == "requested_changes" then
		return {
			key = "review",
			state = "failed",
			label = #requested > 0 and ("Changes requested · " .. join(requested)) or "Changes requested",
			short = "review",
			reason = "changes requested",
		}
	end
	local needs_more = dms == "not_approved" or dms == "approvals_syncing" or input.approved == false
	if #approved > 0 and not needs_more then
		return {
			key = "review",
			state = "passed",
			label = "Approved · " .. join(approved),
			short = "approved",
		}
	end
	local waiting = #pending > 0 and pending or reviewers
	local names = {}
	for _, r in ipairs(waiting) do
		table.insert(names, type(r) == "table" and tostring(r.name or "") or r)
	end
	return {
		key = "review",
		state = "pending",
		label = "Review · " .. join(names),
		short = "review",
		reason = "waiting for approval",
	}
end

---@param input AtlasReadinessInput
---@param dms string
---@return AtlasReadinessGate|nil
local function threads_gate(input, dms)
	-- GitLab's verdict decides whether threads block; the counts only fill
	-- in the label. Open threads GitLab doesn't block on (it says the
	-- discussions are mergeable) leave the gate out, like any gate that
	-- doesn't apply.
	local blocking = input.blocking_discussions_resolved == false or dms == "discussions_not_resolved"
	local resolvable = tonumber(input.resolvable_threads)
	local resolved = tonumber(input.resolved_threads)
	local open = (resolvable and resolved) and math.max(0, resolvable - resolved) or nil
	if blocking then
		return {
			key = "threads",
			state = "failed",
			label = (open and open > 0) and string.format("%d unresolved thread%s", open, open == 1 and "" or "s")
				or "Unresolved threads",
			short = "threads",
			reason = "resolve threads",
		}
	end
	if open == nil or resolvable <= 0 then
		return nil
	end
	if open == 0 then
		return { key = "threads", state = "passed", label = "Threads resolved", short = "threads" }
	end
	if input.blocking_discussions_resolved == true then
		return nil
	end
	-- No verdict from GitLab at all: go by the counts.
	return {
		key = "threads",
		state = "failed",
		label = string.format("%d unresolved thread%s", open, open == 1 and "" or "s"),
		short = "threads",
		reason = "resolve threads",
	}
end

---@param input AtlasReadinessInput
---@return boolean
local function is_draft(input)
	return input.draft == true or tostring(input.state or ""):lower() == "draft"
end

---@param input AtlasReadinessInput
---@return AtlasReadiness
function M.derive(input)
	input = input or {}
	local dms = tostring(input.detailed_merge_status or ""):lower()
	local pr_state = tostring(input.state or ""):lower()
	local target = input.target_branch or "target"

	local gates = {}
	local function add(gate)
		if gate then
			table.insert(gates, gate)
		end
	end
	add(pipeline_gate(input, dms))
	add(conflicts_gate(input, dms))
	add(review_gate(input, dms))
	add(threads_gate(input, dms))
	if is_draft(input) then
		add({ key = "draft", state = "failed", label = "Marked as draft", short = "draft", reason = "mark as ready" })
	end

	if pr_state == "merged" then
		-- Everything is green once merged; neutral labels for gates that
		-- hadn't passed, so a green node never reads "failed"/"waiting".
		local MERGED_LABELS = { pipeline = "Pipeline", conflicts = "No conflicts", review = "Review", threads = "Threads" }
		for _, gate in ipairs(gates) do
			if gate.state ~= "passed" then
				gate.label = MERGED_LABELS[gate.key] or gate.label
			end
			gate.state = "passed"
			gate.reason = nil
		end
		return {
			gates = gates,
			blocking = nil,
			merge = { state = "merged", label = "Merged into " .. target },
			mergeable = false,
		}
	end

	-- GitLab's own verdict picks the blocking gate when it names one we show;
	-- otherwise the first gate that hasn't passed.
	local blocking
	local wanted = DMS_GATE[dms]
	if wanted then
		for i, gate in ipairs(gates) do
			if gate.key == wanted and gate.state ~= "passed" then
				blocking = i
				break
			end
		end
	end
	if blocking == nil then
		for i, gate in ipairs(gates) do
			if gate.state ~= "passed" then
				blocking = i
				break
			end
		end
	end

	if pr_state == "declined" or pr_state == "closed" then
		return {
			gates = gates,
			blocking = nil,
			merge = { state = "closed", label = "Closed" },
			mergeable = false,
		}
	end

	local merge_reason = blocking == nil and dms ~= "" and dms ~= "mergeable" and (DMS_REASON[dms] or dms:gsub("_", " "))
		or nil
	if blocking == nil and merge_reason == nil then
		return {
			gates = gates,
			blocking = nil,
			merge = { state = "ready", label = "Ready to merge" },
			mergeable = true,
		}
	end
	return {
		gates = gates,
		blocking = blocking,
		merge = { state = "blocked", label = "Merge into " .. target, reason = merge_reason or nil },
		mergeable = false,
	}
end

--- The message `gM` shows instead of merging while something blocks.
---@param readiness AtlasReadiness
---@return string|nil message nil when the MR can be merged.
function M.blocked_message(readiness)
	if readiness.mergeable then
		return nil
	end
	local merge = readiness.merge
	if merge.state == "merged" then
		return "Already merged"
	end
	if merge.state == "closed" then
		return "Merge request is closed"
	end
	local gate = readiness.blocking and readiness.gates[readiness.blocking]
	if gate then
		local reason = gate.reason and (" (" .. gate.reason .. ")") or ""
		return "Can't merge yet: " .. gate.label .. reason
	end
	return "Can't merge yet: " .. (merge.reason or "merge is blocked")
end

--- Narrow-terminal one-liner segments, e.g. ✓ pipeline · ✓ no conflicts ·
--- ◷ review · gM blocked (DESIGN-merge-request-view.md §1 "Narrow terminals").
---@param readiness AtlasReadiness
---@param merge_key string|nil
---@return { text: string, state: AtlasReadinessState|"ready"|"blocked"|"merged"|"closed", glyph: string|nil }[]
function M.compact(readiness, merge_key)
	local GLYPHS = { passed = "✓", pending = "◷", failed = "✗" }
	local out = {}
	for _, gate in ipairs(readiness.gates) do
		table.insert(out, { glyph = GLYPHS[gate.state], text = gate.short, state = gate.state })
	end
	local merge = readiness.merge
	local text
	if merge.state == "merged" then
		text = merge.label
	elseif merge.state == "closed" then
		text = "closed"
	else
		local word = merge.state == "ready" and "merge" or "blocked"
		text = merge_key and (merge_key .. " " .. word) or word
	end
	table.insert(out, { text = text, state = merge.state })
	return out
end

return M
