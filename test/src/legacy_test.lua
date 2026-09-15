-- aICQ's migrations: their tables exist after the boot, and `legacy.copy`
-- moves the stand's app_chat_* rows over once — between tables of this
-- test's own, so a real application's rows are never touched.
local test = require("test")
local sql = require("sql")
local legacy = require("legacy")

local OLD = "aicq_test_legacy"
local NEW = "aicq_test_target"
local COLUMNS = {"owner_id", "contact_id", "created_at"}

local function exec(db: any, query: string, params: any?)
    local _, err = db:execute(query, params or {})
    if err then error(tostring(err)) end
end

local function rows(db: any, query: string, params: any?): any
    local found, err = db:query(query, params or {})
    if err then error(tostring(err)) end
    return found or {}
end

local function table_sql(name: string): string
    return "CREATE TABLE " .. name .. " (owner_id TEXT NOT NULL, contact_id TEXT NOT NULL,"
        .. " created_at TEXT NOT NULL, PRIMARY KEY (owner_id, contact_id))"
end

local function define_tests()
    test.describe("aICQ migrations", function()
        test.it("the migrations created aICQ's three tables, and the old names are the stand's", function()
            local db = assert(sql.get("app:db"))
            local found = rows(db, "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'chicago_aicq_%'"
                .. " ORDER BY name")
            db:release()
            local names = {}
            for _, row in ipairs(found) do names[#names + 1] = row.name end
            test.eq(table.concat(names, "|"), "chicago_aicq_contacts|chicago_aicq_dismissed|chicago_aicq_messages")
            test.eq(legacy.CONTACTS .. "|" .. legacy.MESSAGES .. "|" .. legacy.DISMISSED,
                "app_chat_contacts|app_chat_messages|app_chat_dismissed")
        end)

        test.it("copy: every row once; a row already there wins; no old table is nothing to do", function()
            local db = assert(sql.get("app:db"))
            exec(db, "DROP TABLE IF EXISTS " .. OLD)
            exec(db, "DROP TABLE IF EXISTS " .. NEW)
            exec(db, table_sql(NEW))

            local none, nerr = legacy.copy(db, "sqlite", OLD, NEW, COLUMNS)
            test.eq(none, 0, "no old table: nothing to move, and no error — " .. tostring(nerr))

            exec(db, table_sql(OLD))
            test.eq(legacy.copy(db, "sqlite", OLD, NEW, COLUMNS), 0, "an empty old table: nothing to move")

            exec(db, "INSERT INTO " .. OLD .. " (owner_id, contact_id, created_at) VALUES ($1, $2, $3), ($4, $5, $6)",
                {"u-anna", "u-bob", "2026-09-15T10:00:00Z", "u-bob", "u-anna", "2026-09-15T11:00:00Z"})
            exec(db, "INSERT INTO " .. NEW .. " (owner_id, contact_id, created_at) VALUES ($1, $2, $3)",
                {"u-anna", "u-bob", "2026-09-16T09:00:00Z"})
            local moved, merr = legacy.copy(db, "sqlite", OLD, NEW, COLUMNS)
            test.eq(moved, 1, "only the row not already there — " .. tostring(merr))
            local kept = rows(db, "SELECT created_at FROM " .. NEW .. " WHERE owner_id = $1 AND contact_id = $2",
                {"u-anna", "u-bob"})[1]
            test.eq(kept.created_at, "2026-09-16T09:00:00Z", "the row written since wins")
            test.eq(#rows(db, "SELECT owner_id FROM " .. NEW), 2)

            test.eq(legacy.copy(db, "sqlite", OLD, NEW, COLUMNS), 0, "run again: nothing new")

            exec(db, "DROP TABLE IF EXISTS " .. OLD)
            exec(db, "DROP TABLE IF EXISTS " .. NEW)
            db:release()
        end)

        -- The stand's own tables, in the stand's own schema (src/app/chat
        -- 01_people and 02_dismissed), made here where the boot had none: the
        -- migrations' plans must carry every column across.
        test.it("move: the stand's contacts, messages and dismissals land in aICQ's tables, every column", function()
            local db = assert(sql.get("app:db"))
            exec(db, "CREATE TABLE " .. legacy.CONTACTS .. " (owner_id TEXT NOT NULL, contact_id TEXT NOT NULL,"
                .. " created_at TEXT NOT NULL, PRIMARY KEY (owner_id, contact_id))")
            exec(db, "CREATE TABLE " .. legacy.MESSAGES .. " (id TEXT PRIMARY KEY, from_id TEXT NOT NULL,"
                .. " to_id TEXT NOT NULL, body TEXT NOT NULL, created_at TEXT NOT NULL, read_at TEXT NULL)")
            exec(db, "CREATE TABLE " .. legacy.DISMISSED .. " (owner_id TEXT NOT NULL, other_id TEXT NOT NULL,"
                .. " dismissed_at TEXT NOT NULL, PRIMARY KEY (owner_id, other_id))")
            exec(db, "INSERT INTO " .. legacy.CONTACTS .. " VALUES ($1, $2, $3)", {"lg-anna", "lg-bob", "2026-09-15T10:00:00Z"})
            exec(db, "INSERT INTO " .. legacy.MESSAGES .. " VALUES ($1, $2, $3, $4, $5, $6)",
                {"lg-m1", "lg-bob", "lg-anna", "hi", "2026-09-15T10:01:00Z", "2026-09-15T10:02:00Z"})
            exec(db, "INSERT INTO " .. legacy.DISMISSED .. " VALUES ($1, $2, $3)", {"lg-anna", "lg-carol", "2026-09-15T10:03:00Z"})

            local people_moved, perr = legacy.move(db, "sqlite", legacy.PLAN.people)
            local dismissed_moved, derr = legacy.move(db, "sqlite", legacy.PLAN.dismissed)
            test.eq(tostring(people_moved) .. "|" .. tostring(dismissed_moved), "2|1", tostring(perr or derr))

            local contact = rows(db, "SELECT owner_id, contact_id, created_at FROM " .. legacy.TABLES.contacts
                .. " WHERE owner_id = $1", {"lg-anna"})[1]
            test.eq(contact.contact_id .. "|" .. contact.created_at, "lg-bob|2026-09-15T10:00:00Z")
            local message = rows(db, "SELECT from_id, to_id, body, created_at, read_at FROM " .. legacy.TABLES.messages
                .. " WHERE id = $1", {"lg-m1"})[1]
            test.eq(table.concat({message.from_id, message.to_id, message.body, message.created_at, message.read_at}, "|"),
                "lg-bob|lg-anna|hi|2026-09-15T10:01:00Z|2026-09-15T10:02:00Z", "a read message stays read")
            local dismissal = rows(db, "SELECT other_id, dismissed_at FROM " .. legacy.TABLES.dismissed
                .. " WHERE owner_id = $1", {"lg-anna"})[1]
            test.eq(dismissal.other_id .. "|" .. dismissal.dismissed_at, "lg-carol|2026-09-15T10:03:00Z")

            exec(db, "DELETE FROM " .. legacy.TABLES.contacts .. " WHERE owner_id = $1", {"lg-anna"})
            exec(db, "DELETE FROM " .. legacy.TABLES.messages .. " WHERE id = $1", {"lg-m1"})
            exec(db, "DELETE FROM " .. legacy.TABLES.dismissed .. " WHERE owner_id = $1", {"lg-anna"})
            for _, name in ipairs({legacy.CONTACTS, legacy.MESSAGES, legacy.DISMISSED}) do
                exec(db, "DROP TABLE " .. name)
            end
            db:release()
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
