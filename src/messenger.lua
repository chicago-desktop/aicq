-- aICQ messenger (docs/aicq-people.md §5): tells windows that a message
-- arrived and asks the presence service to redraw a tray. It stores
-- nothing — the sender's window writes the row under the sender's actor
-- before `aicq.sent` comes here.
--
-- What a body says about people is not believed where it can be checked:
-- the two ends of a message are read from its stored row by `message_id`
-- (this service's actor has db.get on app:db), so a forged `aicq.sent` can
-- at most ping about a real row. A watch names a person in its body, and
-- that cannot be checked here — a message carries the sender's pid, not its
-- actor — so a forged watch only yields "reload" pings; the content is read
-- by each window under its own actor.
--
-- A watching process is monitored: its exit drops its watches.

local process = require("process")
local channel = require("channel")
local logger = require("logger")
local people = require("people")
local aicq = require("aicq")
local notify = require("notify")

local log = logger:named("chicago.aicq.messenger")

-- The state is a table, not locals: after an error under pcall in go-lua a
-- closure and its owner stop sharing a local.
local state: any = {watch = people.watchers()}

local function refresh(user_id: any)
    if type(user_id) ~= "string" or user_id == "" then return end
    -- No presence service: the tray catches up on that service's next tick.
    local pid = process.registry.lookup(people.PRESENCE)
    if not pid then return end
    local sent, err = process.send(pid, people.REFRESH, {user_id = user_id})
    if not sent then log:warn("tray refresh not asked", {user_id = user_id, error = tostring(err)}) end
end

-- sender_name(user_id) -> the display name | nil. The users directory behind
-- its gate, as a window reads it (people.name_of). This service's actor is
-- not a person, so the gate may refuse it — the balloon then says "New
-- message" rather than an id, and the refusal is said at debug: it is an
-- ordinary state, not a fault.
local function sender_name(user_id: any): any
    local ok, found, why = pcall(people.name_of, user_id)
    if ok and type(found) == "string" and found ~= "" then return found end
    log:debug("the sender's name was not read",
        {user_id = tostring(user_id), reason = tostring(ok and why or found)})
    return nil
end

-- announce(row) — what the recipient sees of an arriving message: a balloon
-- tip by the notification area, its tail at aICQ's tray item and a click
-- opening the conversation with the sender, and a flash of their aICQ
-- windows — the conversation while one is open, else the contact list.
--
-- Nobody online is not a failure: the shell keeps nothing for a later logon
-- (the owner's rule), the message waits in the history, and this is said at
-- info, never warn. A message to oneself shows nothing (`aicq.arrival`).
local function announce(row: any)
    local balloon = aicq.arrival(row, sender_name(row.from_id))
    if not balloon then return end
    local reached, why = notify.balloon(balloon)
    if not reached then
        log:info("no balloon shown", {user_id = tostring(row.to_id), reason = tostring(why)})
        return
    end
    for _, entry in ipairs(aicq.FLASH_ENTRIES) do
        local flashed = notify.flash({entry = entry, user = row.to_id})
        if flashed then return end
    end
    log:debug("no aICQ window to flash", {user_id = tostring(row.to_id)})
end

local function sent(body: any)
    local row, err = people.ends(body.message_id)
    if not row then
        log:warn("aicq.sent about a message that does not read",
            {message_id = tostring(body.message_id), error = tostring(err)})
        return
    end
    local ping = {from_id = row.from_id, to_id = row.to_id, message_id = row.id}
    for _, pid in ipairs(people.targets(state.watch, row)) do
        local ok, serr = process.send(tostring(pid), people.NEW, ping)
        if not ok then log:warn("ping not sent", {pid = pid, error = tostring(serr)}) end
    end
    refresh(row.to_id)
    -- Last of the three, and never able to stop the other two: a window
    -- redraws on a ping, and a notification must not delay or break that.
    local shown, why = pcall(announce, row)
    if not shown then log:info("the arrival was not announced", {error = tostring(why)}) end
end

local function watch(from: string, body: any)
    if not people.watch(state.watch, from, body.user_id) then return end
    local ok, err = process.monitor(from)
    if not ok then log:warn("watching process not monitored", {pid = from, error = tostring(err)}) end
end

local function unwatch(from: string, body: any)
    if not people.unwatch(state.watch, from, body.user_id) then return end
    process.unmonitor(from)
end

local function hear(message: any)
    local topic = message:topic()
    local from = tostring(message:from())
    local body: any = people.unwrap(message:payload())
    if topic == people.SENT then
        sent(body)
    elseif topic == people.READ then
        refresh(body.user_id)
    elseif topic == people.WATCH then
        watch(from, body)
    elseif topic == people.UNWATCH then
        unwatch(from, body)
    end
end

local function main()
    local events = process.events()
    local inbox = process.inbox()
    local registered, rerr = process.registry.register(people.MESSENGER)
    if not registered then
        -- A second messenger would split the watches between two processes.
        log:error("aICQ messenger not registered", {name = people.MESSENGER, error = tostring(rerr)})
        return {status = "failed", error = tostring(rerr)}
    end
    while true do
        local picked = channel.select({events:case_receive(), inbox:case_receive()})
        if not picked.ok then break end
        local value: any = picked.value
        if picked.channel == events then
            if value and value.kind == process.event.CANCEL then break end
            if value and value.kind == process.event.EXIT then people.forget(state.watch, tostring(value.from)) end
        elseif value then
            hear(value)
        end
    end
    return {status = "completed"}
end

return {main = main}
