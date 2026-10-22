local viewed = require("atlas.pulls.ui.detail.viewed")

describe("pulls.ui.detail.viewed.key", function()
	it("combines project, iid and head sha", function()
		assert.are.equal("atlas/semesterarbeit!36@abc123", viewed.key("atlas/semesterarbeit", 36, "abc123"))
	end)

	it("changes when new commits arrive", function()
		assert.are_not.equal(viewed.key("g/p", "36", "abc"), viewed.key("g/p", "36", "def"))
	end)

	it("differs per MR and per project", function()
		assert.are_not.equal(viewed.key("g/p", "1", "abc"), viewed.key("g/p", "2", "abc"))
		assert.are_not.equal(viewed.key("g/p", "1", "abc"), viewed.key("g/q", "1", "abc"))
	end)

	it("treats string and number iids alike", function()
		assert.are.equal(viewed.key("g/p", 7, "s"), viewed.key("g/p", "7", "s"))
	end)

	it("derives the key from a PR", function()
		local pr = { repo_full_name = "g/p", id = "36", source = { commit_hash = "abc" } }
		assert.are.equal("g/p!36@abc", viewed.key_for(pr))
	end)
end)
