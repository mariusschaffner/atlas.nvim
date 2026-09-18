local utils = require("atlas.core.utils")

describe("atlas.core.utils.selection_changed", function()
	local id_key = function(item)
		return tonumber(item.id)
	end

	it("reports unchanged when the same set is reordered", function()
		assert.is_false(utils.selection_changed({ { id = 1 }, { id = 2 } }, { { id = 2 }, { id = 1 } }, id_key))
	end)

	it("reports changed when an item is added", function()
		assert.is_true(utils.selection_changed({ { id = 1 } }, { { id = 1 }, { id = 2 } }, id_key))
	end)

	it("reports changed when a same-size set swaps a member", function()
		assert.is_true(utils.selection_changed({ { id = 1 }, { id = 2 } }, { { id = 1 }, { id = 3 } }, id_key))
	end)

	it("excludes items whose key_fn returns nil from the comparison", function()
		assert.is_false(utils.selection_changed({ { id = 1 }, { id = "bad" } }, { { id = 1 } }, id_key))
	end)

	it("reports unchanged for two empty lists", function()
		assert.is_false(utils.selection_changed({}, {}, id_key))
	end)

	it("works with non-numeric keys", function()
		local provider_id_key = function(reviewer)
			return reviewer.provider_id
		end
		assert.is_false(utils.selection_changed({ { provider_id = "a" } }, { { provider_id = "a" } }, provider_id_key))
		assert.is_true(utils.selection_changed({ { provider_id = "a" } }, { { provider_id = "b" } }, provider_id_key))
	end)
end)
