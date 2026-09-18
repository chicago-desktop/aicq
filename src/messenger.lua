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
--
-- Between computers (docs/aicq-network.md §5) the messenger also answers to
-- `chicago.aicq.messenger@<node>` in the cluster's EVENTUAL registry. A
-- message to net:<node>:<id> is offered to that name, and offered again every
-- RETRY_S and when the node is heard again, until that messenger answers
-- `aicq.delivered`: a send between nodes reports success even when nothing
-- arrives (measured), so only the answer confirms. A delivery from another
-- computer is stored under the sender's message id (a repeat is stored
-- once) with the sender's node taken from the sending process, never from
-- the body, and answered either way. An acknowledgement counts only from
-- the node the message was addressed to.
--
-- It writes those rows under its own actor. The runtime has no SQL right
-- narrower than `db.get` (which the messenger already holds to read a
-- message's ends), so the narrowing is the code's: the two statements of
-- people.receive and people.delivered/failed, nothing else.

local process = require("process")
local channel = require("channel")
local logger = require("logger")
local people = require("people")
local aicq = require("aicq")
local notify = require("notify")
local desktop = require("desktop")
local network = require("network")
local time = require("time")

local log = logger:named("chicago.aicq.messenger")

-- The state is a table, not locals: after an error under pcall in go-lua a
-- closure and its owner stop sharing a local.
local state: any = {watch = people.watchers(), self = nil, unreachable = {}, refused = {}}

local function refresh(user_id: any)
    if type(user_id) ~= "string" or user_id == "" then return end
    -- No presence service: the tray catches up on that service's next tick.
    local pid = process.registry.lookup(people.PRESENCE)
    if not pid then return end
    local sent, err = process.send(pid, people.REFRESH, {user_id = user_id})
    if not sent then log:warn("tray refresh not asked", {user_id = user_id, error = tostring(err)}) end
end

-- sender_name(user_id) -> the display name | nil. The users directory behind
-- the same gate a window passes (people.name_of); this service's policy
-- grants that one gate and nothing else of the directory
-- (`chicago.aicq:messenger_directory` — without it every balloon would read
-- "New message"). An account the directory does not know, or a refusal, is
-- an ordinary state and not a fault: it is said at debug, and the title
-- falls back to "New message" rather than a bare id.
local function sender_name(user_id: any): any
    if network.remote(user_id) then
        local node = network.split(user_id)
        local heard = people.remote_name(user_id)
        return heard and network.label(heard, node) or nil
    end
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
    -- Whom it is for, first of all: a message to oneself, or a row without
    -- two ends, shows nothing — and asks the users directory nothing either.
    local plain = aicq.arrival(row, nil)
    if not plain then return end
    -- And with no desktop of the shell's family running there is nobody to
    -- show it to: a name nobody would read is not worth a directory call.
    -- This is a lookup in the process registry, not a question to a desktop.
    if #desktop.desktops(notify.FAMILY) == 0 then
        log:info("no balloon shown", {user_id = tostring(row.to_id), reason = notify.NOBODY})
        return
    end
    local balloon = aicq.arrival(row, sender_name(row.from_id)) or plain
    local reached, why = notify.balloon(balloon)
    if not reached then
        log:info("no balloon shown", {user_id = tostring(row.to_id), reason = tostring(why)})
        -- Nobody to show it to means that person has no desktop open: there
        -- is nothing to flash either. Any other refusal is the balloon's
        -- alone — a full queue, a field the desktop did not take — and an
        -- open window may still ask for attention.
        if tostring(why) == notify.NOBODY then return end
    end
    for _, entry in ipairs(aicq.FLASH_ENTRIES) do
        local flashed = notify.flash({entry = entry, user = row.to_id})
        if flashed then return end
    end
    log:debug("no aICQ window to flash", {user_id = tostring(row.to_id)})
end

-- ping(row) — every window that watches either end hears of that message.
local function ping(row: any)
    local body = {from_id = row.from_id, to_id = row.to_id, message_id = row.id}
    for _, pid in ipairs(people.targets(state.watch, row)) do
        local ok, serr = process.send(tostring(pid), people.NEW, body)
        if not ok then log:warn("ping not sent", {pid = pid, error = tostring(serr)}) end
    end
end

-- offer(row) — one stored message to the messenger of the computer it is
-- for. Nothing is marked here: only that messenger's answer does. A node
-- whose messenger cannot be found is said once until it is found again.
local function offer(row: any)
    local node = tostring(network.split(row.to_id))
    local body, why = network.delivery(row, sender_name(row.from_id) or row.from_id)
    if not body then
        log:warn("a message was not offered", {message_id = row.id, reason = tostring(why)})
        return
    end
    local pid = process.registry.lookup(network.messenger_name(node))
    if not pid then
        if not state.unreachable[node] then
            state.unreachable[node] = true
            log:info("messages wait for another computer", {node = node, reason = "its messenger is not found"})
        end
        return
    end
    state.unreachable[node] = nil
    local ok, serr = process.send(tostring(pid), network.DELIVER, body)
    if not ok then log:warn("a message was not offered", {message_id = row.id, error = tostring(serr)}) end
end

-- flush() — every undelivered message to another computer, offered again.
local function flush()
    local rows, err = people.outbox(50)
    if not rows then
        log:warn("undelivered messages not read", {error = tostring(err)})
        return
    end
    for _, row in ipairs(rows) do offer(row) end
end

-- delivery(message) — a message from another computer: stored once, told
-- here as a local message is, and answered — also for a repeat, so the
-- sender stops offering it. A refusal is answered with its reason and the
-- sender stops too; a message not stored is not answered and comes again.
local function delivery(message: any)
    local from = tostring(message:from())
    local node = network.node_of(from)
    local body: any = people.unwrap(message:payload())
    local accepted, why = network.accept(node, body, state.self)
    if not accepted then
        local key = tostring(node) .. ": " .. tostring(why)
        if not state.refused[key] then
            state.refused[key] = true
            log:warn("a message from another computer was refused", {node = tostring(node), reason = tostring(why)})
        end
        if type(body) == "table" and type(body.i) == "string" and network.node_ok(node) and node ~= state.self then
            process.send(from, network.DELIVERED, {i = body.i, r = tostring(why)})
        end
        return
    end
    local fresh, err = people.receive(accepted)
    if fresh == nil then
        log:warn("a message from another computer was not stored", {node = tostring(node), error = tostring(err)})
        return
    end
    process.send(from, network.DELIVERED, {i = accepted.id})
    if not fresh then return end
    local row = {id = accepted.id, from_id = accepted.from_id, to_id = accepted.to_id, body = accepted.body}
    ping(row)
    refresh(row.to_id)
    local shown, awhy = pcall(announce, row)
    if not shown then log:info("the arrival was not announced", {error = tostring(awhy)}) end
end

-- confirmed(message) — the other computer's answer: delivered, or refused
-- for good. Only the node the message was addressed to may answer for it.
local function confirmed(message: any)
    local node = network.node_of(message:from())
    local body: any = people.unwrap(message:payload())
    local row = type(body) == "table" and people.ends(body.i) or nil
    if not row or not network.acked(node, row) then
        log:warn("an acknowledgement was not taken", {node = tostring(node), message_id = tostring(body and body.i)})
        return
    end
    local changed, err: any
    if type(body.r) == "string" and body.r ~= "" then
        changed, err = people.failed(row.id, body.r)
        if changed then log:warn("another computer refused a message", {node = tostring(node), reason = body.r}) end
    else
        changed, err = people.delivered(row.id)
    end
    if changed == nil then log:warn("a delivery was not marked", {message_id = row.id, error = tostring(err)}) end
    if changed then ping(row) end
end

local function sent(body: any)
    local row, err = people.ends(body.message_id)
    if not row then
        log:warn("aicq.sent about a message that does not read",
            {message_id = tostring(body.message_id), error = tostring(err)})
        return
    end
    ping(row)
    if network.remote(row.to_id) then
        -- Another computer's person: offered now, and again until answered.
        -- Their tray and their balloon are that computer's to show.
        offer(row)
        return
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
    elseif topic == network.DELIVER then
        delivery(message)
    elseif topic == network.DELIVERED then
        confirmed(message)
    elseif topic == aicq.NODE_BACK then
        flush()
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
    -- The name other computers find this one by. Without a cluster there is
    -- no EVENTUAL registry: aICQ is this computer's alone, said once.
    state.self = network.node_of(process.pid())
    if network.node_ok(state.self) then
        local name = network.messenger_name(tostring(state.self))
        local ok, nerr = process.registry.register(name, tostring(process.pid()), process.registry.EVENTUAL)
        if not ok then
            log:info("aICQ messages stay on this computer", {name = name, reason = tostring(nerr)})
        end
    else
        log:warn("this node takes no part in aICQ between computers: its name is empty or has a colon",
            {node = tostring(state.self)})
    end
    local retry = time.after(tostring(network.RETRY_S) .. "s")
    while true do
        local picked = channel.select({events:case_receive(), inbox:case_receive(), retry:case_receive()})
        if not picked.ok then break end
        local value: any = picked.value
        if picked.channel == retry then
            retry = time.after(tostring(network.RETRY_S) .. "s")
            local ok, ferr = pcall(flush)
            if not ok then log:error("undelivered messages not offered", {error = tostring(ferr)}) end
        elseif picked.channel == events then
            if value and value.kind == process.event.CANCEL then break end
            if value and value.kind == process.event.EXIT then people.forget(state.watch, tostring(value.from)) end
        elseif value then
            -- A message from another computer is its to shape: one that
            -- breaks this code must not take the messenger down with it.
            local ok, herr = pcall(hear, value)
            if not ok then log:error("message not taken", {topic = tostring(value:topic()), error = tostring(herr)}) end
        end
    end
    return {status = "completed"}
end

return {main = main}
