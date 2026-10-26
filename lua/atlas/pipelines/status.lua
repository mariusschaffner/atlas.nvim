-- Pipeline / stage / job status -> glyph, label and colour
-- (DESIGN-pipeline-view.md §2, §3, §7), plus the clock-style durations the
-- pipeline view prints ("12s", "1:02", "3:05 elapsed"). Pure: no editor state.
local M = {}

local utils = require("atlas.ui.shared.utils")

local HL = {
	running = "AtlasCyan",
	success = "AtlasGreen",
	warning = "AtlasYellow",
	failed = "AtlasRed",
	dim = "AtlasTextMuted",
}

-- Statuses GitLab can still move on from by itself (polling continues).
local ACTIVE = {
	created = true,
	waiting_for_resource = true,
	waiting_for_callback = true,
	preparing = true,
	pending = true,
	running = true,
	canceling = true,
	scheduled = true,
}

local PENDING = {
	created = true,
	waiting_for_resource = true,
	waiting_for_callback = true,
	preparing = true,
	pending = true,
	scheduled = true,
}

---@param status string|nil
---@return string
function M.normalize(status)
	return tostring(status or ""):lower()
end

--- Whether a pipeline (or job) in `status` can still change without user action.
---@param status string|nil
---@return boolean
function M.is_active(status)
	return ACTIVE[M.normalize(status)] == true
end

---@class AtlasPipelinePill
---@field icon string
---@field label string
---@field hl string Tinted pill group.
---@field color string Plain foreground group in the pill's colour (elapsed text, stage names).

---@type table<string, AtlasPipelinePill>
local PILLS = {
	running = { icon = "◐", label = "Running", hl = "AtlasGLPipelineRunningPillChip", color = HL.running },
	pending = { icon = "◷", label = "Pending", hl = "AtlasGLPipelinePendingPillChip", color = HL.warning },
	success = { icon = "✓", label = "Passed", hl = "AtlasGLPipelinePassedPillChip", color = HL.success },
	failed = { icon = "✗", label = "Failed", hl = "AtlasGLPipelineFailedPillChip", color = HL.failed },
	canceled = { icon = "⊘", label = "Canceled", hl = "AtlasGLPipelineCanceledPillChip", color = HL.dim },
	manual = { icon = "▶", label = "Manual", hl = "AtlasGLPipelineManualPillChip", color = HL.warning },
}

--- State pill for a pipeline status (§2).
---@param status string|nil
---@return AtlasPipelinePill
function M.pipeline_pill(status)
	local s = M.normalize(status)
	if s == "running" or s == "canceling" then
		return PILLS.running
	elseif s == "success" then
		return PILLS.success
	elseif s == "failed" then
		return PILLS.failed
	elseif s == "canceled" or s == "skipped" then
		return PILLS.canceled
	elseif s == "manual" then
		return PILLS.manual
	end
	return PILLS.pending
end

--- "12s", "1:02", "1:02:03"; "" for nil.
---@param seconds number|nil
---@return string
function M.clock(seconds)
	local total = tonumber(seconds)
	if total == nil then
		return ""
	end
	total = math.max(0, math.floor(total + 0.5))
	if total < 60 then
		return string.format("%ds", total)
	end
	local hours = math.floor(total / 3600)
	local minutes = math.floor((total % 3600) / 60)
	local secs = total % 60
	if hours > 0 then
		return string.format("%d:%02d:%02d", hours, minutes, secs)
	end
	return string.format("%d:%02d", minutes, secs)
end

--- Seconds something has been running: its final `duration` when finished,
--- otherwise `now - started_at`.
---@param item { duration: number|nil, started_at: string|nil, finished_at: string|nil, status: string|nil }
---@param now integer Epoch seconds.
---@return number|nil
function M.duration(item, now)
	if item.duration ~= nil and not M.is_active(item.status) then
		return item.duration
	end
	local started = utils.iso_epoch(item.started_at)
	if started == nil then
		return item.duration
	end
	local finished = utils.iso_epoch(item.finished_at)
	return math.max(0, (finished or now) - started)
end

--- Title-line timer: `{ "3:05", " elapsed" }` while running, `{ "5:41", " total" }` after.
---@param pipeline { duration: number|nil, started_at: string|nil, finished_at: string|nil, status: string|nil }
---@param now integer
---@return string|nil value
---@return string suffix
function M.elapsed(pipeline, now)
	local seconds = M.duration(pipeline, now)
	if seconds == nil then
		return nil, ""
	end
	return M.clock(seconds), M.is_active(pipeline.status) and " elapsed" or " total"
end

---@class AtlasPipelineJobBadge
---@field kind "success"|"running"|"pending"|"failed"|"allowed_failure"|"canceled"|"skipped"|"manual"|"blocked"|"unknown"
---@field icon string
---@field icon_hl string
---@field border "solid"|"dashed"
---@field border_hl string
---@field name_hl string|nil
---@field right_text string Duration, "blocked", or "" (manual jobs show their play key instead).
---@field right_hl string

--- Pill contents for one job (§3).
---@param job { status: string|nil, allow_failure: boolean|nil, manual: boolean|nil, playable: boolean|nil, duration: number|nil, started_at: string|nil, finished_at: string|nil }
---@param now integer
---@return AtlasPipelineJobBadge
function M.job_badge(job, now)
	local s = M.normalize(job.status)
	local duration = M.clock(M.duration(job, now))
	local function badge(kind, icon, icon_hl, extra)
		local out = {
			kind = kind,
			icon = icon,
			icon_hl = icon_hl,
			border = "solid",
			border_hl = "AtlasBorder",
			right_text = duration,
			right_hl = HL.dim,
		}
		for k, v in pairs(extra or {}) do
			out[k] = v
		end
		return out
	end

	if job.manual and (s == "manual" or PENDING[s]) then
		if s == "manual" and job.playable ~= false then
			return badge("manual", "▶", HL.warning, { border = "dashed", border_hl = HL.warning, right_text = "" })
		end
		return badge("blocked", "⏸", HL.dim, {
			border = "dashed",
			border_hl = HL.dim,
			name_hl = HL.dim,
			right_text = "blocked",
		})
	end
	if s == "success" then
		return badge("success", "✓", HL.success)
	elseif s == "running" then
		return badge("running", "◐", HL.running, { right_hl = HL.running })
	elseif s == "failed" then
		if job.allow_failure then
			return badge("allowed_failure", "!", HL.warning)
		end
		return badge("failed", "✗", HL.failed)
	elseif s == "canceled" or s == "canceling" then
		return badge("canceled", "⊘", HL.dim, { name_hl = HL.dim })
	elseif s == "skipped" then
		return badge("skipped", "»", HL.dim, { name_hl = HL.dim })
	elseif s == "manual" then
		return badge("manual", "▶", HL.warning, { border = "dashed", border_hl = HL.warning, right_text = "" })
	elseif PENDING[s] then
		return badge("pending", "◷", HL.warning)
	end
	return badge("unknown", "?", HL.dim)
end

---@class AtlasPipelineStageSummary
---@field name_hl string
---@field icon string|nil
---@field icon_hl string|nil
---@field right_text string
---@field kind string

--- Wall-clock span of a stage: earliest job start to latest job finish (or now).
---@param jobs table[]
---@param now integer
---@return number|nil
local function stage_span(jobs, now)
	local first, last
	for _, job in ipairs(jobs or {}) do
		local started = utils.iso_epoch(job.started_at)
		if started then
			local finished = utils.iso_epoch(job.finished_at) or (M.is_active(job.status) and now or nil)
			first = first and math.min(first, started) or started
			if finished then
				last = last and math.max(last, finished) or finished
			end
		end
	end
	if first == nil or last == nil then
		return nil
	end
	return math.max(0, last - first)
end

--- Stage header (§3): name colour, status glyph and the right-hand text.
---@param stage { status: string|nil, jobs: table[]|nil }
---@param now integer
---@return AtlasPipelineStageSummary
function M.stage_summary(stage, now)
	local s = M.normalize(stage.status)
	local span = M.clock(stage_span(stage.jobs, now))
	if s == "running" or s == "canceling" then
		return { kind = "running", name_hl = HL.running, icon = "◐", icon_hl = HL.running, right_text = "running" }
	elseif s == "manual" then
		return { kind = "manual", name_hl = HL.warning, right_text = "manual" }
	elseif s == "success" then
		return { kind = "success", name_hl = "AtlasTextBright", icon = "✓", icon_hl = HL.success, right_text = span }
	elseif s == "failed" then
		return { kind = "failed", name_hl = "AtlasTextBright", icon = "✗", icon_hl = HL.failed, right_text = span }
	elseif s == "canceled" then
		return { kind = "canceled", name_hl = HL.dim, icon = "⊘", icon_hl = HL.dim, right_text = span }
	elseif s == "skipped" then
		return { kind = "skipped", name_hl = HL.dim, icon = "»", icon_hl = HL.dim, right_text = "" }
	end
	return { kind = "pending", name_hl = "AtlasTextBright", icon = "◷", icon_hl = HL.warning, right_text = "pending" }
end

return M
