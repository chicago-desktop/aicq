-- aICQ between computers (docs/aicq-network.md §4): the name of a person on
-- another computer, as last heard in a roster. The users directory of this
-- node knows nothing of them, and a contact who is offline still needs a
-- name in the list. `id` is net:<node>:<user_id>.
--
-- One SQL serves both drivers: TEXT columns and no defaults, as in
-- 01_people.
local REMOTE = "chicago_aicq_remote"

local CREATE = "CREATE TABLE " .. REMOTE .. [[ (
        id TEXT PRIMARY KEY,
        node TEXT NOT NULL,
        name TEXT NOT NULL,
        seen_at TEXT NOT NULL
    )
]]

local function create(db: any)
    local _, err = db:execute(CREATE)
    if err then error("Failed to create " .. REMOTE .. ": " .. tostring(err)) end
end

local function drop(db: any)
    local _, err = db:execute("DROP TABLE IF EXISTS " .. REMOTE)
    if err then error("Failed to drop " .. REMOTE .. ": " .. tostring(err)) end
end

return require("migration").define(function()
    migration("Create chicago_aicq_remote, the names of people on other computers", function()
        database("postgres", function()
            up(create)
            down(drop)
        end)
        database("sqlite", function()
            up(create)
            down(drop)
        end)
    end)
end)
