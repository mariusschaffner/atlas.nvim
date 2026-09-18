local M = {}

---@param v any
---@return table|nil
function M.as_table(v)
	if type(v) == "table" then
		return v
	end
	return nil
end

--- Compares two item lists (e.g. an "original" picker selection and the
--- "final" one a user just confirmed) by a derived key, and reports whether
--- the effective set of keys differs. key_fn may return nil to exclude an
--- item from the comparison (mirrors filtering out entries with no usable id).
---@generic T
---@param original T[]
---@param selected T[]
---@param key_fn fun(item: T): any|nil
---@return boolean changed
function M.selection_changed(original, selected, key_fn)
	local original_keys, original_count = {}, 0
	for _, item in ipairs(original) do
		local key = key_fn(item)
		if key ~= nil then
			original_keys[key] = true
			original_count = original_count + 1
		end
	end

	local selected_keys, selected_count = {}, 0
	for _, item in ipairs(selected) do
		local key = key_fn(item)
		if key ~= nil then
			selected_keys[key] = true
			selected_count = selected_count + 1
		end
	end

	if selected_count ~= original_count then
		return true
	end
	for key in pairs(original_keys) do
		if not selected_keys[key] then
			return true
		end
	end
	return false
end

return M
