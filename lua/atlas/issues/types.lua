--------------------------------------------------------------------------------
-- User
--------------------------------------------------------------------------------

---@class IssueUser
---@field id integer|nil
---@field account_id string|nil
---@field display_name string

--------------------------------------------------------------------------------
-- Issue
--------------------------------------------------------------------------------

---@class IssueRef
---@field key string
---@field title string|nil

---@class Issue : IssueRef
---@field title string
---@field status string|nil
---@field status_id string|nil
---@field type IssueType|nil
---@field assignee IssueUser|nil
---@field reporter IssueUser|nil
---@field labels IssueLabel[]|nil
---@field milestone IssueMilestone|nil
---@field story_points number|nil
---@field duedate string|nil
---@field parent IssueRef|nil
---@field url string|nil
---@field created_at string|nil
---@field updated_at string|nil
---@field closed_at string|nil
---@field comment_count integer|nil
---@field is_subscribed boolean|nil

---@class IssueDetails
---@field description string
---@field assignees IssueUser[]
---@field labels IssueLabel[]
---@field milestone IssueMilestone|nil

--------------------------------------------------------------------------------
-- Dates
--------------------------------------------------------------------------------

---@class IssueDates
---@field work_item_id string GraphQL global ID used to write dates back (e.g. "gid://gitlab/WorkItem/123").
---@field start_date string|nil
---@field due_date string|nil

--------------------------------------------------------------------------------
-- Label
--------------------------------------------------------------------------------

---@class IssueLabel
---@field name string
---@field color string|nil

--------------------------------------------------------------------------------
-- Milestone
--------------------------------------------------------------------------------

---@class IssueMilestone
---@field id integer|nil
---@field title string
---@field web_url string|nil
---@field due_date string|nil
---@field start_date string|nil
---@field description string|nil
---@field state string|nil "active"|"closed"

--------------------------------------------------------------------------------
-- Group
--------------------------------------------------------------------------------

---@class IssuesGroup
---@field kind "issue"|"milestone"
---@field key string Unique key for collapse-state + selection: issue.key, or "milestone:<id>".
---@field issue Issue|nil Present when kind == "issue".
---@field milestone IssueMilestone|nil Present when kind == "milestone".
---@field children (Issue|IssuesGroup)[] Issue[] when kind == "issue" (flat); IssuesGroup[] when kind == "milestone".

--------------------------------------------------------------------------------
-- Type
--------------------------------------------------------------------------------

---@class IssueType
---@field id string
---@field name string
---@field description string|nil
---@field subtask boolean

--------------------------------------------------------------------------------
-- Transition
--------------------------------------------------------------------------------

---@class IssueTransition
---@field id string
---@field name string
---@field to_status_id string|nil
---@field to_status_name string|nil
---@field to_status_category string|nil
---@field to_status_color string|nil

--------------------------------------------------------------------------------
-- Comment
--------------------------------------------------------------------------------

---@class IssueComment
---@field id string
---@field self string|nil
---@field url string|nil
---@field author IssueUser|nil
---@field body string|nil
---@field created string|nil
---@field updated string|nil
---@field parent_id string|number|nil
---@field children IssueComment[]|nil
---@field reactions table<string, number>|nil
---@field deleted boolean|nil
---@field _raw table|nil

--------------------------------------------------------------------------------
-- History
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- Activity / reactions
--------------------------------------------------------------------------------

---@class IssueActivityBodyHlSpan
---@field start_col integer
---@field end_col integer
---@field hl_group string

---@alias IssueActivityBodyHlFn fun(row: string, row_index: integer): IssueActivityBodyHlSpan[]|nil

---@class IssueActivityEntry
---@field kind string
---@field actor IssueUser|nil
---@field date string|nil
---@field label string|nil
---@field body string|nil
---@field body_hl IssueActivityBodyHlFn|nil
---@field deleted boolean|nil
---@field always_render boolean|nil

---@alias IssueConversationItemKind "comment"|"activity"

---@class IssueConversationItem
---@field id string
---@field kind IssueConversationItemKind
---@field created_at string
---@field entity IssueComment|IssueActivityEntry

---@class IssueReactionOption
---@field key string
---@field emoji string
---@field label string
