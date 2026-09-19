-- Parses/serializes the GitLab-web-UI-style filter text typed into the
-- dashboard filter bar (e.g. `label:bug assignee:me some free text`) to and
-- from the same view-shaped table the existing GitLab fetch functions
-- already understand (project/scope/labels/assignee_username/etc.).
local M = {}

---@param text string
---@return string[]
local function tokenize(text)
	local tokens = {}
	local i, len = 1, #text
	while i <= len do
		while i <= len and text:sub(i, i):match("%s") do
			i = i + 1
		end
		if i > len then
			break
		end

		local buf = {}
		while i <= len and not text:sub(i, i):match("%s") do
			local c = text:sub(i, i)
			if c == '"' then
				local close = text:find('"', i + 1, true)
				if close then
					table.insert(buf, text:sub(i + 1, close - 1))
					i = close + 1
				else
					table.insert(buf, text:sub(i + 1))
					i = len + 1
				end
			else
				local special = text:find('["%s]', i)
				local stop = (special or (len + 1)) - 1
				table.insert(buf, text:sub(i, stop))
				i = stop + 1
			end
		end
		table.insert(tokens, table.concat(buf))
	end
	return tokens
end

local KEY_ALIASES = {
	label = "labels",
	labels = "labels",
	assignee = "assignee",
	author = "author",
	reviewer = "reviewer",
	milestone = "milestone",
	project = "project",
	group = "group",
	scope = "scope",
	state = "state",
	view = "view",
}

local PULLS_STATUS_VALUES = { OPEN = true, MERGED = true, DECLINED = true }

---@class AtlasFilterQueryParseResult
---@field view "issues"|"pulls"|nil
---@field query table
---@field status_filters table<string, boolean>|nil

---@param text string|nil
---@param opts { domain: "pulls"|"issues" }
---@return AtlasFilterQueryParseResult
function M.parse(text, opts)
	opts = opts or {}
	local view = {}
	local free_words = {}
	local labels = {}
	local view_token = nil
	local status_filters = nil

	for _, raw_token in ipairs(tokenize(text or "")) do
		local key, value = raw_token:match("^([%a_]+):(.+)$")
		local canonical = key and KEY_ALIASES[key:lower()]
		if canonical and value and value ~= "" then
			value = value:gsub("^@", "")
			if canonical == "labels" then
				for _, part in ipairs(vim.split(value, ",", { plain = true, trimempty = true })) do
					table.insert(labels, part)
				end
			elseif canonical == "assignee" then
				if value:lower() == "me" then
					view.scope = "assigned_to_me"
				else
					view.assignee_username = value
				end
			elseif canonical == "author" then
				if value:lower() == "me" then
					view.scope = "created_by_me"
				else
					view.author_username = value
				end
			elseif canonical == "reviewer" and opts.domain == "pulls" then
				view.extra_params = view.extra_params or {}
				if value:lower() == "me" then
					view.extra_params.reviewer_id = "Me"
				else
					view.extra_params.reviewer_username = value
				end
			elseif canonical == "state" and opts.domain == "issues" then
				view.state = value:lower()
			elseif canonical == "state" and opts.domain == "pulls" then
				status_filters = status_filters or {}
				for _, part in ipairs(vim.split(value, ",", { plain = true, trimempty = true })) do
					local status = part:upper()
					if PULLS_STATUS_VALUES[status] then
						status_filters[status] = true
					end
				end
			elseif canonical == "view" then
				local candidate = value:lower()
				if candidate == "issues" or candidate == "pulls" then
					view_token = candidate
				end
			elseif canonical == "scope" then
				view.scope = value:lower()
			elseif canonical == "milestone" then
				view.milestone = value
			elseif canonical == "project" then
				view.project = value
			elseif canonical == "group" then
				view.group = value
			end
		else
			table.insert(free_words, raw_token)
		end
	end

	if #labels > 0 then
		view.labels = table.concat(labels, ",")
	end
	if #free_words > 0 then
		view.search = table.concat(free_words, " ")
	end

	return { view = view_token, query = view, status_filters = status_filters }
end

---@param key string
---@param value any
---@return string
local function token(key, value)
	value = tostring(value)
	if value:find("%s") then
		return string.format('%s:"%s"', key, value)
	end
	return string.format("%s:%s", key, value)
end

local PULLS_STATUS_ORDER = { "OPEN", "MERGED", "DECLINED" }

---@param view table|nil
---@param opts { domain: "pulls"|"issues", status_filters?: table<string, boolean> }
---@return string
function M.serialize(view, opts)
	opts = opts or {}
	view = view or {}
	local parts = {}

	if opts.domain == "issues" or opts.domain == "pulls" then
		table.insert(parts, token("view", opts.domain))
	end

	if view.scope == "assigned_to_me" then
		table.insert(parts, token("assignee", "me"))
	elseif view.assignee_username and view.assignee_username ~= "" then
		table.insert(parts, token("assignee", view.assignee_username))
	end

	if view.scope == "created_by_me" then
		table.insert(parts, token("author", "me"))
	elseif view.author_username and view.author_username ~= "" then
		table.insert(parts, token("author", view.author_username))
	end

	if view.scope and view.scope ~= "" and view.scope ~= "assigned_to_me" and view.scope ~= "created_by_me" then
		table.insert(parts, token("scope", view.scope))
	end

	if view.extra_params then
		local skip = {}
		if opts.domain == "pulls" then
			if view.extra_params.reviewer_id == "Me" then
				table.insert(parts, token("reviewer", "me"))
				skip.reviewer_id = true
			elseif view.extra_params.reviewer_username then
				table.insert(parts, token("reviewer", view.extra_params.reviewer_username))
				skip.reviewer_username = true
			end
		end
		local extra_keys = vim.tbl_keys(view.extra_params)
		table.sort(extra_keys)
		for _, key in ipairs(extra_keys) do
			local value = view.extra_params[key]
			if not skip[key] and value ~= nil and value ~= "" then
				table.insert(parts, token(key, value))
			end
		end
	end

	if opts.domain == "issues" and view.state and view.state ~= "" then
		table.insert(parts, token("state", view.state))
	end

	if opts.domain == "pulls" and opts.status_filters then
		local statuses = {}
		for _, status in ipairs(PULLS_STATUS_ORDER) do
			if opts.status_filters[status] then
				table.insert(statuses, status:lower())
			end
		end
		if #statuses > 0 then
			table.insert(parts, token("state", table.concat(statuses, ",")))
		end
	end

	if view.labels and view.labels ~= "" then
		table.insert(parts, token("label", view.labels))
	end
	if view.milestone and view.milestone ~= "" then
		table.insert(parts, token("milestone", view.milestone))
	end
	-- `project` is intentionally never serialized into the visible/editable
	-- filter text: it's always the current repo, so showing it is just noise.
	-- Parsing it back in via M.parse still works for anyone who types it.
	if view.group and view.group ~= "" then
		table.insert(parts, token("group", view.group))
	end

	if view.search and view.search ~= "" then
		table.insert(parts, tostring(view.search))
	end

	return table.concat(parts, " ")
end

return M
