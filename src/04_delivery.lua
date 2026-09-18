-- aICQ between computers (docs/aicq-network.md §5): whether a message to
-- another computer has arrived there. `delivered_at` is set when that
-- computer's messenger confirms it; `failed` names why it never will. A
-- message between two people of this computer ignores both columns.
local MESSAGES = "chicago_aicq_messages"

local STEPS = {
    {"delivered_at", "ALTER TABLE " .. MESSAGES .. " ADD COLUMN delivered_at TEXT NULL"},
    {"failed", "ALTER TABLE " .. MESSAGES .. " ADD COLUMN failed TEXT NULL"},
}

local function add(db: any)
    for _, step in ipairs(STEPS) do
        local _, err = db:execute(step[2])
        if err then error("Failed to add " .. step[1] .. ": " .. tostring(err)) end
    end
end

local function drop(db: any)
    for _, name in ipairs({"failed", "delivered_at"}) do
        local _, err = db:execute("ALTER TABLE " .. MESSAGES .. " DROP COLUMN " .. name)
        if err then error("Failed to drop " .. name .. ": " .. tostring(err)) end
    end
end

return require("migration").define(function()
    migration("Add delivered_at and failed to chicago_aicq_messages, for messages to other computers", function()
        database("postgres", function()
            up(add)
            down(drop)
        end)
        database("sqlite", function()
            up(add)
            down(drop)
        end)
    end)
end)
