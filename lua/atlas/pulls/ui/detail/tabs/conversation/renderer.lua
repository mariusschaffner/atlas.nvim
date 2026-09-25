local M = {}

local keymaps = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local spinner = require("atlas.ui.components.spinner")
local bordered_box = require("atlas.ui.components.bordered_box")
local comment_box = require("atlas.pulls.ui.components.comment_box")
local icons = require("atlas.ui.shared.icons")
local highlights = require("atlas.ui.shared.highlights")
local threads = require("atlas.ui.components.threadsv2")
local review_threads = require("atlas.pulls.ui.components.review_threads")
local activity_component = require("atlas.pulls.ui.detail.components.activity")
local state = require("atlas.pulls.ui.detail.tabs.conversation.state")
local detail = require("atlas.pulls.ui.detail.state")
local actions = require("atlas.pulls.ui.detail.tabs.conversation.actions")
local presentation = require("atlas.pulls.ui.presentation")

local PADDING_X = 1
local PADDING = string.rep(" ", PADDING_X)
local CONNECTOR = "│"
local INDENT_STEP = 2
local MIN_BOX_WIDTH = 20

---@param name string|nil
---@return string
local function author_hl(name)
	local normalized = name and vim.trim(name):lower() or ""
	if normalized == "" or normalized == "unknown" or normalized == "none" then
		return "AtlasTextMutedItalic"
	end
	return highlights.dynamic_for(normalized) or "AtlasTextMuted"
end

---@param lines string[]
---@param spans table[]
local function append_connector(lines, spans)
	local connector_line = PADDING .. CONNECTOR
	table.insert(lines, connector_line)
	table.insert(spans, {
		line = #lines - 1,
		start_col = PADDING_X,
		end_col = PADDING_X + #CONNECTOR,
		hl_group = "AtlasTextMuted",
	})
end

---@param dst_lines string[]
---@param dst_spans table[]
---@param src_lines string[]
---@param src_spans table[]
local function splice(dst_lines, dst_spans, src_lines, src_spans)
	local offset = #dst_lines
	for _, line in ipairs(src_lines) do
		table.insert(dst_lines, line)
	end
	for _, span in ipairs(src_spans) do
		span.line = span.line + offset
		table.insert(dst_spans, span)
	end
end

---@param node AtlasReviewThreadNode
---@return integer
local function descendant_count(node)
	local count = #node.children
	for _, child in ipairs(node.children) do
		count = count + descendant_count(child)
	end
	return count
end

---@param node AtlasReviewThreadNode
---@param depth integer
---@param out PullsConversationNavigableEntry[]
local function collect_navigable(node, depth, out)
	if node.comment.is_task then
		table.insert(out, { id = "task:" .. tostring(node.comment.id), kind = "task", entity = node.comment })
		return
	end
	table.insert(out, { id = "comment:" .. tostring(node.comment.id), kind = "comment", entity = node.comment })
	local collapsed_here = depth == 0 and #node.children > 0 and state.is_collapsed(node.comment.id)
	if not collapsed_here then
		for _, child in ipairs(node.children) do
			collect_navigable(child, depth + 1, out)
		end
	end
end

local build_hint = comment_box.build_hint

---@param comment PullsComment
---@return string|nil text
---@return table[]|nil highlights
local function bottom_hint_for(comment)
	local comments = detail.provider and detail.provider.capabilities.comments
	if not comments or not presentation.is_open_or_draft(detail.current_pr) then
		return nil, nil
	end

	local segments = {}
	if comments.add_comment then
		table.insert(segments, { action_id = "ui.comments.reply", label = "Reply", hl = "AtlasFooterInfo" })
	end
	local own = actions.is_own_comment(comment)
	if own and comments.edit_comment then
		table.insert(segments, { action_id = "ui.comments.edit", label = "Edit", hl = "AtlasFooterWarning" })
	end
	if own and comments.delete_comment then
		table.insert(segments, { action_id = "ui.delete", label = "Delete", hl = "AtlasFooterError" })
	end
	return build_hint(segments)
end

--- Shown on a comment's own bottom border while it is being inline-edited,
--- and on the composing box while adding/replying.
---@return string text
---@return table[] highlights
local function editing_hint()
	local hl = "AtlasFieldBoxBorderEditing"
	return build_hint({
		{ action_id = "ui.submit", label = "Save", hl = hl },
		{ action_id = "ui.field_edit.close", label = "Cancel", hl = hl },
	})
end

---@param box_lines string[]
---@param box_highlights table[]
---@param indent integer
local function apply_indent(box_lines, box_highlights, indent)
	if indent <= 0 then
		return
	end
	local pad = string.rep(" ", indent)
	for i, line in ipairs(box_lines) do
		box_lines[i] = pad .. line
	end
	for _, span in ipairs(box_highlights) do
		span.start_col = span.start_col + indent
		span.end_col = span.end_col + indent
	end
end

---@param comment PullsComment
---@param depth integer
---@param width integer
---@param lines string[]
---@param spans table[]
---@param line_map table<integer, table>
---@param extra_content_lines string[]|nil
---@param extra_content_highlights table[]|nil
local function render_comment_box(
	comment,
	depth,
	width,
	lines,
	spans,
	line_map,
	extra_content_lines,
	extra_content_highlights
)
	local id = tostring(comment.id)

	local reaction_options = detail.provider
		and detail.provider.capabilities.comments
		and detail.provider.capabilities.comments.reaction_options

	local is_editing = state.editing_id == id
	local is_active = state.composing == nil and state.active_id == ("comment:" .. id)
	local border_hl = is_editing and "AtlasFieldBoxBorderEditing"
		or (is_active and "AtlasFieldBoxBorderEditable")
		or "AtlasFieldBoxBorder"

	local bottom_hint, bottom_hint_highlights
	if is_editing then
		bottom_hint, bottom_hint_highlights = editing_hint()
	elseif is_active then
		bottom_hint, bottom_hint_highlights = bottom_hint_for(comment)
	end

	local fold_keys = keymaps.resolve("ui.toggle_fold")
	local box_lines, box_highlights, region = comment_box.render({
		comment = comment,
		depth = depth,
		padding_x = PADDING_X,
		width = width,
		reaction_options = reaction_options,
		max_lines = state.comment_max_lines(comment),
		fold_key = fold_keys and fold_keys[1],
		border_hl = border_hl,
		bottom_hint = bottom_hint,
		bottom_hint_highlights = bottom_hint_highlights,
		extra_content_lines = extra_content_lines,
		extra_content_highlights = extra_content_highlights,
	})

	local base = #lines
	-- Points at just the raw editable body (skipping the date line above it
	-- and any truncation-indicator/reactions rows below it), so the inline
	-- edit overlay lands exactly on the body text.
	state.regions["comment:" .. id] = {
		row = base + region.row,
		col = region.col,
		width = region.width,
		height = region.height,
	}

	for _, line in ipairs(box_lines) do
		table.insert(lines, line)
	end
	for _, span in ipairs(box_highlights) do
		table.insert(
			spans,
			{ line = base + span.line, start_col = span.start_col, end_col = span.end_col, hl_group = span.hl_group }
		)
	end
	for i = 1, #box_lines do
		line_map[base + i] = { comment = comment, entity_kind = "comment" }
	end
end

---@param width integer
---@param depth integer
---@param lines string[]
---@param spans table[]
local function render_composing_box(width, depth, lines, spans)
	local composing = state.composing
	if not composing then
		return
	end

	local title = "New Comment"
	local title_highlights = nil
	local current_user = require("atlas.pulls.state").current_user
	if current_user and current_user.name and current_user.name ~= "" then
		title = current_user.name
		title_highlights = { { start_col = 0, end_col = #title, hl_group = author_hl(title) } }
	end

	local indent = PADDING_X + depth * INDENT_STEP
	local available = math.max(MIN_BOX_WIDTH, width - indent)
	local box_width = comment_box.box_width(available)
	local content_lines = { "", "", "" }
	local bottom_hint, bottom_hint_highlights = editing_hint()

	local box_lines, box_highlights = bordered_box.render({
		width = box_width,
		box_width = box_width,
		title = title,
		title_highlights = title_highlights,
		content_lines = content_lines,
		border_hl = "AtlasFieldBoxBorderEditing",
		bottom_hint = bottom_hint,
		bottom_hint_highlights = bottom_hint_highlights,
	})
	apply_indent(box_lines, box_highlights, indent)

	local base = #lines
	state.regions.composing = { row = base + 1, col = indent + 1, width = box_width - 2, height = #content_lines }

	for _, line in ipairs(box_lines) do
		table.insert(lines, line)
	end
	for _, span in ipairs(box_highlights) do
		table.insert(
			spans,
			{ line = base + span.line, start_col = span.start_col, end_col = span.end_col, hl_group = span.hl_group }
		)
	end
end

---@param node AtlasReviewThreadNode
---@param width integer
---@param lines string[]
---@param spans table[]
---@param line_map table<integer, table>
local function render_task_entry(node, width, lines, spans, line_map)
	local comment = node.comment
	local id = "task:" .. tostring(comment.id)
	local provider = detail.provider
	local comments = provider and provider.capabilities.comments
	local fold_keys = keymaps.resolve("ui.toggle_fold")
	local fold_key = fold_keys and fold_keys[1]

	local base = #lines
	local task_lines, task_spans, task_line_map = review_threads.render_task_compact(node, width, {
		padding_x = PADDING_X,
		reaction_options = comments and comments.reaction_options,
		content_max_lines = fold_key and state.comment_max_lines or nil,
		content_truncated_key = fold_key,
	})
	splice(lines, spans, task_lines, task_spans)
	for lnum, item in pairs(task_line_map or {}) do
		line_map[base + lnum] = item
	end

	state.regions[id] =
		{ row = base, col = PADDING_X, width = math.max(1, width - PADDING_X * 2), height = math.max(1, #task_lines) }

	if state.active_id == id then
		for i = 0, #task_lines - 1 do
			table.insert(spans, { line = base + i, line_hl_group = "CursorLine" })
		end
	end
end

---@param node AtlasReviewThreadNode
---@param depth integer
---@param width integer
---@param lines string[]
---@param spans table[]
---@param line_map table<integer, table>
local function render_thread_node(node, depth, width, lines, spans, line_map)
	if node.comment.is_task then
		if #lines > 0 then
			append_connector(lines, spans)
		end
		render_task_entry(node, width, lines, spans, line_map)
		return
	end

	local collapsed_here = depth == 0 and #node.children > 0 and state.is_collapsed(node.comment.id)

	local extra_lines, extra_highlights
	if collapsed_here then
		local count = descendant_count(node)
		local text = string.format("%d %s (za to expand)", count, count == 1 and "reply" or "replies")
		extra_lines = { text }
		extra_highlights = { { line = 0, start_col = 0, end_col = #text, hl_group = "AtlasLogInfo" } }
	end

	if #lines > 0 then
		append_connector(lines, spans)
	end
	render_comment_box(node.comment, depth, width, lines, spans, line_map, extra_lines, extra_highlights)

	if not collapsed_here then
		for _, child in ipairs(node.children) do
			render_thread_node(child, depth + 1, width, lines, spans, line_map)
		end
		local composing = state.composing
		if
			composing
			and composing.kind == "reply"
			and composing.parent
			and tostring(composing.parent.id) == tostring(node.comment.id)
		then
			append_connector(lines, spans)
			render_composing_box(width, depth + 1, lines, spans)
		end
	end
end

---@param line_map table<integer, table>
---@param item PullsConversationItem
local function attach_item(line_map, item)
	for _, entry in pairs(line_map) do
		entry.conversation_item = item
		entry.entity_kind = item.kind
	end
end

-- Timeline

---@class PullsConversationTimelineEntry
---@field type "comment"|"review"|"activity_run"
---@field timestamp string
---@field thread AtlasReviewThreadNode|nil
---@field item PullsConversationItem|nil
---@field items PullsConversationItem[]|nil

---@param items PullsConversationItem[]
---@return PullsConversationTimelineEntry[]
local function build_timeline(items)
	local mixed = {}
	local comments = {}
	for _, item in ipairs(items) do
		if item.kind == "comment" then
			---@type PullsComment
			local comment = item.entity
			table.insert(comments, comment)
		else
			table.insert(mixed, {
				kind = item.kind,
				timestamp = item.created_on,
				item = item,
			})
		end
	end
	for _, thread in ipairs(review_threads.group_comments(comments)) do
		table.insert(mixed, {
			kind = "comment",
			timestamp = thread.comment.created_on or "",
			thread = thread,
		})
	end
	table.sort(mixed, function(a, b)
		local ta, tb = tostring(a.timestamp), tostring(b.timestamp)
		if ta == tb then
			return a.kind == "activity" and b.kind ~= "activity"
		end
		return ta < tb
	end)
	local entries, run = {}, {}
	local function flush_run()
		if #run > 0 then
			table.insert(entries, { type = "activity_run", timestamp = run[1].created_on, items = run })
			run = {}
		end
	end
	for _, item in ipairs(mixed) do
		if item.kind == "activity" then
			table.insert(run, item.item)
		else
			flush_run()
			if item.kind == "review" then
				table.insert(entries, { type = item.kind, timestamp = item.timestamp, item = item.item })
			else
				table.insert(entries, {
					type = "comment",
					timestamp = item.timestamp,
					thread = item.thread,
				})
			end
		end
	end
	flush_run()
	return entries
end

-- Render

---@param review PullsReviewHistoryEntry
---@return string, string, string
local function review_status(review)
	local icon, hl = icons.pulls("activity")
	local label = "left a review"
	if review.state == "approved" then
		icon, hl = icons.pulls_status("successful")
		label = "approved"
	elseif review.state == "changes_requested" then
		icon, hl = icons.pulls_status("failed")
		label = "requested changes"
	elseif review.state == "dismissed" then
		if review.previous_state == "approved" then
			icon = icons.pulls_status("successful")
			hl = "AtlasTextMuted"
			label = "previously approved"
		elseif review.previous_state == "changes_requested" then
			icon = icons.pulls_status("failed")
			hl = "AtlasTextMuted"
			label = "previously requested changes"
		else
			icon, hl = icons.pulls_status("stopped")
			label = "dismissed"
		end
	end
	return icon, hl, label
end

---@param item PullsConversationItem
---@param width integer
---@param has_next boolean
local function render_review(item, width, has_next)
	---@type PullsReviewHistoryEntry
	local review = item.entity
	local icon, icon_hl, label = review_status(review)
	local timestamp = utils.relative_time(review.submitted_on)
	local additional = timestamp ~= "" and (label .. "  " .. timestamp) or label
	local body = utils.strip_markup(review.body)
	local lines, spans, line_map = threads.render(
		{
			{
				icon = icon,
				icon_hl = icon_hl,
				author = review.author and (review.author.nickname or review.author.name) or "Unknown",
				additional = additional,
				content = body ~= "" and body or nil,
			},
		},
		width,
		{
			padding_x = PADDING_X,
			content_prefix = has_next and "│ " or "  ",
			additional_hl = function(_, text)
				local hl_list = {
					{ start_col = 0, end_col = math.min(#label, #text), hl_group = icon_hl },
				}
				local time_start = #label + 2
				if time_start < #text then
					table.insert(hl_list, {
						start_col = time_start,
						end_col = #text,
						hl_group = "AtlasTextMuted",
					})
				end
				return hl_list
			end,
		}
	)
	attach_item(line_map, item)
	return lines, spans, line_map
end

---@param item PullsConversationItem
---@param width integer
---@param has_next boolean
---@param lines string[]
---@param spans table[]
---@param line_map table<integer, table>
local function render_review_entry(item, width, has_next, lines, spans, line_map)
	---@type PullsReviewHistoryEntry
	local review_entry = item.entity
	local id = "review:" .. tostring(review_entry.id or review_entry.submitted_on or "")

	if #lines > 0 then
		append_connector(lines, spans)
	end
	local base = #lines
	local r_lines, r_spans, r_map = render_review(item, width, has_next)
	splice(lines, spans, r_lines, r_spans)
	for lnum, data in pairs(r_map or {}) do
		line_map[base + lnum] = data
	end

	state.regions[id] =
		{ row = base, col = PADDING_X, width = math.max(1, width - PADDING_X * 2), height = math.max(1, #r_lines) }
	if state.active_id == id then
		for i = 0, #r_lines - 1 do
			table.insert(spans, { line = base + i, line_hl_group = "CursorLine" })
		end
	end
end

---@param entry PullsConversationTimelineEntry
---@param width integer
---@param has_next boolean
---@param lines string[]
---@param spans table[]
---@param line_map table<integer, table>
local function render_entry(entry, width, has_next, lines, spans, line_map)
	if entry.type == "comment" then
		render_thread_node(entry.thread, 0, width, lines, spans, line_map)
		return
	elseif entry.type == "review" and entry.item then
		render_review_entry(entry.item, width, has_next, lines, spans, line_map)
		return
	elseif entry.type == "activity_run" then
		local run_id = tostring(entry.timestamp or "")
		local activities = {}
		for _, item in ipairs(entry.items or {}) do
			---@type PullsActivityEntry
			local activity = item.entity
			table.insert(activities, activity)
		end
		if #lines > 0 then
			append_connector(lines, spans)
		end
		local a_lines, a_spans, a_map = activity_component.render(activities, width, {
			padding_x = PADDING_X,
			squash = not state.is_run_expanded(run_id),
			run_id = run_id,
			has_next = has_next,
		})
		local base = #lines
		splice(lines, spans, a_lines, a_spans)
		for lnum, item in pairs(a_map or {}) do
			line_map[base + lnum] = item
		end
	end
end

---@param _pr PullRequest
---@param _details PullRequestDetails|nil
---@param width integer
function M.render(_pr, _details, width)
	local lines, spans, line_map = {}, {}, {}

	if state.error then
		utils.push(lines, spans, state.error, "AtlasLogError", PADDING_X)
		return lines, spans, line_map
	end

	if state.items == nil then
		return lines, spans, line_map
	end
	if state.items == "loading" then
		utils.push(lines, spans, spinner.with_text("Loading conversation..."), "AtlasTextMuted", PADDING_X)
		return lines, spans, line_map
	end

	---@cast state.items PullsConversationItem[]
	local items = state.items
	local entries = build_timeline(items)

	-- Rebuilt from the same `entries` used for rendering, so navigation
	-- never diverges from what's actually on screen.
	local navigable = {}
	for _, entry in ipairs(entries) do
		if entry.type == "comment" and entry.thread then
			collect_navigable(entry.thread, 0, navigable)
		elseif entry.type == "review" and entry.item then
			---@type PullsReviewHistoryEntry
			local review_entry = entry.item.entity
			table.insert(navigable, {
				id = "review:" .. tostring(review_entry.id or review_entry.submitted_on or ""),
				kind = "review",
				entity = review_entry,
			})
		end
	end
	state.set_navigable(navigable)

	if #entries == 0 and state.composing == nil then
		utils.push(lines, spans, "No conversation yet.", "AtlasTextMuted", PADDING_X)
		return lines, spans, line_map
	end

	for index, entry in ipairs(entries) do
		render_entry(entry, width, index < #entries, lines, spans, line_map)
	end

	if state.composing and state.composing.kind == "add" then
		if #lines > 0 then
			append_connector(lines, spans)
		end
		render_composing_box(width, 0, lines, spans)
	end

	return lines, spans, line_map
end

return M
