-- aICQ people (docs/aicq-people.md §3): one-way contact lists and the
-- messages between people. A message row is written by the sender's own
-- window under the sender's actor; `read_at` is set when the recipient reads
-- it. Contacts are one-way, as in ICQ without authorization.
--
-- One SQL serves both drivers: TEXT columns and no defaults — the library
-- writes the timestamps itself, fixed width with nanoseconds, so the text
-- sorts as the time does.
--
-- Where the stand kept aICQ's rows in app_chat_contacts and app_chat_messages,
-- they are copied over once (legacy.PLAN.people); elsewhere there is nothing
-- to copy.
local legacy = require("legacy")

local CONTACTS = legacy.TABLES.contacts
local MESSAGES = legacy.TABLES.messages

local STATEMENTS = {
    {CONTACTS, "CREATE TABLE " .. CONTACTS .. [[ (
            owner_id TEXT NOT NULL,
            contact_id TEXT NOT NULL,
            created_at TEXT NOT NULL,
            PRIMARY KEY (owner_id, contact_id)
        )
    ]]},
    {MESSAGES, "CREATE TABLE " .. MESSAGES .. [[ (
            id TEXT PRIMARY KEY,
            from_id TEXT NOT NULL,
            to_id TEXT NOT NULL,
            body TEXT NOT NULL,
            created_at TEXT NOT NULL,
            read_at TEXT NULL
        )
    ]]},
    {"the unread index", "CREATE INDEX idx_chicago_aicq_messages_unread ON " .. MESSAGES .. " (to_id, read_at)"},
    {"the pair index", "CREATE INDEX idx_chicago_aicq_messages_pair ON " .. MESSAGES .. " (from_id, to_id, created_at)"},
}

local function up_on(driver: string): any
    return function(db: any)
        for _, step in ipairs(STATEMENTS) do
            local _, err = db:execute(step[2])
            if err then error("Failed to create " .. step[1] .. ": " .. tostring(err)) end
        end
        local moved, merr = legacy.move(db, driver, legacy.PLAN.people)
        if moved == nil then error("Failed to move the stand's rows: " .. tostring(merr)) end
    end
end

local function drop(db: any)
    for _, name in ipairs({MESSAGES, CONTACTS}) do
        local _, err = db:execute("DROP TABLE IF EXISTS " .. name)
        if err then error("Failed to drop " .. name .. ": " .. tostring(err)) end
    end
end

return require("migration").define(function()
    migration("Create chicago_aicq_contacts and chicago_aicq_messages, moving the stand's rows", function()
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
