[![Neovim](https://img.shields.io/badge/Neovim-0.10+-blue.svg)](https://neovim.io/)
[![Version](https://img.shields.io/github/v/tag/emrearmagan/atlas.nvim.svg)](https://github.com/emrearmagan/atlas.nvim/tags)
[![CI](https://github.com/emrearmagan/atlas.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/emrearmagan/atlas.nvim/actions/workflows/ci.yml)
[![License](https://img.shields.io/github/license/emrearmagan/atlas.nvim?style=flat-square&color=blue)](LICENSE)

# Atlas.nvim

Review GitLab merge requests and manage GitLab issues without leaving Neovim.

<p>
  <img alt="GitLab" src="https://img.shields.io/badge/GitLab-FC6D26?style=flat-square&logo=gitlab&logoColor=white">
</p>

<img alt="Atlas UI" src="https://github.com/user-attachments/assets/de6459f9-f123-40a6-acbd-097a17e7ae86" />

> [!CAUTION]
> **Still in early development, will have breaking changes!**

## Table of Contents

- [Installation](#installation)
  - [Requirements](#requirements)
- [Features](#features)
- [Configuration](#configuration)
- [Commands](#commands)
- [Pulls](#pulls)
  - [GitLab](#gitlab)
- [Issues](#issues)
  - [GitLab](#gitlab-issues)
- [Events](#events)
- [Keymaps](#keymaps)
- [Contributing](#contributing)

## Installation

### Using [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
---@module "atlas"

{
  "emrearmagan/atlas.nvim",
  dependencies = {
    "nvim-tree/nvim-web-devicons", -- optional but recommended
    "MeanderingProgrammer/render-markdown.nvim", -- optional but recommended
    "esmuellert/codediff.nvim", -- optional (PullRequest diff)
    "sindrets/diffview.nvim", -- optional; or "dlyongemallo/diffview-plus.nvim"
  },
  -- See Configuration below
  ---@type AtlasConfig
  opts = {},
}
```

### Using [vim.pack](https://neovim.io/doc/user/pack/#vim.pack) (Neovim 0.12+)

```lua
vim.pack.add({
  "https://github.com/emrearmagan/atlas.nvim",
})

-- See Configuration below
require("atlas").setup({})
```

### Requirements

- Neovim: `0.10+`
- `git` and `curl` on `$PATH`
- GitLab: GitLab REST API v4 (`gitlab.com` or self-hosted), Personal Access Token with `api` scope

> [!tip]
> It's a good idea to run `:checkhealth atlas` to see if everything is set up correctly.

## Features

### Review Pull Requests

<img alt="AtlasDiff" src="https://github.com/user-attachments/assets/7280373a-f6e9-4847-be64-89e245d461cd">

Run `:Atlas review` inside a Git repository to pick one of its open or draft pull requests, or pass a pull-request URL directly. Atlas opens the configured diff viewer.
Or press the configured `pulls.open_diff` key (`gd` by default) on a pull request to start a review.

- See pending, resolved, and outdated GitLab threads inline at their diff locations.
- Add inline or file-level comments and suggestions; reply to, edit, delete, resolve, or reopen threads.
- Submit pending comments with an optional review summary, approve, or request changes.
- Merge pull requests from Atlas using the methods supported by GitLab.
- Review GitLab tasks alongside their comments.
- Browse comments, tasks, and local notes.
- Mark files reviewed in AtlasDiff.

> [!NOTE]
> **Alternative viewers:** [CodeDiff](https://github.com/esmuellert/codediff.nvim), [Diffview](https://github.com/sindrets/diffview.nvim), and [Diffview-plus](https://github.com/dlyongemallo/diffview-plus.nvim) can display Atlas comment, task, and local-note overlays, but their integrations rely on plugin internals and may break after upstream changes.

#### Local notes

<p align="center">
  <img width="85%" alt="Local review notes" src="https://github.com/user-attachments/assets/8652d731-b57f-45f8-896e-d62d0ec8d7f4">
</p>

Local notes let you leave something on a diff without posting it to the pull request. Each note is attached to a file and line and can be an `ISSUE`, `SUGGESTION`, `NOTE`, or `PRAISE`. Diff views mark notes as outdated when their saved line changes.

<details>
<summary><strong>Script and integration</strong></summary>

For scripts, use `bin/atlas-notes`. Notes added there appear in AtlasDiff, CodeDiff, Diffview, Diffview-plus, and `:Atlas notes`:

```sh
./bin/atlas-notes add \
  --target https://gitlab.com/owner/repository/-/merge_requests/123 \
  --file lua/review_queue.lua --line 19 \
  --context "local item = queue[index]" \
  --type suggestion --body "Should this be a bool?"
```

My dotfiles include a [Pi extension that wraps this script](https://github.com/emrearmagan/dotfiles/blob/main/config/pi/extensions/atlas-notes.ts) so review agents can list and add notes.

</details>

### View Pipelines

<p align="center">
  <img width="85%" alt="View pipelines" src="https://github.com/user-attachments/assets/c625c4e8-b1ad-4772-b46b-24718ba6fbb7">
</p>

View pipelines and their jobs, inspect their status, and read job logs directly in Atlas. Retry failed pipelines or jobs and cancel work that is still running.

### Custom Actions

<p align="center">
  <img width="85%" alt="Atlas custom action" src="https://github.com/user-attachments/assets/a8ca355b-09e2-428c-b3fb-3280fd161110">
</p>

Add project-specific actions to pull requests and issues. Custom actions receive the current item and provider context, making it possible to call local scripts, open repositories in tmux, copy branch names, or connect Atlas to your own tooling.

<details>
<summary><strong>Configuration</strong></summary>

```lua
pulls = {
  repo_config = {
    paths = {
      ["your-workspace/*"] = "~/code/repos/*",
    },
    settings = {},
  },
  custom_actions = {
    {
      id = "show_repo_status",
      label = "Show repository status",
      confirmation = true,
      ---@param pr PullRequest
      ---@param ctx AtlasPullsCustomActionContext
      ---@param done fun(ok: boolean|nil, message: string|nil)
      run = function(_, ctx, done)
        if not ctx.repo_path then
          done(false, "No repo path")
          return
        end

        local output = ctx.output("Repository status")
        output:write("Checking " .. ctx.repo_path)
        output:run({ "git", "status", "--short" }, function(code)
          if code ~= 0 then
            done(false, "Failed to read repository status")
            return
          end
          done(true, "Repository status loaded")
        end, {
          cwd = ctx.repo_path,
        })
      end,
    },
  },
},
issues = {
  custom_actions = {
    {
      id = "copy_branch_name",
      label = "Copy branch name",
      ---@param issue Issue
      ---@param ctx AtlasIssuesCustomActionContext
      ---@param done fun(ok: boolean|nil, message: string|nil)
      run = function(issue, ctx, done)
        local branch = string.format("%s/%s", issue.key, issue.title:lower():gsub("%s+", "-"))
        vim.fn.setreg("+", branch)
        done(true, "Copied: " .. branch)
      end,
    },
  },
},
```

Use `ctx.output(title)` to show output from a custom action:

```lua
output:write("Loading...")
output:run(cmd, on_exit, { cwd = "/repo" })
```

</details>

### Create Pull Requests and Issues

<p align="center">
  <img width="50%" alt="Create pull request" src="https://github.com/user-attachments/assets/d6335c66-35f7-4495-b83a-53819d7ec7d5"><img width="50%" alt="Create issue" src="https://github.com/user-attachments/assets/8f3b06d8-763d-4e0f-ab93-9c3754065ca3">
</p>

`:Atlas create pr` opens a form for the current branch using a configured template or a description generated from its commits. Edit the title and description, choose the target branch and reviewers, set the draft state, and preview the commits and diffstat before submitting.

`:Atlas create issue` opens a GitLab issue form with Markdown descriptions, saved templates, and fields such as labels, assignees, and milestones.

### Notifications

<p align="center">
  <img width="85%" alt="Notifications" src="https://github.com/user-attachments/assets/117b5ad7-3840-4487-bd91-f2f9bf213428">
</p>

Open GitLab notifications inside Atlas, refresh them, open the related item, and mark notifications as read or done without leaving Neovim.

### Bookmarks

<p align="center">
  <img width="85%" alt="Bookmarks" src="https://github.com/user-attachments/assets/f008d6af-dfc6-4b65-8af1-94cd6ce9fc99">
</p>

Turn frequently used GitLab searches into named shortcuts. Use bookmarks for review queues, recurring project views, and the searches you return to throughout the day.

Bookmarks appear alongside your configured views, keeping important queries one action away.
Star a pull request or issue with `*` to keep it at the top of lists. Starred items are saved locally and appear in the first bookmark entry.

### Statusline

Atlas comes with its own statusline for key hints, loading progress, and notifications. Keeping it enabled is recommended because most interaction and feedback goes through it.

If you use lualine, disable its statusline for Atlas buffers so it does not replace the Atlas statusline:

```lua
require("lualine").setup({
  options = {
    disabled_filetypes = {
      statusline = { "atlas" },
      winbar = {},
    },
  },
})
```

At some point there will probably an extension for lualine.

## Configuration

```lua
{
  ui = {
    -- Global statusline for Atlas. See the Statusline section below.
    statusline = true,
    -- "auto", "default", "snacks", or "fzf-lua".
    picker = "auto",
    -- Make the main Atlas dashboard a listed buffer.
    listed_buffer = false,
  },

  providers = {
    ---@type AtlasGitLabConfig
    gitlab = {
      base_url = "https://gitlab.com",
      -- Personal Access Token with `api` scope:
      -- https://docs.gitlab.com/ee/user/profile/personal_access_tokens.html
      token = vim.env.GITLAB_TOKEN,
      cache_ttl = 300, -- Set to 0 to disable caching.
    },
  },

  -- See Pulls Configuration below.
  pulls = { },

  -- See Issue Configuration below.
  issues = { },
}
```

## Commands

- `:Atlas` - Pick a command
- `:Atlas pulls [provider]` - Open a pull-request provider dashboard
- `:Atlas issues [provider]` - Open an issue provider dashboard
- `:Atlas review [pull-request-url]` - Review a pull request with the configured diff viewer
- `:Atlas diff <base>...<head>` - Open a Git range in native AtlasDiff
- `:Atlas diff <pull-request-url>` - Open a pull request in native AtlasDiff
- `:Atlas create <pr|issue>` - Create a pull request or issue
- `:Atlas search [provider]` - Search configured pull-request and issue providers
- `:Atlas open <target|.>` - Open a GitLab URL, a PR/issue number in the current repository, or the current repository
- `:Atlas notes [target]` - Inspect local review notes
- `:Atlas clear [cache|notes|stars]` - Clear all Atlas data or only cached data and cloned repositories, local review notes, or starred items
- `:Atlas logs` - Toggle Atlas logs
- `:AtlasDiff <base>...<head>` - Open a Git range in native AtlasDiff directly
- `:AtlasDiff <pull-request-url>` - Open a pull request in native AtlasDiff directly

## Pulls

Use `:Atlas pulls` to browse and manage GitLab merge requests.
Shared authentication and endpoints are configured in the top-level `providers` table.

### Pulls Configuration

```lua
pulls = {
  delete_notes = false, -- Delete local PR notes after approval or merge.
  default_merge_method = "merge", -- "merge" or "squash".
  default_delete_branch = false,
  git_transport = "https", -- "https" or "ssh" for Atlas-managed Git remotes.

  -- Replaces the built-in Conventional Comments templates.
  comment_templates = {
    insert_mode = true, -- Enter Insert mode after applying a template.
    items = {
      { label = "Suggestion", text = "suggestion: " },
      { label = "Issue", text = "issue: " },
      { label = "Nitpick", text = "nitpick: " },
    },
  },

  diff = {
    -- Any command that accepts explicit <base>...<head> Git revisions.
    open_cmd = "AtlasDiff", -- default; for example "DiffviewOpen" or "CodeDiff".
    show_review_panel = false, -- Set true to show the review panel when a diff opens.
    comment_display = "virtual_lines", -- "virtual_lines" or compact "virtual_text" hints.
    review_panel = {
      height = 10,
    },

    -- AtlasDiff options; external viewers use their own configuration.
    layout = "inline", -- "inline" or "side-by-side".
    compact = true, -- Start with only changed hunks and surrounding context visible.
    compact_context_lines = 3, -- Context lines shown around hunks in compact mode.
    explorer = {
      grouped = true, -- Group changed files by directory.
      hidden = false,
      show_commits = false, -- Set true to show commits below changed files initially.
      width = 40,
      initial_focus = "explorer", -- "explorer" or "diff".
      preview = false, -- Show a file as soon as the explorer cursor moves onto it.
      ignore = { ".git/**", ".jj/**" },
    },
  },
  repo_config = {
    -- Maps `workspace/repo` to local paths. Used for checkout, diffs, and custom actions.
    paths = {
      ["your-workspace/*"] = "~/code/repos/*",
      ["your-workspace/atlas"] = "~/code/atlas",
    },
    settings = {
      ["your-workspace/atlas"] = {
        readme = "README.md", -- optional, defaults to README.md
        pr_template = ".gitlab/merge_request_templates/Default.md", -- optional, defaults to .gitlab/merge_request_templates/Default.md
      },
    },
  },
  custom_actions = {}, -- See Custom Actions below.
},
```

<a id="gitlab"></a>

<details>
<summary><strong>GitLab</strong></summary>

```lua
pulls = {
  ---@type AtlasGitLabPullsConfig
  gitlab = {
    ---@type AtlasGitLabPullsViewConfig[]
    views = {
      {
        name = "Assigned",
        key = "1",
        layout = "grouped", -- "compact", "grouped", or "plain"
        scope = "assigned_to_me",
      },
      {
        name = "Reviewing",
        key = "3",
        scope = "all",
        extra_params = { reviewer_id = "Me" },
      },
      -- Single project
      {
        name = "GitLab",
        key = "G",
        project = "gitlab-org/gitlab",
      },
      -- Whole group, all projects under it
      {
        name = "GitLab Org",
        key = "O",
        group = "gitlab-org",
      },
    },

    bookmarks = {
      key   = "S",      -- default
      label = "Search", -- default
      items = {
        ["Reviewing"]    = { scope = "all", extra_params = { reviewer_id = "Me" } },
        ["Created by me"] = { scope = "all", author_username = "me" },
      },
    },
  },
},
```

<img alt="GitLab pull requests" src="https://github.com/user-attachments/assets/128fe916-e733-4abb-9c5c-5244684f3c41">

</details>

## Issues

Use `:Atlas issues` to browse and manage GitLab issues.
Shared authentication and endpoints are configured in the top-level `providers` table.

### Issue Configuration

```lua
issues = {
  max_results = 100,
  with_relationships = true, -- Fetch parent/subissue relationships for plain issue tree views.
  custom_actions = {}, -- See Custom Actions below.
}
```

<a id="gitlab-issues"></a>

<details>
<summary><strong>GitLab Issues</strong></summary>

```lua
issues = {
  ---@type AtlasGitLabIssuesConfig
  gitlab = {
    ---@type AtlasGitLabIssuesViewConfig[]
    views = {
      {
        name = "Assigned",
        key = "1",
        scope = "assigned_to_me",
        state = "opened",
      },
      {
        name = "Created",
        key = "2",
        scope = "created_by_me",
        state = "opened",
      },
      {
        name = "All open",
        key = "3",
        scope = "all",
        state = "opened",
        -- Anything not covered by the explicit fields below can be passed via `extra_params`.
        extra_params = { ["not[labels]"] = "wontfix" },
      },
    },

    bookmarks = {
      key   = "S",      -- default
      label = "Search", -- default
      items = {
        ["No labels"] = { scope = "all", state = "opened",
                          extra_params = { ["not[labels]"] = "*" } },
        ["Closed"]    = { scope = "created_by_me", state = "closed" },
      },
    },
  },
},
```

</details>

## Events

Atlas emits these `User` events after the corresponding cleanup or setup has completed:

- `AtlasUIClosed` for the main pulls/issues dashboard.
- `AtlasDiffOpened` and `AtlasDiffClosed` for the native AtlasDiff view.
- `AtlasReviewAttached` and `AtlasReviewDetached` for Atlas review overlays in AtlasDiff, CodeDiff, and Diffview.

## Keymaps

Set an action to `false` to disable it, or set it to a list to add aliases.

```lua
keymaps = {
  ui = {
    help = "g?", -- { "g?", "<leader>?" } would add aliases
    close = "q", -- false would disable it
    next_item = "j",
    previous_item = "k",
    first_item = "gg",
    last_item = "G",
    select = "<CR>",
    submit = "<C-s>",
    delete = "dd",
    comments = {
      add = { "a", "i" },
      reply = "c",
      edit = "e",
      react = "gr",
    },
    toggle_panel = "p",
    toggle_fold = "za",
    toggle_all_folds = "zA",
    previous_panel_tab = "<S-Tab>",
    next_panel_tab = "<Tab>",
    notifications = {
      open = "N",
      mark_read = "r",
      mark_done = "d",
    },
    toggle_subscription = "gS",
    toggle_star = "*",
    refresh = "r",
    refresh_view = "R",
    open_actions = "A",
    open_in_browser = "gx",
    copy_id = "y",
    copy_url = "Y",
    show_details = "K",
    search = "?",
  },
  picker = {
    next_item = { "<Down>", "<C-n>", "<C-j>" },
    previous_item = { "<Up>", "<C-p>", "<C-k>" },
    select = { "<CR>", "<C-s>" },
    toggle = "<Tab>",
    close = { "q", "<Esc>" },
  },
  issues = {
    transition_issue = "gs",
    change_assignee = "ga",
    change_reporter = "gr",
    edit_issue = "ge",
    create_issue = "c",
    toggle_description_mode = "m",
  },
  pulls = {
    open_diff = "gd",
    checkout = "gc",
    external_help = "gA", -- Atlas help in external diff viewers
    toggle_repo_panel = "o",
    toggle_repo_issue_state = "t",
    edit_title = "T",
    edit_description = "D",
    review = {
      focus_item = "gd",
      approve = "ga",
      request_changes = "gr",
      submit_review = "gs",
      add_task = "<leader>t",
      comment_templates = "gT",
      find_file = "<leader>ff",
      explorer = {
        find_file = { "f", "<leader>ff" },
        next_file = { "]f", "<Tab>" },
        previous_file = { "[f", "<S-Tab>" },
        next_unreviewed_file = "]u",
        previous_unreviewed_file = "[u",
        toggle_grouping = "T",
        toggle_file_reviewed = "-",
        toggle_commits = "gC",
      },
      diff = {
        toggle_layout = "t",
        toggle_compact = "gc",
        next_hunk = "]h",
        previous_hunk = "[h",
        toggle_review_panel = "gR",
        toggle_detail_panel = "gD",
        toggle_comments = "gH",
        next_comment = "]c",
        previous_comment = "[c",
        next_note = "]n",
        previous_note = "[n",
        add_comment = "c",
        submit_comment = "C",
        add_suggestion = "s",
        submit_suggestion = "S",
        add_note = "<leader>n",
        toggle_resolved = "x",
      },
    },
    filters = {
      open = "gpo",
      merged = "gpm",
      declined = "gpd",
    },
  },
},
```

## Credits

Thank you to everyone who has contributed to Atlas! ❤️

<a href="https://github.com/emrearmagan/atlas.nvim/graphs/contributors">
  <img src="https://contrib.rocks/image?columns=25&max=10000&repo=emrearmagan/atlas.nvim" alt="Atlas contributors">
</a>

## Contributing

Contributions are welcome! If you'd like to contribute, please open an [issue](https://github.com/emrearmagan/atlas.nvim/issues) or [pull request](https://github.com/emrearmagan/atlas.nvim/pulls) on GitHub. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT License - see [LICENSE](LICENSE) for details.
