local config = require("atlas.config")
local providers = require("atlas.providers")

describe("providers.resolve", function()
	local original_options

	before_each(function()
		original_options = config.options
		config.options = {
			providers = {
				gitlab = { base_url = "https://gitlab.example.com" },
			},
			pulls = {
				gitlab = {},
			},
			issues = {
				gitlab = {},
			},
		}
	end)

	after_each(function()
		config.options = original_options
	end)

	it("parses supported provider URLs", function()
		local gitlab = assert(providers.resolve("https://gitlab.example.com/emrearmagan/atlas.nvim/-/issues/8"))

		assert.are.equal("emrearmagan/atlas.nvim", gitlab.project_path)
		assert.are.equal("https://gitlab.example.com/emrearmagan/atlas.nvim.git", gitlab.repository_url)
	end)

	it("resolves Git remotes as repository targets", function()
		local cases = {
			{
				"ssh://git@gitlab.example.com/group/subgroup/repo.git",
				"gitlab",
				"group/subgroup/repo",
				"https://gitlab.example.com/group/subgroup/repo",
				"https://gitlab.example.com/group/subgroup/repo.git",
			},
			{
				"git@gitlab.example.com:group/subgroup/repo.git",
				"gitlab",
				"group/subgroup/repo",
				"https://gitlab.example.com/group/subgroup/repo",
				"https://gitlab.example.com/group/subgroup/repo.git",
			},
			{
				"https://gitlab.example.com/group/subgroup/repo.git",
				"gitlab",
				"group/subgroup/repo",
				"https://gitlab.example.com/group/subgroup/repo",
				"https://gitlab.example.com/group/subgroup/repo.git",
			},
		}

		for _, case in ipairs(cases) do
			local target = assert(providers.resolve(case[1]))
			assert.are.equal(case[2], target.provider)
			assert.are.equal("pulls", target.domain)
			assert.are.equal("repo", target.entity)
			assert.are.equal(case[3], target.repo_full_name)
			assert.are.equal(case[4], target.url)
			assert.are.equal(case[5], target.repository_url)
		end
	end)

	it("preserves configured base paths", function()
		config.options.providers.gitlab.base_url = "https://gitlab.example.com/gitlab"

		local repository = assert(providers.resolve("git@gitlab.example.com:group/subgroup/repo.git"))
		local https_repository = assert(providers.resolve("https://gitlab.example.com/gitlab/group/subgroup/repo.git"))
		local merge_request =
			assert(providers.resolve("https://gitlab.example.com/gitlab/group/subgroup/repo/-/merge_requests/12"))

		assert.are.equal("group/subgroup/repo", repository.repo_full_name)
		assert.are.equal("https://gitlab.example.com/gitlab/group/subgroup/repo", repository.url)
		assert.are.equal("https://gitlab.example.com/gitlab/group/subgroup/repo.git", repository.repository_url)
		assert.are.equal(repository.repo_full_name, https_repository.repo_full_name)
		assert.are.equal(repository.repository_url, https_repository.repository_url)
		assert.are.equal(repository.repository_url, merge_request.repository_url)
		assert.are.equal(12, merge_request.id)
	end)

	it("rejects unsupported URLs", function()
		local target, err = providers.resolve("https://not-gitlab.example.com/browse/ATLAS-123")
		assert.is_nil(target)
		assert.are.equal("Unsupported Atlas URL", err)
	end)
end)
