-- Provider Interface
--------------------------------------------------------------------------------

---@class IssuesFetchOpts
---@field force_load boolean|nil
---@field max_results number|nil
---@field next_page_token string|nil
---@field layout "plain"|"compact"|nil
---@field with_relationships boolean|nil

---@class AtlasIssuesCommentCompletionContext
---@field issue Issue
---@field details IssueDetails|nil
---@field comments IssueComment[]

---@class IssuesViewConfig : AtlasIssuesViewConfig

---@class IssuesProvider
---@field id string
---@field name string
---@field icon string
---@field hl_group string
---@field views fun(): IssuesViewConfig[]
---@field search_view fun(target: AtlasTarget): IssuesViewConfig
---@field issue_ref fun(target: AtlasTarget): IssueRef|nil
---@field capabilities IssuesProviderCapabilities

---@class IssuesProviderCapabilities
---@field core IssuesCoreCapability
---@field comments IssuesCommentsCapability|nil
---@field notifications AtlasNotificationsCapability|nil
---@field actions IssuesActionsCapability|nil
---@field ui IssuesUICapability|nil

---@class IssueLinkedMergeRequest
---@field id integer MR iid
---@field title string
---@field state string "opened"|"merged"|"closed"|...
---@field web_url string|nil
---@field repo_full_name string Project path the MR belongs to, e.g. "group/project"

---@class IssueLinkedBranch
---@field name string

---@class IssueProjectBranch
---@field name string
---@field default boolean

---@class IssuesCoreCapability
---@field fetch_user fun(on_done: fun(user: IssueUser|nil, err: string|nil)): { cancel: fun() }|nil
---@field search_query fun(view: IssuesViewConfig, opts: IssuesFetchOpts): string
---@field fetch_issues fun(view: IssuesViewConfig, opts: IssuesFetchOpts, on_done: fun(issues: Issue[], next_page_token: string|nil, is_last: boolean, err: string|nil)): { cancel: fun() }|nil
---@field fetch_by_refs fun(refs: IssueRef[], opts: IssuesFetchOpts, on_done: fun(issues: Issue[], err: string|nil)): { cancel: fun() }|nil
---@field fetch_issue fun(ref: IssueRef, opts: IssuesFetchOpts|nil, on_done: fun(details: IssueDetails|nil, err: string|nil)): { cancel: fun() }|nil
---@field update_description (fun(issue: Issue, content: string, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil)|nil
---@field update_title (fun(issue: Issue, title: string, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil)|nil
---@field fetch_linked_merge_requests (fun(issue: Issue, opts: { force_load: boolean|nil }|nil, on_done: fun(items: IssueLinkedMergeRequest[]|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field fetch_linked_branches (fun(issue: Issue, opts: { force_load: boolean|nil }|nil, on_done: fun(items: IssueLinkedBranch[]|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field fetch_project_branches (fun(issue: Issue, opts: { force_load: boolean|nil }|nil, on_done: fun(items: IssueProjectBranch[]|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field create_branch (fun(issue: Issue, branch_name: string, source_ref: string, on_done: fun(branch: IssueLinkedBranch|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field fetch_milestones (fun(project_path: string, on_done: fun(milestones: IssueMilestone[]|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field fetch_milestone (fun(project_path: string, milestone_id: integer, on_done: fun(milestone: IssueMilestone|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field fetch_milestone_issues (fun(project_path: string, milestone_id: integer, on_done: fun(issues: Issue[]|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field fetch_milestone_merge_requests (fun(project_path: string, milestone_id: integer, on_done: fun(items: MilestoneWorkItem[]|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field update_milestone_title (fun(project_path: string, milestone_id: integer, title: string, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil)|nil
---@field update_milestone_description (fun(project_path: string, milestone_id: integer, description: string, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil)|nil
---@field update_milestone_start_date (fun(project_path: string, milestone_id: integer, value: string, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil)|nil
---@field update_milestone_due_date (fun(project_path: string, milestone_id: integer, value: string, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil)|nil
---@field refresh fun()|nil

---@class IssuesCommentsCapability
---@field fetch_activity (fun(issue: Issue, opts: IssuesFetchOpts|nil, on_done: fun(entries: IssueActivityEntry[]|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field fetch_conversation (fun(issue: Issue, opts: { force_refresh: boolean|nil }|nil, on_done: fun(items: IssueConversationItem[]|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field add_comment (fun(issue: Issue, content: string, on_done: fun(comment: IssueComment|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field reply_comment (fun(issue: Issue, parent: IssueComment, content: string, on_done: fun(comment: IssueComment|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field edit_comment (fun(issue: Issue, comment: IssueComment, content: string, on_done: fun(comment: IssueComment|nil, err: string|nil)): { cancel: fun() }|nil)|nil
---@field delete_comment (fun(issue: Issue, comment: IssueComment, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil)|nil
---@field add_reaction (fun(issue: Issue, item: IssueConversationItem, key: string, on_done: fun(ok: boolean, err: string|nil)): { cancel: fun() }|nil)|nil
---@field reaction_options IssueReactionOption[]|nil
---@field comment_completion (fun(context: AtlasIssuesCommentCompletionContext): AtlasMarkdownCompletionProvider|nil)|nil

---@class IssuesActionsCapability
---@field items AtlasIssueAction[]
---@field is_available fun(action_id: string, context: AtlasIssueActionContext): boolean
---@field run fun(action_id: string, context: AtlasIssueActionContext, on_done: fun(result: IssuesActionResult|nil, err: string|nil)): boolean

---@class IssuesActionResult
---@field issue_key string|nil

---@class IssuesUICapability
---@field setup fun()|nil
---@field detail IssuesProviderDetail|nil

--------------------------------------------------------------------------------
-- Detail interface
--------------------------------------------------------------------------------

---@class IssuesTitleStatus
---@field text string
---@field hl string
---@field label string|nil Title field's box label, e.g. "Title - 42"; falls back to issue.key if absent.

---@class IssuesProviderHeaderFields
---@field author IssuesDetailHeaderField
---@field assignee IssuesDetailHeaderField
---@field labels IssuesDetailHeaderField
---@field milestone IssuesDetailHeaderField|nil

---@class IssuesProviderDetail
---@field header_fields (fun(issue: Issue, details: IssueDetails|nil, loading: boolean): IssuesProviderHeaderFields)|nil
---@field title_status (fun(issue: Issue): IssuesTitleStatus)|nil
---@field tabs (fun(): IssuesDetailTabDefinition[])|nil

--------------------------------------------------------------------------------
-- Detail types
--------------------------------------------------------------------------------

---@class IssuesDetailHeaderField
---@field label string
---@field value string
---@field hl string|table[]|nil hl group name, or list of {start_col, end_col, hl_group} relative to the value
---@field editable boolean|nil whether this field can be edited from the detail panel (styled with a distinct border)
---@field border_hl string|nil explicit border color override, e.g. for the title field's open/closed status

---@class IssuesDetailTabModule
---@field render fun(issue: Issue, details: IssueDetails|nil, width: integer): string[], table[], table<integer, table>|nil
---@field on_select (fun(issue: Issue, refresh: fun(), opts: { force_refresh: boolean|nil }|nil))|nil
---@field reset fun()|nil
---@field activate (fun(buf: integer, refresh: fun()))|nil
---@field deactivate (fun(buf: integer))|nil
---@field is_loading (fun(): boolean)|nil
---@field is_selectable_line (fun(lnum: integer, entry: table): boolean)|nil
---@field on_enter (fun(issue: Issue, entry: table): boolean|nil)|nil

---@class IssuesDetailTabDefinition
---@field key string
---@field label string
---@field icon AtlasIconStyle|nil
---@field mod IssuesDetailTabModule
