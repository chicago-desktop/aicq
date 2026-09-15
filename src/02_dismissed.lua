-- aICQ Not in List (docs/aicq-people.md §1, §4): whom a person took off the
-- list of those who wrote to them. A message from that person created after
-- `dismissed_at` brings them back; adding them as a contact deletes the row.
--
-- Where the stand kept dismissals in app_chat_dismissed, they are copied over
-- once (legacy.PLAN.dismissed).
local legacy = require("legacy")

local DISMISSED = legacy.TABLES.dismissed

local CREATE = "CREATE TABLE " .. DISMISSED .. [[ (
        owner_id TEXT NOT NULL,
        other_id TEXT NOT NULL,
        dismissed_at TEXT NOT NULL,
        PRIMARY KEY (owner_id, other_id)
    )
]]

local function up_on(driver: string): any
    return function(db: any)
        local _, err = db:execute(CREATE)
        if err then error("Failed to create " .. DISMISSED .. ": " .. tostring(err)) end
        local moved, merr = legacy.move(db, driver, legacy.PLAN.dismissed)
        if moved == nil then error("Failed to move the stand's dismissals: " .. tostring(merr)) end
    end
end

local function drop(db: any)
    local _, err = db:execute("DROP TABLE IF EXISTS " .. DISMISSED)
    if err then error("Failed to drop " .. DISMISSED .. ": " .. tostring(err)) end
end

return require("migration").define(function()
    migration("Create windows_aicq_dismissed, moving the stand's dismissals", function()
        database("postgres", function()
            up(up_on("postgres"))
            down(drop)
        end)
        database("sqlite", function()
            up(up_on("sqlite"))
            down(drop)
        end)
    end)
end)
