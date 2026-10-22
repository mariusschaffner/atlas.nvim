local wf_state = require("atlas.issues.providers.gitlab.wf_state")

describe("atlas.issues.providers.gitlab.wf_state.state_for", function()
	it("returns done for a closed issue regardless of labels", function()
		local issue = { status_id = "closed", labels = { { name = "WF:Doing" } } }
		assert.are.equal("done", wf_state.state_for(issue))
	end)

	it("returns doing for an open issue with a WF:Doing label", function()
		local issue = { status_id = "open", labels = { { name = "WF:Doing" } } }
		assert.are.equal("doing", wf_state.state_for(issue))
	end)

	it("returns todo for an open issue with a WF:To Do label", function()
		local issue = { status_id = "open", labels = { { name = "WF:To Do" } } }
		assert.are.equal("todo", wf_state.state_for(issue))
	end)

	it("returns todo for an open issue with no WF label", function()
		local issue = { status_id = "open", labels = { { name = "bug" } } }
		assert.are.equal("todo", wf_state.state_for(issue))
	end)

	it("returns todo for an open issue with no labels at all", function()
		local issue = { status_id = "open" }
		assert.are.equal("todo", wf_state.state_for(issue))
	end)

	it("is case- and spacing-insensitive on the WF label", function()
		assert.are.equal("doing", wf_state.state_for({ status_id = "open", labels = { { name = "wf: doing" } } }))
		assert.are.equal("doing", wf_state.state_for({ status_id = "open", labels = { { name = "WF:  Doing " } } }))
	end)

	it("returns done for an open issue carrying an explicit WF:Done label", function()
		local issue = { status_id = "open", labels = { { name = "WF:Done" } } }
		assert.are.equal("done", wf_state.state_for(issue))
	end)
end)
