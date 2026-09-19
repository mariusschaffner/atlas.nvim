local inline_field_edit = require("atlas.ui.inline_field_edit")

describe("atlas.ui.inline_field_edit.parse_multi_value", function()
	it("resolves comma-separated names against the known set", function()
		local resolved_by_lower = { alice = "alice", bob = "bob" }
		local resolved, unresolved = inline_field_edit.parse_multi_value("alice, bob", resolved_by_lower)
		assert.same({ "alice", "bob" }, resolved)
		assert.same({}, unresolved)
	end)

	it("drops unresolved segments without touching the resolved ones", function()
		local resolved_by_lower = { alice = "alice" }
		local resolved, unresolved =
			inline_field_edit.parse_multi_value("alice, charlie", resolved_by_lower)
		assert.same({ "alice" }, resolved)
		assert.same({ "charlie" }, unresolved)
	end)

	it("is case-insensitive but returns the canonical stored casing", function()
		local resolved_by_lower = { ["john.doe"] = "John.Doe" }
		local resolved = inline_field_edit.parse_multi_value("JOHN.DOE", resolved_by_lower)
		assert.same({ "John.Doe" }, resolved)
	end)

	it("dedupes repeated names in the resolved list", function()
		local resolved_by_lower = { alice = "alice" }
		local resolved = inline_field_edit.parse_multi_value("alice, alice, alice", resolved_by_lower)
		assert.same({ "alice" }, resolved)
	end)

	it("ignores empty and whitespace-only segments", function()
		local resolved_by_lower = { alice = "alice" }
		local resolved, unresolved = inline_field_edit.parse_multi_value("  , alice,  , ", resolved_by_lower)
		assert.same({ "alice" }, resolved)
		assert.same({}, unresolved)
	end)

	it("returns nothing for an empty string", function()
		local resolved, unresolved = inline_field_edit.parse_multi_value("", {})
		assert.same({}, resolved)
		assert.same({}, unresolved)
	end)
end)
