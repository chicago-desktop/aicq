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

local log = logger:named("windows.aicq.messenger")

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
