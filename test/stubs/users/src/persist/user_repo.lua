-- Harness stand-in for kickside.users.persist:user_repo, over the table
-- harness_users that people_test creates and fills. The two calls the
-- directory adapter makes behave as the real ones do:
--   list(options) — the newest first, `options.limit` or 50, `offset`: the
--                   adapter calls it without options, so it sees 50 accounts;
--   get(identifier) — by user_id, else by the e-mail in lower case.
local sql = require("sql")

local repo = {}

repo.TABLE = "harness_users"

local function rows(query: string, params: any): any
    local db = assert(sql.get("app:db"))
    local found, err = db:query(query, params)
    db:release()
    if err then error(tostring(err)) end
    return found or {}
end

function repo.list(options: any): any
    options = options or {}
    return rows("SELECT user_id, email, full_name, status, created_at FROM " .. repo.TABLE
        .. " ORDER BY created_at DESC LIMIT $1 OFFSET $2", {options.limit or 50, options.offset or 0})
end

function repo.get(identifier: any): any
    local found = rows("SELECT user_id, email, full_name, status FROM " .. repo.TABLE .. " WHERE user_id = $1", {identifier})
    if found[1] then return found[1] end
    found = rows("SELECT user_id, email, full_name, status FROM " .. repo.TABLE .. " WHERE email = $1",
        {string.lower(tostring(identifier))})
    return found[1]
end

return repo
