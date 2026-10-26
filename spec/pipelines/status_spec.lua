local status = require("atlas.pipelines.status")

local NOW = 1761480000 -- 2025-10-26T12:00:00Z

describe("atlas.pipelines.status", function()
	describe("pipeline_pill", function()
		local cases = {
			{ "running", "◐", "Running", "AtlasGLPipelineRunningPillChip" },
			{ "RUNNING", "◐", "Running", "AtlasGLPipelineRunningPillChip" },
			{ "canceling", "◐", "Running", "AtlasGLPipelineRunningPillChip" },
			{ "pending", "◷", "Pending", "AtlasGLPipelinePendingPillChip" },
			{ "created", "◷", "Pending", "AtlasGLPipelinePendingPillChip" },
			{ "waiting_for_resource", "◷", "Pending", "AtlasGLPipelinePendingPillChip" },
			{ "success", "✓", "Passed", "AtlasGLPipelinePassedPillChip" },
			{ "failed", "✗", "Failed", "AtlasGLPipelineFailedPillChip" },
			{ "canceled", "⊘", "Canceled", "AtlasGLPipelineCanceledPillChip" },
			{ "skipped", "⊘", "Canceled", "AtlasGLPipelineCanceledPillChip" },
			{ "manual", "▶", "Manual", "AtlasGLPipelineManualPillChip" },
		}
		for _, case in ipairs(cases) do
			it("maps " .. case[1], function()
				local pill = status.pipeline_pill(case[1])
				assert.are.same({ case[2], case[3], case[4] }, { pill.icon, pill.label, pill.hl })
			end)
		end

		it("uses the state colour for running/success/failed/manual/canceled", function()
			assert.equal("AtlasCyan", status.pipeline_pill("running").color)
			assert.equal("AtlasGreen", status.pipeline_pill("success").color)
			assert.equal("AtlasRed", status.pipeline_pill("failed").color)
			assert.equal("AtlasYellow", status.pipeline_pill("manual").color)
			assert.equal("AtlasYellow", status.pipeline_pill("pending").color)
			assert.equal("AtlasTextMuted", status.pipeline_pill("canceled").color)
		end)
	end)

	describe("is_active", function()
		it("is true only while GitLab can still move the pipeline on", function()
			for _, s in ipairs({ "created", "pending", "running", "preparing", "canceling", "scheduled" }) do
				assert.is_true(status.is_active(s), s)
			end
			for _, s in ipairs({ "success", "failed", "canceled", "skipped", "manual", "", nil }) do
				assert.is_false(status.is_active(s), tostring(s))
			end
		end)
	end)

	describe("clock", function()
		it("formats seconds, minutes and hours", function()
			assert.equal("", status.clock(nil))
			assert.equal("0s", status.clock(0))
			assert.equal("12s", status.clock(12))
			assert.equal("59s", status.clock(59.4))
			assert.equal("1:00", status.clock(60))
			assert.equal("1:02", status.clock(62))
			assert.equal("5:41", status.clock(341))
			assert.equal("1:02:03", status.clock(3723))
		end)
	end)

	describe("elapsed", function()
		it("ticks from started_at while running", function()
			local value, suffix =
				status.elapsed({ status = "running", started_at = "2025-10-26T11:56:55Z", duration = nil }, NOW)
			assert.equal("3:05", value)
			assert.equal(" elapsed", suffix)
		end)

		it("shows the final duration once finished", function()
			local value, suffix = status.elapsed({ status = "success", duration = 341 }, NOW)
			assert.equal("5:41", value)
			assert.equal(" total", suffix)
		end)

		it("is empty for a pipeline that never started", function()
			assert.is_nil((status.elapsed({ status = "created" }, NOW)))
		end)
	end)

	describe("job_badge", function()
		local function badge(job)
			job.duration = job.duration or 12
			return status.job_badge(job, NOW)
		end

		it("maps every job status", function()
			local cases = {
				{ { status = "success" }, "success", "✓", "AtlasGreen", "12s" },
				{ { status = "running", started_at = "2025-10-26T11:57:46Z", duration = nil }, "running", "◐", "AtlasCyan", "2:14" },
				{ { status = "pending" }, "pending", "◷", "AtlasYellow", "12s" },
				{ { status = "failed" }, "failed", "✗", "AtlasRed", "12s" },
				{ { status = "failed", allow_failure = true }, "allowed_failure", "!", "AtlasYellow", "12s" },
				{ { status = "canceled" }, "canceled", "⊘", "AtlasTextMuted", "12s" },
				{ { status = "skipped" }, "skipped", "»", "AtlasTextMuted", "12s" },
			}
			for _, case in ipairs(cases) do
				local b = badge(case[1])
				assert.are.same(
					{ case[2], case[3], case[4], case[5], "solid" },
					{ b.kind, b.icon, b.icon_hl, b.right_text, b.border },
					case[2]
				)
			end
		end)

		it("draws a playable manual job dashed and yellow with no right text", function()
			local b = badge({ status = "manual", manual = true, playable = true })
			assert.are.same({ "manual", "▶", "AtlasYellow", "dashed", "AtlasYellow", "" }, {
				b.kind,
				b.icon,
				b.icon_hl,
				b.border,
				b.border_hl,
				b.right_text,
			})
		end)

		it("draws a manual job that can't be played yet as blocked", function()
			for _, s in ipairs({ "created", "manual" }) do
				local b = badge({ status = s, manual = true, playable = false })
				assert.are.same({ "blocked", "⏸", "dashed", "AtlasTextMuted", "blocked" }, {
					b.kind,
					b.icon,
					b.border,
					b.border_hl,
					b.right_text,
				})
			end
		end)
	end)

	describe("stage_summary", function()
		local done_jobs = {
			{ status = "success", started_at = "2025-10-26T11:50:00Z", finished_at = "2025-10-26T11:50:12Z" },
			{ status = "success", started_at = "2025-10-26T11:50:00Z", finished_at = "2025-10-26T11:50:53Z" },
		}

		it("shows a finished stage bright with its wall-clock span", function()
			local s = status.stage_summary({ status = "success", jobs = done_jobs }, NOW)
			assert.are.same({ "AtlasTextBright", "✓", "AtlasGreen", "53s" }, { s.name_hl, s.icon, s.icon_hl, s.right_text })
		end)

		it("colours running and manual stages", function()
			local running = status.stage_summary({ status = "running", jobs = {} }, NOW)
			assert.are.same({ "AtlasCyan", "◐", "running" }, { running.name_hl, running.icon, running.right_text })
			local manual = status.stage_summary({ status = "manual", jobs = {} }, NOW)
			assert.are.same({ "AtlasYellow", nil, "manual" }, { manual.name_hl, manual.icon, manual.right_text })
		end)

		it("marks failed stages red", function()
			local s = status.stage_summary({ status = "failed", jobs = done_jobs }, NOW)
			assert.are.same({ "✗", "AtlasRed" }, { s.icon, s.icon_hl })
		end)
	end)
end)
