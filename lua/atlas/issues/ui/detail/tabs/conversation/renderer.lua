local M = {}

local keymaps = require("atlas.core.keymaps")
local utils = require("atlas.ui.shared.utils")
local spinner = require("atlas.ui.components.spinner")
local bordered_box = require("atlas.ui.components.bordered_box")
local emojis = require("atlas.ui.shared.emojis")
local comment_threads = require("atlas.issues.ui.components.comment_threads")
local activity_component = require("atlas.issues.ui.detail.components.activity")
local presentation = require("atlas.issues.ui.presentation")
local detail = require("atlas.issues.ui.detail.state")
local state = require("atlas.issues.ui.detail.tabs.conversation.state")
local actions = require("atlas.issues.ui.detail.tabs.conversation.actions")

local PADDING_X = 1
local PADDING = string.rep(" ", PADDING_X)
local CONTENT_PAD = " "
local CONNECTOR = "│"
local INDENT_STEP = 2

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

---@param node IssuesCommentThreadNode
---@return integer
local function descendant_count(node)
	local count = #node.children
	for _, child in ipairs(node.children) do
		count = count + descendant_count(child)
	end
	return count
end

---@param node IssuesCommentThreadNode
---@param depth integer
---@param out IssuesConversationNavigableEntry[]
local function collect_navigable(node, depth, out)
	table.insert(out, { id = tostring(node.comment.id), comment = node.comment })
	local collapsed_here = depth == 0 and #node.children > 0 and state.is_collapsed(node.comment.id)
	if not collapsed_here then
		for _, child in ipairs(node.children) do
			collect_navigable(child, depth + 1, out)
		end
	end
end

---@param comment IssueComment
---@param reaction_options IssueReactionOption[]|nil
---@return string[] lines
---@return table[] highlights
local function comment_content(comment, reaction_options)
	local lines, highlights = {}, {}
	local date_text = utils.format_date(comment.created)
	if date_text ~= "" then
		table.insert(lines, date_text)
		table.insert(highlights, { line = 0, start_col = 0, end_col = #date_text, hl_group = "AtlasTextMuted" })
	end

	if comment.deleted then
		local text = "(deleted comment)"
		table.insert(lines, text)
		table.insert(highlights, { line = #lines - 1, start_col = 0, end_col = #text, hl_group = "AtlasTextMutedItalic" })
		return lines, highlights
	end

	local body_lines = utils.sanitize_lines(utils.strip_markup(comment.body or ""))
	while #body_lines > 0 and vim.trim(body_lines[#body_lines]) == "" do
		table.remove(body_lines)
	end
	if #body_lines == 0 then
		body_lines = { "(empty comment)" }
	end

	local max_lines = state.comment_max_lines(comment)
	local truncated = max_lines ~= nil and #body_lines > max_lines
	local visible_count = truncated and max_lines or #body_lines
	for i = 1, visible_count do
		table.insert(lines, body_lines[i])
	end
	if truncated then
		local fold_keys = keymaps.resolve("ui.toggle_fold")
		local key = fold_keys and fold_keys[1]
		local text = key and string.format("... (%s to expand)", key) or "..."
		table.insert(lines, text)
		table.insert(highlights, { line = #lines - 1, start_col = 0, end_col = #text, hl_group = "AtlasTextMuted" })
	end

	local reactions_text, reaction_highlights = emojis.format(comment.reactions, reaction_options)
	if reactions_text ~= "" then
		table.insert(lines, reactions_text)
		local line_idx = #lines - 1
		for _, span in ipairs(reaction_highlights) do
			table.insert(
				highlights,
				{ line = line_idx, start_col = span.start_col, end_col = span.end_col, hl_group = span.hl_group }
			)
		end
	end

	return lines, highlights
end

---@param comment IssueComment
---@return string|nil text
---@return table[]|nil highlights
local function bottom_hint_for(comment)
	local comments = detail.provider and detail.provider.capabilities.comments
	if not comments then
		return nil, nil
	end

	local parts, highlights, cursor = {}, {}, 0
	---@param action_id string
	---@param label string
	---@param hl string
	local function add_segment(action_id, label, hl)
		if #parts > 0 then
			local sep = " ── "
			table.insert(parts, sep)
			cursor = cursor + #sep
		end
		local segment = utils.field_hint_label(action_id, label, true)
		table.insert(highlights, { start_col = cursor, end_col = cursor + #segment, hl_group = hl })
		table.insert(parts, segment)
		cursor = cursor + #segment
	end

	if comments.add_comment or comments.reply_comment then
		add_segment("ui.comments.reply", "Reply", "AtlasFooterInfo")
	end
	local own = actions.is_own_comment(comment)
	if own and comments.edit_comment then
		add_segment("ui.comments.edit", "Edit", "AtlasFooterWarning")
	end
	if own and comments.delete_comment then
		add_segment("ui.delete", "Delete", "AtlasFooterError")
	end

	if #parts == 0 then
		return nil, nil
	end
	return table.concat(parts), highlights
end

---@param comment IssueComment
---@return string title
---@return table[] title_highlights Spans relative to `title`, coloring the whole (name-only) title.
local function title_for(comment)
	local name = comment_threads.author_name(comment.author)
	return name, { { start_col = 0, end_col = #name, hl_group = presentation.person_hl(name) } }
end

--- Adds a space of horizontal padding on every content line, so the border
--- isn't flush against the text.
---@param lines string[]
---@param highlights table[]
---@return string[] lines
---@return table[] highlights
local function frame_content(lines, highlights)
	local framed_lines = {}
	for _, line in ipairs(lines) do
		table.insert(framed_lines, CONTENT_PAD .. line)
	end

	local framed_highlights = {}
	for _, span in ipairs(highlights) do
		table.insert(framed_highlights, {
			line = span.line,
			start_col = span.start_col + #CONTENT_PAD,
			end_col = span.end_col + #CONTENT_PAD,
			hl_group = span.hl_group,
		})
	end
	return framed_lines, framed_highlights
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

---@param comment IssueComment
---@param depth integer
---@param width integer
---@param lines string[]
---@param spans table[]
---@param line_map table<integer, table>
---@param extra_content_lines string[]|nil
---@param extra_content_highlights table[]|nil
local function render_comment_box(comment, depth, width, lines, spans, line_map, extra_content_lines, extra_content_highlights)
	local id = tostring(comment.id)
	local reaction_options = detail.provider and detail.provider.capabilities.comments and detail.provider.capabilities.comments.reaction_options
	local content_lines, content_highlights = comment_content(comment, reaction_options)
	for _, line in ipairs(extra_content_lines or {}) do
		table.insert(content_lines, line)
	end
	for _, span in ipairs(extra_content_highlights or {}) do
		table.insert(content_highlights, span)
	end

	local is_editing = state.editing_id == id
	local is_active = state.composing == nil and state.active_id == id
	local border_hl = is_editing and "AtlasFieldBoxBorderEditing"
		or (is_active and "AtlasFieldBoxBorderEditable")
		or "AtlasFieldBoxBorder"

	local bottom_hint, bottom_hint_highlights
	if is_active and not is_editing then
		bottom_hint, bottom_hint_highlights = bottom_hint_for(comment)
	end

	local indent = depth * INDENT_STEP
	local box_width = math.max(20, width - indent)
	local title, title_highlights = title_for(comment)
	local framed_lines, framed_highlights = frame_content(content_lines, content_highlights)

	local box_lines, box_highlights = bordered_box.render({
		width = box_width,
		box_width = box_width,
		title = title,
		title_highlights = title_highlights,
		content_lines = framed_lines,
		content_highlights = framed_highlights,
		border_hl = border_hl,
		bottom_hint = bottom_hint,
		bottom_hint_highlights = bottom_hint_highlights,
	})
	apply_indent(box_lines, box_highlights, indent)

	local base = #lines
	state.regions["comment:" .. id] = { row = base + 1, col = indent + 1, width = box_width - 2, height = #framed_lines }

	for _, line in ipairs(box_lines) do
		table.insert(lines, line)
	end
	for _, span in ipairs(box_highlights) do
		table.insert(spans, { line = base + span.line, start_col = span.start_col, end_col = span.end_col, hl_group = span.hl_group })
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
	local current_user = require("atlas.issues.state").current_user
	if current_user and current_user.display_name and current_user.display_name ~= "" then
		title = current_user.display_name
		title_highlights = { { start_col = 0, end_col = #title, hl_group = presentation.person_hl(title) } }
	end

	local indent = depth * INDENT_STEP
	local box_width = math.max(20, width - indent)
	local content_lines = { "", "", "" }

	local box_lines, box_highlights = bordered_box.render({
		width = box_width,
		box_width = box_width,
		title = title,
		title_highlights = title_highlights,
		content_lines = content_lines,
		border_hl = "AtlasFieldBoxBorderEditing",
	})
	apply_indent(box_lines, box_highlights, indent)

	local base = #lines
	state.regions.composing = { row = base + 1, col = indent + 1, width = box_width - 2, height = #content_lines }

	for _, line in ipairs(box_lines) do
		table.insert(lines, line)
	end
	for _, span in ipairs(box_highlights) do
		table.insert(spans, { line = base + span.line, start_col = span.start_col, end_col = span.end_col, hl_group = span.hl_group })
	end
end

---@param node IssuesCommentThreadNode
---@param depth integer
---@param width integer
---@param lines string[]
---@param spans table[]
---@param line_map table<integer, table>
local function render_thread_node(node, depth, width, lines, spans, line_map)
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
		if composing and composing.kind == "reply" and composing.parent and tostring(composing.parent.id) == tostring(node.comment.id) then
			append_connector(lines, spans)
			render_composing_box(width, depth + 1, lines, spans)
		end
	end
end

---@class IssuesConversationTimelineEntry
---@field type "comment"|"activity_run"
---@field timestamp string
---@field thread IssuesCommentThreadNode|nil
---@field items IssueConversationItem[]|nil

---@param items IssueConversationItem[]
---@return IssuesConversationTimelineEntry[]
local function build_timeline(items)
	local mixed = {}
	local comments = {}
	for _, item in ipairs(items) do
		if item.kind == "comment" then
			table.insert(comments, item.entity)
		else
			table.insert(mixed, { kind = "activity", timestamp = item.created_at, item = item })
		end
	end
	for _, thread in ipairs(comment_threads.group_comments(comments)) do
		table.insert(mixed, { kind = "comment", timestamp = thread.comment.created or "", thread = thread })
	end
	table.sort(mixed, function(left, right)
		local left_time = tostring(left.timestamp)
		local right_time = tostring(right.timestamp)
		if left_time == right_time then
			return left.kind == "activity" and right.kind ~= "activity"
		end
		return left_time < right_time
	end)

	local entries = {}
	local run = {}
	local function flush_run()
		if #run > 0 then
			table.insert(entries, { type = "activity_run", timestamp = run[1].created_at, items = run })
			run = {}
		end
	end
	for _, item in ipairs(mixed) do
		if item.kind == "activity" then
			---@type IssueActivityEntry
			local activity = item.item.entity
			if activity.always_render then
				flush_run()
				table.insert(entries, { type = "activity_run", timestamp = item.timestamp, items = { item.item } })
			else
				table.insert(run, item.item)
			end
		else
			flush_run()
			table.insert(entries, { type = "comment", timestamp = item.timestamp, thread = item.thread })
		end
	end
	flush_run()
	return entries
end

---@param entry IssuesConversationTimelineEntry
---@param width integer
---@param has_next boolean
---@param lines string[]
---@param spans table[]
---@param line_map table<integer, table>
local function render_entry(entry, width, has_next, lines, spans, line_map)
	if entry.type == "comment" then
		render_thread_node(entry.thread, 0, width, lines, spans, line_map)
		return
	end
	if entry.type == "activity_run" then
		local run_id = tostring(entry.timestamp or "")
		local activities = {}
		for _, item in ipairs(entry.items or {}) do
			table.insert(activities, item.entity)
		end
		local activity_lines, activity_spans, activity_line_map = activity_component.render(activities, width, {
			padding_x = PADDING_X,
			squash = not state.is_run_expanded(run_id),
			run_id = run_id,
			has_next = has_next,
		})
		if #lines > 0 then
			append_connector(lines, spans)
		end
		splice(lines, spans, activity_lines, activity_spans)
		local base = #lines - #activity_lines
		for lnum, item in pairs(activity_line_map or {}) do
			line_map[base + lnum] = item
		end
	end
end

---@param _issue Issue
---@param _details IssueDetails|nil
---@param width integer
function M.render(_issue, _details, width)
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

	---@cast state.items IssueConversationItem[]
	local navigable = {}
	for _, thread in ipairs(comment_threads.group_comments(state.comments())) do
		collect_navigable(thread, 0, navigable)
	end
	state.set_navigable(navigable)

	local entries = build_timeline(state.items)

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
