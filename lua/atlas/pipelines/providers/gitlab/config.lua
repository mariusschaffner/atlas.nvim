-- Example:
--   require("atlas").setup({
--     pipelines = {
--       ---@type AtlasGitLabPipelinesConfig
--       gitlab = {
--         views = {
--           { name = "All", key = "1" },
--         },
--       },
--     },
--   })

---@class AtlasGitLabPipelinesViewConfig : PipelinesViewConfig

---@class AtlasGitLabPipelinesConfig
---@field views AtlasGitLabPipelinesViewConfig[]|nil
