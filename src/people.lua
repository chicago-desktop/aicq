-- aICQ people: the data half of "people in aICQ" (docs/aicq-people.md §2–§5).
--
-- Runs in the calling window's process, under the caller's actor. The
-- sender and the reader are always the actor — `security.actor():id()`,
-- measured to be the users table id of the person logged on — and never a
-- field of a message: no function here takes a user id for "me". Rows live
-- in windows_aicq_contacts and windows_aicq_messages (migration windows.aicq:01_people);
-- the database is the one the application names (people.db_id).
--
-- Other people's names come through the users module's own lookup, the
-- contract kickside.contract:directory, behind the gate its endpoints have
-- (`access` on kickside.users.directory:*): without that check a window
-- would read past the users module's authorization.
--
-- Every function answers `value, nil` or `nil, reason`; a denial is named,
-- not turned into an empty list.
--
-- The messenger and the presence service use the parts that need no actor:
-- the watch table, a message's two ends, the unread count by an explicit id
-- and the presence tally. The tray items themselves are windows.aicq:aicq's.

local sql = require("sql")
local security = require("security")
local contract = require("contract")
local process = require("process")
local channel = require("channel")
local time = require("time")
local uuid = require("uuid")
local registry = require("registry")
local aicq = require("aicq")

local people = {}

-- The database is named once, by the application: the requirement
-- windows.aicq:target_db writes it into this migration's meta.target_db,
-- and it is read back from there (people.db_id), as the shell's persist does.
people.MIGRATION = "windows.aicq:01_people"

-- The names both halves use are windows.aicq:aicq's; one place for each.
-- Windows → messenger: WATCH, UNWATCH; messenger → windows: NEW; library →
-- messenger: READ, after mark_read (the windows tell their contact list
-- with aicq.SEEN, a topic of their own).
people.MESSENGER = aicq.MESSENGER
people.PRESENCE = aicq.SERVICE
people.WATCH = aicq.WATCH
people.UNWATCH = aicq.UNWATCH
people.NEW = aicq.NEW
people.READ = aicq.READ
-- The data half's own topics. Library → messenger: SENT. Messenger →
-- presence: REFRESH. Library → presence: WHO, answered on ONLINE.
people.SENT = "aicq.sent"
people.REFRESH = "aicq.refresh"
people.WHO = "aicq.who"
people.ONLINE = "aicq.online"

people.DIRECTORY = "kickside.contract:directory"
people.GATES = {
    search = "kickside.users.directory:directory_search",
    resolve = "kickside.users.directory:directory_resolve",
    exists = "kickside.users.directory:directory_exists",
}

people.FIND_MAX = 20
-- The most the directory adapter answers in one search.
people.DIRECTORY_MAX = 100
-- How many accounts the users directory reads at all: its adapter lists
-- them with user_repo.list() and no options, which takes the 50 newest
-- (kickside.users.persist:user_repo). An older account is found by no query
-- and its name does not resolve — the users module's limit, reported, not
-- worked around here.
people.DIRECTORY_WINDOW = 50
people.HISTORY_DEFAULT = 200
people.HISTORY_MAX = 1000
people.BODY_MAX = 4000
people.WHO_BUDGET = "2s"

-- A message body as it arrives: one parse rule for the whole of aICQ.
people.unwrap = aicq.unwrap

local CONTACTS = "windows_aicq_contacts"
local MESSAGES = "windows_aicq_messages"
local DISMISSED = "windows_aicq_dismissed"

-- ─── helpers ────────────────────────────────────────────────────────────

local function trim(value: any): string
    if type(value) ~= "string" then return "" end
    return (string.gsub(value, "^%s*(.-)%s*$", "%1"))
end

-- letters(text) -> how many characters: UTF-8 lead bytes, not bytes.
local function letters(text: string): integer
    local _, count = string.gsub(text, "[^\128-\191]", "")
    return math.tointeger(count) or 0
end

-- Fixed width with nanoseconds: ORDER BY created_at is the order of
-- sending, within one second too.
local function stamp(): string
    return time.now():utc():format("2006-01-02T15:04:05.000000000Z")
end

local function whole(value: any): integer?
    return math.tointeger(tonumber(value))
end

-- display_name(user) -> the name a users row is shown by: the full name when
-- there is one, else the e-mail, else the id. The same rule the stand's logon
-- names the person by in the Start menu; one copy of it for all of aICQ.
function people.display_name(user: any): string
    local display = type(user.full_name) == "string" and user.full_name ~= "" and user.full_name or user.email
    return tostring(display or user.user_id)
end

-- A table, not a local: an error under pcall splits upvalues in go-lua.
local named: any = {db = nil}

-- db_id() -> the database aICQ keeps its tables in | nil, reason.
function people.db_id(): (string?, string?)
    if named.db then return tostring(named.db), nil end
    local entry: any, err = registry.get(people.MIGRATION)
    if not entry then return nil, people.MIGRATION .. " (it names the database) is unreadable: " .. tostring(err) end
    local meta: any = entry.meta or {}
    local id = meta.target_db
    if type(id) ~= "string" or id == "" then return nil, people.MIGRATION .. " has no meta.target_db" end
    named.db = id
    return tostring(id), nil
end

local function open(): (any, string?)
    local id, iderr = people.db_id()
    if not id then return nil, iderr end
    local db, err = sql.get(id)
    if not db then return nil, "the database is unavailable: " .. tostring(err) end
    return db, nil
end

-- read(query, params) -> rows | nil, reason: one query on a connection of its own.
local function read(query: string, params: any): (any, string?)
    local db, err = open()
    if not db then return nil, err end
    local rows, qerr = db:query(query, params)
    db:release()
    if qerr then return nil, tostring(qerr) end
    return rows or {}, nil
end

local function write(query: string, params: any): (any, string?)
    local db, err = open()
    if not db then return nil, err end
    local result, xerr = db:execute(query, params)
    db:release()
    if xerr then return nil, tostring(xerr) end
    return result or {}, nil
end

-- person() -> id | nil, reason: who this window runs under. A desktop
-- without a logon runs its windows under the shell's own actor, which is
-- not a person: a session's actor carries `user_id` in its meta
-- (kickside.users:session), a service actor does not.
local function person(): (string?, string?)
    local actor: any = people.deps.security.actor()
    if not actor then return nil, "no one is logged on: the window runs without an actor" end
    local id = tostring(actor:id())
    local meta: any = actor:meta() or {}
    if tostring(meta.user_id or "") ~= id then
        return nil, "the window runs under " .. id .. ", which is not a logged-on person"
    end
    return id, nil
end

local function gate(op: string): string?
    if people.deps.security.can("access", people.GATES[op]) == true then return nil end
    return "the users directory (" .. op .. ") is not granted to your account (" .. people.GATES[op] .. ")"
end

-- The directory's answer back as a users row: its label is the full name,
-- else the e-mail, else the id (the display_name rule), and its sublabel is
-- the e-mail. An account the directory does not know comes back with the
-- id as label and no sublabel.
local function row_of(principal: any): any
    local id = tostring(principal.id or "")
    local label = type(principal.label) == "string" and principal.label or ""
    local email = type(principal.sublabel) == "string" and principal.sublabel ~= "" and principal.sublabel or nil
    local full_name = (label ~= "" and label ~= email and label ~= id) and label or nil
    return {user_id = id, email = email, full_name = full_name}
end

local function principals_of(answer: any): any
    if type(answer) == "table" and type(answer.principals) == "table" then return answer.principals end
    return {}
end

local function public(row: any): any
    return {id = row.user_id, name = people.display_name(row), uin = people.uin(row.user_id)}
end

local function by_name(a: any, b: any): boolean
    local left, right = string.lower(tostring(a.name)), string.lower(tostring(b.name))
    if left ~= right then return left < right end
    return tostring(a.id) < tostring(b.id)
end

-- The contact list's order: the contacts by name, then Not in List with the
-- newest conversation first.
local function in_order(a: any, b: any): boolean
    if a.listed ~= b.listed then return a.listed == true end
    if not a.listed and a.last_at ~= b.last_at then return tostring(a.last_at or "") > tostring(b.last_at or "") end
    return by_name(a, b)
end

local function unread_of(id: string): (any, string?)
    local rows, err = read("SELECT from_id, COUNT(*) AS n FROM " .. MESSAGES
        .. " WHERE to_id = $1 AND read_at IS NULL GROUP BY from_id", {id})
    if not rows then return nil, err end
    local out: any = {}
    for _, row in ipairs(rows) do out[tostring(row.from_id)] = whole(row.n) or 0 end
    return out, nil
end

-- conversations(id) -> {[peer] = {last_at, from_at, dismissed_at}}: for each
-- person the caller has exchanged messages with, the newest message either
-- way, the newest one FROM them, and when the caller dismissed them. The
-- timestamps are the library's fixed-width text, so they compare as text.
local function conversations(id: string): (any, string?)
    local rows, err = read("SELECT from_id, to_id, MAX(created_at) AS newest FROM " .. MESSAGES
        .. " WHERE from_id = $1 OR to_id = $1 GROUP BY from_id, to_id", {id})
    if not rows then return nil, err end
    local out: any = {}
    for _, row in ipairs(rows) do
        local from, to, at = tostring(row.from_id), tostring(row.to_id), tostring(row.newest)
        local peer = from == id and to or from
        local talk: any = out[peer] or {}
        if talk.last_at == nil or at > talk.last_at then talk.last_at = at end
        if from == peer then talk.from_at = at end
        out[peer] = talk
    end
    local dismissed, derr = read("SELECT other_id, dismissed_at FROM " .. DISMISSED .. " WHERE owner_id = $1", {id})
    if not dismissed then return nil, derr end
    for _, row in ipairs(dismissed) do
        local talk: any = out[tostring(row.other_id)]
        if talk then talk.dismissed_at = tostring(row.dismissed_at) end
    end
    return out, nil
end

-- known(id) -> whether the directory knows that account | nil, reason.
local function known(id: string): (boolean?, string?)
    local denied = gate("exists")
    if denied then return nil, denied end
    local answer, err = people.deps.directory("exists", {type = "user", id = id})
    if not answer then return nil, err end
    return answer.exists == true, nil
end

-- ─── the real roads, replaced in tests through people.deps ──────────────

-- The users directory under the caller's actor and scope, the way the
-- profile window opens its contract.
local function directory_call(method: string, args: any): (any, string?)
    local def, derr = contract.get(people.DIRECTORY)
    if derr or not def then return nil, "the users directory is unavailable: " .. tostring(derr) end
    local opener: any = def
    local actor, scope = security.actor(), security.scope()
    if actor and scope then opener = opener:with_actor(actor):with_scope(scope) end
    local instance: any, oerr = opener:open()
    if oerr or not instance then return nil, "the users directory did not open: " .. tostring(oerr) end
    local result, cerr = instance[method](instance, args)
    if cerr then return nil, "the users directory refused " .. method .. ": " .. tostring(cerr) end
    return result, nil
end

local function send_to(name: string, topic: string, body: any): (boolean, string?)
    local pid, lerr = process.registry.lookup(name)
    if not pid then return false, name .. " is not running (" .. tostring(lerr) .. ")" end
    local sent, serr = process.send(pid, topic, body)
    if not sent then return false, tostring(serr) end
    return true, nil
end

-- The presence service's answers come on a topic of their own, one
-- subscription per process, kept in a table.
local listening: any = {channel = nil}

local function who(): (any, string?)
    local pid, lerr = process.registry.lookup(people.PRESENCE)
    if not pid then return nil, "the presence service is not running (" .. tostring(lerr) .. ")" end
    if not listening.channel then
        listening.channel = process.listen(people.ONLINE, {message = true})
        if not listening.channel then return nil, "could not subscribe to " .. people.ONLINE end
    end
    local ch: any = listening.channel
    -- An answer left from an earlier question that timed out is not this one.
    while true do
        local stale = channel.select({ch:case_receive()}, true)
        if stale.default or not stale.ok then break end
    end
    local sent, serr = process.send(pid, people.WHO, {})
    if not sent then return nil, "the presence service was not asked: " .. tostring(serr) end
    local expiry = time.after(people.WHO_BUDGET)
    local picked = channel.select({ch:case_receive(), expiry:case_receive()})
    if picked.channel == expiry then return nil, "the presence service did not answer within " .. people.WHO_BUDGET end
    if not picked.ok then return nil, "the presence channel closed" end
    local body: any = people.unwrap(picked.value:payload())
    if type(body.online) ~= "table" then return nil, "the presence service answered without a list" end
    return body.online, nil
end

people.deps = {security = security, directory = directory_call, send = send_to, who = who}

-- ─── the caller's own data ──────────────────────────────────────────────

-- uin(user_id) -> a 9-digit number, the same for the same id on every run
-- and machine: a polynomial hash of the id's bytes modulo a prime, folded
-- into 100000000…999999999. Display only: two ids may share one.
function people.uin(user_id: any): integer
    local text = tostring(user_id or "")
    local hash = 0
    for index = 1, #text do
        hash = (hash * 257 + string.byte(text, index)) % 1000000007
    end
    return math.tointeger(100000000 + hash % 900000000) or 100000000
end

function people.me(): (any, string?)
    local id, why = person()
    if not id then return nil, why end
    local meta: any = people.deps.security.actor():meta() or {}
    local name = people.display_name({user_id = id, email = meta.email, full_name = meta.full_name})
    return {id = id, name = name, uin = people.uin(id)}, nil
end

-- online() -> {[user_id] = desktops} | nil, reason, from the presence service.
function people.online(): (any, string?)
    local map, err = people.deps.who()
    return map, err
end

function people.contacts(): (any, string?)
    local me, why = person()
    if not me then return nil, why end
    local rows, err = read("SELECT contact_id FROM " .. CONTACTS .. " WHERE owner_id = $1", {me})
    if not rows then return nil, "contacts not read: " .. tostring(err) end
    local counts, cerr = unread_of(me)
    if not counts then return nil, "unread messages not counted: " .. tostring(cerr) end
    local talks, terr = conversations(me)
    if not talks then return nil, "conversations not read: " .. tostring(terr) end

    -- The contacts, then whoever wrote to the caller and is not one, read or
    -- not — ICQ's "Not in List" — unless dismissed after their last message.
    -- Unread messages always show: the tray's envelope must point at a row.
    local refs: any, listed: any = {}, {}
    for _, row in ipairs(rows) do
        local id = tostring(row.contact_id)
        listed[id] = true
        refs[#refs + 1] = {type = "user", id = id}
    end
    for id, talk in pairs(talks) do
        if not listed[id] and talk.from_at ~= nil
            and ((counts[id] or 0) > 0 or talk.dismissed_at == nil or talk.from_at > talk.dismissed_at) then
            refs[#refs + 1] = {type = "user", id = id}
        end
    end
    local list: any = {}
    if #refs == 0 then return list, nil end

    local denied = gate("resolve")
    if denied then return nil, denied end
    local answer, rerr = people.deps.directory("resolve", {refs = refs})
    if not answer then return nil, rerr end
    local rows_by_id: any = {}
    for _, principal in ipairs(principals_of(answer)) do rows_by_id[tostring(principal.id)] = row_of(principal) end

    local online, owhy = people.online()
    for _, ref in ipairs(refs) do
        local item = public(rows_by_id[ref.id] or {user_id = ref.id})
        item.unread = counts[ref.id] or 0
        item.listed = listed[ref.id] == true
        item.last_at = talks[ref.id] and talks[ref.id].last_at or nil
        if online then
            item.desktops = whole(online[ref.id]) or 0
            item.online = item.desktops > 0
        end
        list[#list + 1] = item
    end
    table.sort(list, in_order)
    if not online then list.why = "presence not read: " .. tostring(owhy) end
    return list, nil
end

-- find(query) -> at most FIND_MAX {id, name, uin}. Three shapes: an exact
-- e-mail (the query has "@"), a UIN (nine digits), else a name prefix of
-- three letters or more against the full name only — a name query must not
-- turn into a way of listing e-mail addresses. The caller is left out.
function people.find(query: any): (any, string?)
    local me, why = person()
    if not me then return nil, why end
    local q = trim(query)
    if q == "" then return nil, "type an e-mail, a name or a UIN" end
    local shape, search = "name", q
    if string.find(q, "@", 1, true) then
        shape = "email"
    elseif string.match(q, "^%d%d%d%d%d%d%d%d%d$") then
        shape, search = "uin", ""
    elseif letters(q) < 3 then
        return nil, "a name needs three letters or more"
    end
    local denied = gate("search")
    if denied then return nil, denied end
    local meta: any = people.deps.security.actor():meta() or {}
    local wanted = string.lower(q)
    if shape == "email" and wanted == string.lower(tostring(meta.email or "")) then return {}, nil end

    local answer, err = people.deps.directory("search",
        {query = search, kinds = {"user"}, limit = people.DIRECTORY_MAX})
    if not answer then return nil, err end
    local principals = principals_of(answer)
    local number = whole(q)
    local found: any = {}
    for _, principal in ipairs(principals) do
        if type(principal) == "table" and principal.type == "user" and tostring(principal.id or "") ~= me then
            local row = row_of(principal)
            local hit = false
            if shape == "email" then
                hit = row.email ~= nil and string.lower(row.email) == wanted
            elseif shape == "uin" then
                hit = people.uin(row.user_id) == number
            else
                hit = row.full_name ~= nil and string.sub(string.lower(row.full_name), 1, #wanted) == wanted
            end
            if hit then found[#found + 1] = public(row) end
        end
    end
    if shape == "uin" and #found == 0 and #principals >= people.DIRECTORY_WINDOW then
        return nil, "UIN " .. q .. " is not among the " .. tostring(people.DIRECTORY_WINDOW)
            .. " newest accounts the users directory reads; search by e-mail or name"
    end
    -- An e-mail the directory did not list may still be an account older than
    -- its window: `exists` looks it up directly, and the answer says so
    -- instead of passing for "nobody".
    if shape == "email" and #found == 0 then
        local exists, kerr = known(q)
        if exists == nil then return nil, kerr end
        if exists then
            return nil, "an account with this e-mail exists, but it is not among the "
                .. tostring(people.DIRECTORY_WINDOW) .. " newest accounts the users directory reads"
        end
    end
    table.sort(found, by_name)
    local capped: any = {}
    for index = 1, math.min(#found, people.FIND_MAX) do capped[index] = found[index] end
    return capped, nil
end

function people.add(user_id: any): (any, string?)
    local me, why = person()
    if not me then return nil, why end
    local id = trim(user_id)
    if id == "" then return nil, "no account named" end
    if id == me then return nil, "you cannot add yourself" end
    local exists, kerr = known(id)
    if exists == nil then return nil, kerr end
    if not exists then return nil, "no such account: " .. id end
    -- A contact is not dismissed: a later Remove Contact leaves them in Not in
    -- List again, as anyone else who wrote.
    local cleared, cerr = write("DELETE FROM " .. DISMISSED .. " WHERE owner_id = $1 AND other_id = $2", {me, id})
    if not cleared then return nil, "contact not added: " .. tostring(cerr) end
    local result, err = write("INSERT INTO " .. CONTACTS .. " (owner_id, contact_id, created_at) VALUES ($1, $2, $3)"
        .. " ON CONFLICT (owner_id, contact_id) DO NOTHING", {me, id, stamp()})
    if not result then return nil, "contact not added: " .. tostring(err) end
    return true, nil
end

function people.remove(user_id: any): (any, string?)
    local me, why = person()
    if not me then return nil, why end
    local id = trim(user_id)
    if id == "" then return nil, "no account named" end
    local result, err = write("DELETE FROM " .. CONTACTS .. " WHERE owner_id = $1 AND contact_id = $2", {me, id})
    if not result then return nil, "contact not removed: " .. tostring(err) end
    return true, nil
end

-- dismiss(user_id) -> true: that person leaves the caller's Not in List
-- until they write again; `add` clears it.
function people.dismiss(user_id: any): (any, string?)
    local me, why = person()
    if not me then return nil, why end
    local id = trim(user_id)
    if id == "" then return nil, "no account named" end
    if id == me then return nil, "you cannot dismiss yourself" end
    local exists, kerr = known(id)
    if exists == nil then return nil, kerr end
    if not exists then return nil, "no such account: " .. id end
    local result, err = write("INSERT INTO " .. DISMISSED .. " (owner_id, other_id, dismissed_at) VALUES ($1, $2, $3)"
        .. " ON CONFLICT (owner_id, other_id) DO UPDATE SET dismissed_at = excluded.dismissed_at", {me, id, stamp()})
    if not result then return nil, "not dismissed: " .. tostring(err) end
    return true, nil
end

-- send(to_id, text) -> message id, nil, notice. The row is stored first;
-- the messenger is told after. A messenger that was not reached is the
-- third value, not a failure: the message is there and shows on the
-- recipient's next reload, and a window that took it for a failure would
-- send it twice.
function people.send(to_id: any, text: any): (any, string?, string?)
    local me, why = person()
    if not me then return nil, why, nil end
    local to = trim(to_id)
    local body = trim(text)
    if to == "" then return nil, "no recipient", nil end
    if to == me then return nil, "a message to yourself is not sent", nil end
    if body == "" then return nil, "the message is empty", nil end
    if letters(body) > people.BODY_MAX then
        return nil, "the message is longer than " .. tostring(people.BODY_MAX) .. " characters", nil
    end
    local exists, kerr = known(to)
    if exists == nil then return nil, kerr, nil end
    if not exists then return nil, "no such account: " .. to, nil end
    local id, iderr = uuid.v7()
    if not id then return nil, "no message id: " .. tostring(iderr), nil end
    local result, err = write("INSERT INTO " .. MESSAGES .. " (id, from_id, to_id, body, created_at, read_at)"
        .. " VALUES ($1, $2, $3, $4, $5, NULL)", {id, me, to, body, stamp()})
    if not result then return nil, "the message was not stored: " .. tostring(err), nil end
    local told, terr = people.deps.send(people.MESSENGER, people.SENT, {message_id = id, to_id = to})
    if not told then return id, nil, "the message is stored, but the messenger did not hear of it: " .. tostring(terr) end
    return id, nil, nil
end

-- history(user_id, limit) -> the last `limit` messages between the caller
-- and that person, oldest first.
function people.history(user_id: any, limit: any): (any, string?)
    local me, why = person()
    if not me then return nil, why end
    local peer = trim(user_id)
    if peer == "" then return nil, "no account named" end
    local count = whole(limit) or people.HISTORY_DEFAULT
    if count < 1 then count = 1 end
    if count > people.HISTORY_MAX then count = people.HISTORY_MAX end
    local rows, err = read("SELECT id, from_id, to_id, body, created_at, read_at FROM " .. MESSAGES
        .. " WHERE (from_id = $1 AND to_id = $2) OR (from_id = $2 AND to_id = $1)"
        .. " ORDER BY created_at DESC, id DESC LIMIT $3", {me, peer, count})
    if not rows then return nil, "history not read: " .. tostring(err) end
    local out: any = {}
    for index = #rows, 1, -1 do
        local row: any = rows[index]
        out[#out + 1] = {id = tostring(row.id), from_id = tostring(row.from_id), to_id = tostring(row.to_id),
            body = tostring(row.body or ""), at = tostring(row.created_at or ""), read = row.read_at ~= nil}
    end
    return out, nil
end

-- mark_read(user_id) -> how many of that person's messages to the caller
-- were marked, nil, notice. The messenger is told, so the tray drops the
-- envelope at once instead of on the next tick.
function people.mark_read(user_id: any): (any, string?, string?)
    local me, why = person()
    if not me then return nil, why, nil end
    local peer = trim(user_id)
    if peer == "" then return nil, "no account named", nil end
    -- SQLite numbers `$N` parameters by their first appearance, not by N:
    -- the placeholders are written in ascending order so both drivers agree.
    local result, err = write("UPDATE " .. MESSAGES .. " SET read_at = $1"
        .. " WHERE to_id = $2 AND from_id = $3 AND read_at IS NULL", {stamp(), me, peer})
    if not result then return nil, "not marked read: " .. tostring(err), nil end
    local count = whole(result.rows_affected) or 0
    if count > 0 then
        local told, terr = people.deps.send(people.MESSENGER, people.READ, {user_id = me})
        if not told then return count, nil, "marked read, but the messenger did not hear of it: " .. tostring(terr) end
    end
    return count, nil, nil
end

-- unread() -> {[from_id] = count} of the caller's unread messages.
function people.unread(): (any, string?)
    local me, why = person()
    if not me then return nil, why end
    local counts, err = unread_of(me)
    if not counts then return nil, "unread messages not counted: " .. tostring(err) end
    return counts, nil
end

-- ─── for the services: no actor needed ──────────────────────────────────

-- count_unread(user_id) -> how many unread messages that person has.
function people.count_unread(user_id: any): (integer?, string?)
    local id = trim(user_id)
    if id == "" then return nil, "no account named" end
    local rows, err = read("SELECT COUNT(*) AS n FROM " .. MESSAGES .. " WHERE to_id = $1 AND read_at IS NULL", {id})
    if not rows then return nil, err end
    local first: any = rows[1] or {}
    return whole(first.n) or 0, nil
end

-- ends(message_id) -> {id, from_id, to_id} of a stored message.
function people.ends(message_id: any): (any, string?)
    if type(message_id) ~= "string" or message_id == "" then return nil, "no message id" end
    local rows, err = read("SELECT id, from_id, to_id FROM " .. MESSAGES .. " WHERE id = $1", {message_id})
    if not rows then return nil, err end
    local row: any = rows[1]
    if not row then return nil, "no message " .. message_id end
    return {id = tostring(row.id), from_id = tostring(row.from_id), to_id = tostring(row.to_id)}, nil
end

-- tally(seen, now, ttl) -> {[user_id] = desktops}: the desktops whose last
-- desktop.list answer, younger than `ttl` seconds, named a person.
function people.tally(seen: any, now: any, ttl: any): any
    local out: any = {}
    local limit = tonumber(ttl) or 0
    local at_now = tonumber(now) or 0
    for _, entry in pairs(type(seen) == "table" and seen or {}) do
        if type(entry) == "table" and type(entry.user) == "string" and entry.user ~= ""
            and at_now - (tonumber(entry.at) or 0) < limit then
            out[entry.user] = (out[entry.user] or 0) + 1
        end
    end
    return out
end

-- The messenger's watch table: who watches whose messages, both ways.
function people.watchers(): any
    return {by_user = {}, by_pid = {}}
end

-- watch(table, pid, user_id) -> true when the pid watched nothing before
-- (the messenger then monitors it, so its exit drops its watches).
function people.watch(watch: any, pid: any, user_id: any): boolean
    if type(user_id) ~= "string" or user_id == "" then return false end
    local key = tostring(pid)
    local fresh = watch.by_pid[key] == nil
    watch.by_pid[key] = watch.by_pid[key] or {}
    watch.by_pid[key][user_id] = true
    watch.by_user[user_id] = watch.by_user[user_id] or {}
    watch.by_user[user_id][key] = true
    return fresh
end

-- unwatch(table, pid, user_id?) -> true when the pid watches nothing any
-- more. Without `user_id` every watch of that pid goes.
function people.unwatch(watch: any, pid: any, user_id: any): boolean
    local key = tostring(pid)
    local mine: any = watch.by_pid[key]
    if not mine then return false end
    local drop: any = {}
    if type(user_id) == "string" and user_id ~= "" then
        if mine[user_id] then drop[1] = user_id end
    else
        for id in pairs(mine) do drop[#drop + 1] = id end
    end
    for _, id in ipairs(drop) do
        mine[id] = nil
        local watching: any = watch.by_user[id]
        if watching then
            watching[key] = nil
            if next(watching) == nil then watch.by_user[id] = nil end
        end
    end
    if next(mine) ~= nil then return false end
    watch.by_pid[key] = nil
    return true
end

-- forget(table, pid): a watching process exited.
function people.forget(watch: any, pid: any)
    people.unwatch(watch, pid, nil)
end

-- targets(table, row) -> the pids watching either end of a message, once each.
function people.targets(watch: any, row: any): any
    local seen: any, out: any = {}, {}
    for _, id in ipairs({tostring(row.to_id), tostring(row.from_id)}) do
        for key in pairs(watch.by_user[id] or {}) do
            if not seen[key] then
                seen[key] = true
                out[#out + 1] = key
            end
        end
    end
    table.sort(out)
    return out
end

return people
