local M = {}

local utils = require("atlas.ui.shared.utils")
local spinner = require("atlas.ui.components.spinner")
local emojis = require("atlas.ui.shared.emojis")
local line_builder = require("atlas.ui.components.line")
local day_divider = require("atlas.ui.components.timeline.day_divider")
local event_row = require("atlas.ui.components.timeline.event_row")
local timeline_comment = require("atlas.ui.components.timeline.comment")
local frame = require("atlas.ui.components.composer.frame")
local dock = require("atlas.ui.components.composer.dock")
local comment_threads = require("atlas.issues.ui.components.comment_threads")
local events = require("atlas.issues.ui.detail.tabs.conversation.events")
local presentation = require("atlas.issues.ui.presentation")
local detail = require("atlas.issues.ui.detail.state")
local state = require("atlas.issues.ui.detail.tabs.conversation.state")
local actions = require("atlas.issues.ui.detail.tabs.conversation.actions")

local PADDING_X = 1
--- Activity runs longer than this collapse to their first/last
--- `COLLAPSE_KEEP` entries around a "⋯ N more changes" row.
local COLLAPSE_THRESHOLD = 4
local COLLAPSE_KEEP = 2

--- Finds "@handle" mentions in a single (already-wrapped) line and colors
--- them the same way an author's own name is colored (`person_hl`), keyed
--- off the handle text itself.
---@param line string
---@return table[] spans
local function mention_spans(line)
	local spans = {}
	local search_from = 1
	while true do
		local s, e, handle = line:find("@([%w_%.%-]+)", search_from)
		if not s then
			break
		end
		table.insert(spans, { start_col = s - 1, end_col = e, hl_group = presentation.person_hl(handle) })
		search_from = e + 1
	end
	return spans
end

---@param comment IssueComment
---@return string[]
local function body_lines(comment)
	if comment.deleted then
		return { "(deleted comment)" }
	end
	local lines = utils.sanitize_lines(utils.strip_markup(comment.body or ""))
	while #lines > 0 and vim.trim(lines[#lines]) == "" do
		table.remove(lines)
	end
	if #lines == 0 then
		return { "(empty comment)" }
	end
	return lines
end

---@param comment IssueComment
---@return AtlasTimelineEventSegment[]
local function thread_badges(comment)
	if not comment.resolvable then
		return {}
	end
	if comment.resolved then
		return { { "✓ resolved thread", "AtlasBadgeResolved" } }
	end
	return { { "◷ unresolved thread", "AtlasBadgeUnresolved" } }
end

---@param node IssuesCommentThreadNode
---@param depth integer
---@return AtlasTimelineCommentNode
local function to_comment_node(node, depth)
	local comment = node.comment
	local reaction_options = detail.provider
		and detail.provider.capabilities.comments
		and detail.provider.capabilities.comments.reaction_options
	local reactions_text, reactions_spans = emojis.format(comment.reactions, reaction_options)
	local children = {}
	for _, child in ipairs(node.children) do
		table.insert(children, to_comment_node(child, depth + 1))
	end
	return {
		id = tostring(comment.id),
		author = comment_threads.author_name(comment.author),
		is_you = actions.is_own_comment(comment),
		time = utils.local_time(comment.created),
		badges = depth == 0 and thread_badges(comment) or nil,
		body_lines = body_lines(comment),
		max_lines = state.comment_max_lines(comment),
		reactions_text = reactions_text,
		reactions_spans = reactions_spans and #reactions_spans > 0 and reactions_spans or nil,
		children = children,
		collapsed = depth == 0 and state.is_collapsed(comment.id),
		data = comment,
	}
end

---@param title AtlasTimelineEventSegment[]|nil
---@param hints AtlasKeyHintSegment[]
---@return AtlasTimelineComposerRender
local function composer_render(title, hints)
	return function(ctx)
		return frame.render({
			indent = ctx.indent,
			width = ctx.width,
			prefix = ctx.prefix,
			title = title,
			height = state.composer.height,
			mode = state.composer.mode,
			hints = hints,
			dirty = state.composer.dirty,
		})
	end
end

--- Footer hints of the reply composer; "post & resolve" only while the
--- thread is resolvable and still open.
---@param root IssueComment
---@return AtlasKeyHintSegment[]
function M.reply_hints(root)
	local comments = detail.provider and detail.provider.capabilities.comments
	local hints = { { action_id = "ui.submit", label = "post" } }
	if root.resolvable and not root.resolved and comments and comments.set_thread_resolved then
		table.insert(hints, { action_id = "ui.comments.submit_resolve", label = "post & resolve" })
	end
	table.insert(hints, { action_id = "ui.field_edit.close", label = "cancel" })
	return hints
end

---@type AtlasKeyHintSegment[]
M.EDIT_HINTS = {
	{ action_id = "ui.submit", label = "save" },
	{ action_id = "ui.field_edit.close", label = "discard" },
}

---@return string|nil
local function current_user_name()
	local user = require("atlas.issues.state").current_user
	return user and (user.display_name ~= "" and user.display_name or user.account_id) or nil
end

---@class IssuesConversationTimelineEntry
---@field type "comment"|"activity_run"|"day"
---@field timestamp string
---@field label string|nil Day label ("day" entries).
---@field thread IssuesCommentThreadNode|nil
---@field items IssueConversationItem[]|nil

--- Merges comment threads and activity oldest-first, cuts activity into runs
--- (broken by comments, `always_render` entries and day boundaries) and
--- inserts a "day" entry wherever the local calendar day changes.
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
	local current_day = nil
	local function flush_run()
		if #run > 0 then
			table.insert(entries, { type = "activity_run", timestamp = run[1].created_at, items = run })
			run = {}
		end
	end
	for _, item in ipairs(mixed) do
		local day = utils.local_day_key(item.timestamp)
		if day ~= current_day then
			flush_run()
			current_day = day
			table.insert(entries, { type = "day", timestamp = item.timestamp, label = utils.day_label(item.timestamp) })
		end
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

---@class IssuesConversationRenderContext
---@field lines string[]
---@field spans AtlasUIHighlight[]
---@field line_map table<integer, table>
---@field width integer

---@param ctx IssuesConversationRenderContext
local function blank(ctx)
	table.insert(ctx.lines, "")
	ctx.line_map[#ctx.lines] = { kind = "spacer" }
end

---@param ctx IssuesConversationRenderContext
---@param block_lines string[]
---@param block_spans AtlasUIHighlight[]
---@param entry table|nil line_map entry for every row of the block
---@return integer base
local function append(ctx, block_lines, block_spans, entry)
	local base = line_builder.splice(ctx.lines, ctx.spans, block_lines, block_spans)
	for i = 1, #block_lines do
		ctx.line_map[base + i] = entry or { kind = "spacer" }
	end
	return base
end

---@param ctx IssuesConversationRenderContext
---@param entry IssuesConversationTimelineEntry
local function render_activity_run(ctx, entry)
	local run_id = tostring(entry.timestamp or "")
	local items = entry.items or {}
	local function render_item(item)
		local block_lines, block_spans = event_row.render(events.to_event(item.entity), ctx.width, {
			padding_x = PADDING_X,
		})
		append(ctx, block_lines, block_spans, {
			kind = "activity",
			activity_entry = item.entity,
			activity_actor = item.entity.actor,
			run_id = run_id,
		})
	end

	if #items > COLLAPSE_THRESHOLD and not state.is_run_expanded(run_id) then
		for i = 1, COLLAPSE_KEEP do
			render_item(items[i])
		end
		local hidden = #items - COLLAPSE_KEEP * 2
		local block_lines, block_spans = event_row.render({
			icon = "⋯",
			segments = { { string.format("%d more %s", hidden, hidden == 1 and "change" or "changes"), "AtlasTimelineVerb" } },
			hints = { { action_id = "issues.expand_activity", label = "expand" } },
		}, ctx.width, { padding_x = PADDING_X })
		append(ctx, block_lines, block_spans, { kind = "activity_gap", run_id = run_id })
		for i = #items - COLLAPSE_KEEP + 1, #items do
			render_item(items[i])
		end
		return
	end
	for _, item in ipairs(items) do
		render_item(item)
	end
end

---@param ctx IssuesConversationRenderContext
---@param thread IssuesCommentThreadNode
local function render_thread(ctx, thread)
	local composing = state.composing
	local root = thread.comment
	local reply_here = composing ~= nil and tostring(composing.parent.id) == tostring(root.id)
	local block_lines, block_spans, block_map, regions = timeline_comment.render(to_comment_node(thread, 0), ctx.width, {
		padding_x = PADDING_X,
		body_spans = mention_spans,
		truncated_hints = { { action_id = "ui.toggle_fold", label = "expand" } },
		collapsed_hints = { { action_id = "ui.toggle_fold", label = "expand" } },
		editing_id = state.editing_id,
		render_editor = composer_render(nil, M.EDIT_HINTS),
		reply_parent_id = reply_here and tostring(root.id) or nil,
		reply_author = current_user_name(),
		render_reply = reply_here and composer_render({ { "↩ Reply to thread", "AtlasComposerTitle" } }, M.reply_hints(root))
			or nil,
	})
	local base = append(ctx, block_lines, block_spans)
	for lnum, entry in pairs(block_map) do
		ctx.line_map[base + lnum] = entry
	end
	for key, region in pairs(regions) do
		state.regions[key] = vim.tbl_extend("force", {}, region, { row = base + region.row })
	end
end

---@param ctx IssuesConversationRenderContext
---@param text string
---@param hl string
local function push_message(ctx, text, hl)
	utils.push(ctx.lines, ctx.spans, text, hl, PADDING_X)
	ctx.line_map[#ctx.lines] = { kind = "spacer" }
end

--- Trailing rows so the last timeline entries can scroll clear of the
--- docked composer, plus the "· NOW ·" marker right above it while it's open.
---@param ctx IssuesConversationRenderContext
local function render_dock_padding(ctx)
	local height = dock.total_height()
	if height == 0 then
		return
	end
	blank(ctx)
	if dock.is_expanded() then
		local block_lines, block_spans = day_divider.render_centered("NOW", ctx.width)
		append(ctx, block_lines, block_spans)
	end
	for _ = 1, height do
		blank(ctx)
	end
end

---@param _issue Issue
---@param _details IssueDetails|nil
---@param width integer
function M.render(_issue, _details, width)
	---@type IssuesConversationRenderContext
	local ctx = { lines = {}, spans = {}, line_map = {}, width = width }
	state.regions = {}

	if state.error then
		push_message(ctx, state.error, "AtlasLogError")
		return ctx.lines, ctx.spans, ctx.line_map
	end
	if state.items == nil then
		return ctx.lines, ctx.spans, ctx.line_map
	end
	if state.items == "loading" then
		push_message(ctx, spinner.with_text("Loading conversation..."), "AtlasTextMuted")
		return ctx.lines, ctx.spans, ctx.line_map
	end

	---@cast state.items IssueConversationItem[]
	local entries = build_timeline(state.items)
	if #entries == 0 then
		push_message(ctx, "No activity yet.", "AtlasTextMuted")
	end

	local previous = nil
	for _, entry in ipairs(entries) do
		if entry.type == "day" then
			if previous ~= nil and previous ~= "comment" then
				blank(ctx)
			end
			local block_lines, block_spans = day_divider.render(entry.label or "", width, { padding_x = PADDING_X })
			append(ctx, block_lines, block_spans)
		elseif entry.type == "comment" then
			-- Every thread is followed by a blank row; only an activity run
			-- right before it needs one added.
			if previous == "activity_run" then
				blank(ctx)
			end
			render_thread(ctx, entry.thread)
			blank(ctx)
		else
			render_activity_run(ctx, entry)
		end
		previous = entry.type
	end

	render_dock_padding(ctx)
	return ctx.lines, ctx.spans, ctx.line_map
end

return M
