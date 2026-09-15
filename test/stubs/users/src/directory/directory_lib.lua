-- Harness stand-in for kickside.users.directory:directory_lib, the users
-- directory adapter behind kickside.contract:directory. Users only, written
-- to the behaviour of kickside/users 0.1.41 rather than copied from it:
--
--   search  — the query, lower-cased, as a substring of the label (the full
--             name, else the e-mail, else the id), of the e-mail or of the
--             id, over user_repo.list() called WITHOUT options — that is the
--             50 newest accounts; the answer cut to `limit` (20 by default,
--             1 to 100);
--   resolve — each ref by the account's label and e-mail; an id the list
--             does not hold comes back labelled by the id, no sublabel;
--   exists  — user_repo.get.
local user_repo = require("user_repo")

local directory = {}

local function lower(value: any): string
    return string.lower(tostring(value or ""))
end

local function label(user: any): string
    if type(user.full_name) == "string" and user.full_name ~= "" then return user.full_name end
    return tostring(user.email or user.user_id)
end

local function limit_of(value: any): integer
    local count = math.tointeger(value)
    if count == nil then return 20 end
    if count < 1 then return 1 end
    if count > 100 then return 100 end
    return count
end

local function has(haystack: any, needle: string): boolean
    return needle == "" or string.find(lower(haystack), needle, 1, true) ~= nil
end

function directory.search(input: any): any
    input = type(input) == "table" and input or {}
    local query = lower(input.query)
    local limit = limit_of(input.limit)
    local found: any = {}
    for _, user in ipairs(user_repo.list() or {}) do
        if #found < limit and (has(label(user), query) or has(user.email, query) or has(user.user_id, query)) then
            found[#found + 1] = {type = "user", id = user.user_id, label = label(user), sublabel = user.email or ""}
        end
    end
    return {principals = found}
end

function directory.resolve(input: any): any
    input = type(input) == "table" and input or {}
    local by_id: any = {}
    for _, user in ipairs(user_repo.list() or {}) do by_id[user.user_id] = user end
    local found: any = {}
    for _, ref in ipairs(input.refs or {}) do
        local user = by_id[ref.id]
        if user then
            found[#found + 1] = {type = "user", id = ref.id, label = label(user), sublabel = user.email or ""}
        else
            found[#found + 1] = {type = "user", id = ref.id, label = ref.id, sublabel = ""}
        end
    end
    return {principals = found}
end

function directory.exists(input: any): any
    input = type(input) == "table" and input or {}
    if type(input.id) ~= "string" or input.id == "" then return {exists = false} end
    return {exists = user_repo.get(input.id) ~= nil}
end

return directory
