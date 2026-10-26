-- UI state of the pipeline detail view. The pipeline data itself (and its
-- polling) lives in the store (`atlas.pipelines.pipeline_state`).

---@class PipelinesDetailLogState
---@field job_id string|nil Job whose trace the log buffer shows.
---@field rows AtlasPipelineLogRow[] Rows currently in the buffer.
---@field folds table<integer, boolean> Section header rows that already got a fold.
---@field follow boolean Keep the cursor on the last line as the trace grows.
---@field moving boolean A programmatic cursor move is in progress (not the user scrolling).
---@field positioned boolean The initial cursor position (end / first error) was applied.

---@class PipelinesDetailState
---@field win integer|nil
---@field buf integer|nil
---@field header_win integer|nil
---@field header_buf integer|nil
---@field provider PipelinesProvider|nil
---@field pipeline_ref Pipeline|nil What the view was opened with (shown until the store has loaded).
---@field merge_request { iid: integer|nil, title: string|nil }|nil
---@field store AtlasPipelineStore|nil
---@field unsubscribe fun()|nil
---@field focus "graph"|"log" Which part gets the keys.
---@field fullscreen boolean Graph hidden, log fills the view.
---@field viewport_first integer|nil First visible stage (horizontal scroll).
---@field return_to fun()|nil Reopens where the view was opened from, on close.
---@field log PipelinesDetailLogState
local M = {}

---@return PipelinesDetailLogState
local function new_log()
	return { job_id = nil, rows = {}, folds = {}, follow = true, moving = false, positioned = false }
end

function M.reset()
	M.win = nil
	M.buf = nil
	M.header_win = nil
	M.header_buf = nil
	M.provider = nil
	M.pipeline_ref = nil
	M.merge_request = nil
	M.store = nil
	M.unsubscribe = nil
	M.focus = "graph"
	M.fullscreen = false
	M.viewport_first = nil
	M.return_to = nil
	M.log = new_log()
end

--- Forgets the log buffer's bookkeeping (another job or pipeline is shown next).
function M.reset_log()
	M.log = new_log()
end

M.reset()

return M
