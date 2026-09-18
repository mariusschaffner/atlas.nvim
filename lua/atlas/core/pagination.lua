local M = {}

--- Fetches pages one at a time (via opts.fetch) until either max_results is
--- reached or the source reports no more pages, accumulating items across
--- calls. Generic pagination-loop extracted so callers don't have to write
--- their own recursive fetch_page.
---@generic T
---@param opts {
---max_results: integer,
---fetch: fun(next_page_token: string|nil, remaining: integer, done: fun(items: T[], next_token: string|nil, is_last: boolean, err: string|nil)),
---on_page: (fun(items: T[]))|nil,
---on_error: fun(err: string, items: T[]),
---on_complete: fun(items: T[]),
---}
function M.run(opts)
	local function fetch_page(next_page_token, items)
		local remaining = opts.max_results - #items
		if remaining <= 0 then
			opts.on_complete(items)
			return
		end

		opts.fetch(next_page_token, remaining, function(page_items, next_token, is_last, err)
			if err ~= nil then
				opts.on_error(err, items)
				return
			end

			for _, item in ipairs(page_items) do
				if #items >= opts.max_results then
					break
				end
				table.insert(items, item)
			end

			if opts.on_page then
				opts.on_page(items)
			end

			if #items >= opts.max_results then
				opts.on_complete(items)
				return
			end

			if is_last ~= true and next_token ~= nil and next_token ~= "" then
				fetch_page(next_token, items)
				return
			end

			opts.on_complete(items)
		end)
	end

	fetch_page(nil, {})
end

return M
