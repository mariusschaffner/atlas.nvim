local M = {}

---@param author IssueUser|nil
---@return string
local function author_name(author)
	if author == nil then
		return "Unknown"
	end
	if author.display_name and author.display_name ~= "" then
		return author.display_name
	end
	if author.account_id and author.account_id ~= "" then
		return author.account_id
	end
	return "Unknown"
end
M.author_name = author_name

---@class IssuesCommentThreadNode
---@field comment IssueComment
---@field children IssuesCommentThreadNode[]

---@param comments IssueComment[]
---@return IssuesCommentThreadNode[]
function M.group_comments(comments)
	local nodes = {}
	local by_id = {}
	for _, comment in ipairs(comments) do
		local node = { comment = comment, children = {} }
		table.insert(nodes, node)
		by_id[tostring(comment.id)] = node
	end

	local roots = {}
	for _, node in ipairs(nodes) do
		local parent = node.comment.parent_id and by_id[tostring(node.comment.parent_id)]
		if parent and parent ~= node then
			table.insert(parent.children, node)
		else
			table.insert(roots, node)
		end
	end

	local function sort_tree(items)
		table.sort(items, function(left, right)
			local left_date = tostring(left.comment.created or "")
			local right_date = tostring(right.comment.created or "")
			if left_date ~= right_date then
				return left_date < right_date
			end
			return tostring(left.comment.id) < tostring(right.comment.id)
		end)
		for _, item in ipairs(items) do
			sort_tree(item.children)
		end
	end

	sort_tree(roots)
	return roots
end

return M
