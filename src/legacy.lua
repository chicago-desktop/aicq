-- The one-time move of what the stand kept before aICQ was a module: its
-- src/app/chat wrote the tables app_chat_contacts, app_chat_messages and
-- app_chat_dismissed. The migrations copy those rows into this module's
-- tables once, so switching the stand to the module keeps everyone's contact
-- list, history and dismissals; an application that never had them has
-- nothing to move.
--
-- The table names are parameters of `copy`, not constants inside it, so a
-- test copies between tables of its own and never touches a real
-- application's rows.

local legacy = {}

-- Where the stand kept aICQ's rows while it lived in its src/app/chat.
legacy.CONTACTS = "app_chat_contacts"
legacy.MESSAGES = "app_chat_messages"
legacy.DISMISSED = "app_chat_dismissed"

-- aICQ's own tables, named once: the migrations create them by these names.
legacy.TABLES = {
    contacts = "chicago_aicq_contacts",
    messages = "chicago_aicq_messages",
    dismissed = "chicago_aicq_dismissed",
}

-- What each migration moves: the stand's table, aICQ's, and the columns.
legacy.PLAN = {
    people = {
        {from = legacy.CONTACTS, to = legacy.TABLES.contacts, columns = {"owner_id", "contact_id", "created_at"}},
        {from = legacy.MESSAGES, to = legacy.TABLES.messages,
            columns = {"id", "from_id", "to_id", "body", "created_at", "read_at"}},
    },
    dismissed = {
        {from = legacy.DISMISSED, to = legacy.TABLES.dismissed, columns = {"owner_id", "other_id", "dismissed_at"}},
    },
}

-- exists(db, driver, name) -> whether that table exists | nil, reason.
function legacy.exists(db: any, driver: string, name: string): (boolean?, string?)
    local rows: any, err: any
    if driver == "postgres" then
        rows, err = db:query("SELECT to_regclass($1) AS found", {name})
    else
        rows, err = db:query("SELECT name AS found FROM sqlite_master WHERE type = 'table' AND name = $1", {name})
    end
    if err then return nil, tostring(err) end
    local first: any = type(rows) == "table" and rows[1] or nil
    return first ~= nil and first.found ~= nil, nil
end

-- copy(db, driver, from, to, columns) -> how many rows were copied | nil, reason
--
-- Copies every row of `from` into `to`, the named columns only, when `from`
-- exists. A row whose key is already in `to` stays as it is: running the copy
-- again moves nothing twice, and nothing written since is overwritten. No
-- `from` table is not an error.
function legacy.copy(db: any, driver: string, from: string, to: string, columns: {string}): (integer?, string?)
    local present, err = legacy.exists(db, driver, from)
    if present == nil then return nil, "could not tell whether " .. from .. " exists: " .. tostring(err) end
    if not present then return 0, nil end
    local list = table.concat(columns, ", ")
    -- `WHERE true`: SQLite reads `ON CONFLICT` after a bare SELECT as a join's ON.
    local result, xerr = db:execute("INSERT INTO " .. to .. " (" .. list .. ") SELECT " .. list
        .. " FROM " .. from .. " WHERE true ON CONFLICT DO NOTHING")
    if xerr then return nil, "could not copy " .. from .. " into " .. to .. ": " .. tostring(xerr) end
    return math.tointeger(tonumber(type(result) == "table" and result.rows_affected or 0)) or 0, nil
end

-- move(db, driver, plan) -> how many rows were copied in all | nil, reason:
-- every step of one of legacy.PLAN's lists, stopping at the first refusal.
function legacy.move(db: any, driver: string, plan: any): (integer?, string?)
    local total = 0
    for _, step in ipairs(plan) do
        local copied, err = legacy.copy(db, driver, tostring(step.from), tostring(step.to), step.columns :: {string})
        if copied == nil then return nil, err end
        total = total + copied
    end
    return total, nil
end

return legacy
