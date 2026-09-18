-- aICQ presence: the tray item of every desktop, next to the clock.
--
-- Every running desktop of the shell's and the base's families (under
-- terminal.ssh, one desktop per connection) gets its own item:
--
-- * the envelope `aICQ (N)` while the person logged on to that desktop has
--   N unread messages (docs/aicq-people.md §5, `aicq.mail`);
-- * otherwise the flower with the people online besides that desktop's own
--   person, and the agents (`aicq.pick`). The agent count comes from the contact
--   list's report while it is fresh (`aicq.REPORT`: an open list runs under
--   the logged-on person and sees their agents too), else from this
--   service's own roster read under its own actor — which sees only public
--   system agents; `aicq.pick` chooses. A desktop without a logged-on
--   person always shows the flower.
--
-- Who is logged on to a desktop is its `desktop.list` answer (`user.id`).
-- The service asks every desktop each tick and takes the answers as they
-- come on `desktop.replies()`, so the loop never waits for a desktop; each
-- answer pushes that desktop's item at once. `aicq.refresh` (from the
-- messenger) pushes the desktops of one person at once, and `aicq.who` is
-- answered with `{[user_id] = desktops}` from the answers of the last two
-- ticks.
--
-- The item is pushed every tick even unchanged: a restarted shell starts
-- with an empty tray, and `ttl` removes the item if this service stops.
--
-- Between computers (docs/aicq-network.md §3): the service joins the pg
-- group `aicq.presence` of aICQ's own scope and broadcasts, every
-- ANNOUNCE_S, the people logged on here — its own rosters come back to it
-- too. It keeps the rosters it hears by the node of the SENDING process and
-- answers `aicq.who` with them as well (`network`), judged per node:
-- fresh, unknown (no news, still a member) or gone (the membership says
-- so). A scope that does not open leaves aICQ on this computer only; the
-- tray's work goes on.

local process = require("process")
local channel = require("channel")
local time = require("time")
local logger = require("logger")
local desktop = require("desktop")
local roster = require("roster")
local control = require("control")
local aicq = require("aicq")
local people = require("people")
local network = require("network")
local pg = require("pg")
local system = require("system")

local log = logger:named("chicago.aicq.presence")

local TICK = tostring(aicq.TICK_S) .. "s"
-- The desktop families, from their owners: the Chicago shell's and the base's own.
local FAMILIES = {control.SERVICE_NAME, desktop.DEFAULT_SERVICE}
-- The compositor's command that names the person logged on.
local LIST = "desktop.list"

-- The service's state is a table, not locals: after an error under pcall in
-- go-lua a closure and its owner stop sharing a local.
--   report — the contact list's last report (aicq.heard);
--   seen   — {[desktop name] = {user = id | false, at = seconds}};
--   asked  — {[compositor pid] = desktop name} of this tick's questions;
--   roster — this tick's roster read, {list} or {why};
--   net    — the rosters heard from the network (network.heard);
--   scope  — the pg scope while joined, else nil;
--   self   — this node's name; members — the nodes that count (network.members);
--   refused — the nodes whose rosters were refused, said once each;
--   said   — what the log last said of each node ("fresh 2", "unknown", …).
local state: any = {report = nil, seen = {}, asked = {}, roster = nil,
    net = {nodes = {}}, scope = nil, self = nil, members = nil, refused = {}, said = {}}

local function now_s(): integer
    return math.tointeger(time.now():unix_nano() // 1000000000) or 0
end

-- The roster read once per tick and used for every desktop's item.
local function roster_now(): any
    local ok, list = pcall(roster.reachable, nil, "")
    if ok then return {list = list} end
    return {why = tostring(list)}
end

-- others(name) -> how many people besides that desktop's own person are online.
local function others(name: string): integer
    local seen: any = state.seen[name]
    local mine: any = seen and seen.user or nil
    local count = 0
    for user in pairs(people.tally(state.seen, now_s(), aicq.REPORT_TTL_S)) do
        if user ~= mine then count = count + 1 end
    end
    return count
end

-- flower(name) -> that desktop's flower: the people online besides its own
-- person, and the agents — the list's report while fresh, else own reading.
-- A desktop nobody logged on to (or not answered yet) passes no people
-- count, and its title speaks of agents alone (`aicq.tray`).
local function flower(name: string): any
    local read: any = state.roster or roster_now()
    local seen: any = state.seen[name]
    local count: any = nil
    if seen and type(seen.user) == "string" then count = others(name) end
    local item: any = aicq.pick(read.list, read.why, state.report, now_s(), count)
    return item
end

-- running() -> {{name, pid}, …}: every running desktop of every family. No
-- desktop running is not an error but an ordinary state of the stand.
local function running(): any
    local found: any = {}
    for _, family in ipairs(FAMILIES) do
        for _, one in ipairs(desktop.desktops(family)) do found[#found + 1] = one end
    end
    return found
end

-- item(name) -> the envelope while that desktop's person has unread
-- messages, else the flower.
local function item(name: string): any
    local base: any = flower(name)
    local seen: any = state.seen[name]
    if not seen or type(seen.user) ~= "string" then return base end
    local count, err = people.count_unread(seen.user)
    if not count then
        log:warn("unread messages not counted", {desktop = name, error = tostring(err)})
        return base
    end
    return aicq.mail(count, base)
end

local function put(name: string)
    local ok, err = desktop.tray(item(name), name)
    if not ok then log:warn("tray not updated", {desktop = name, error = tostring(err)}) end
end

-- push(): every running desktop gets its item from what is known of its
-- person, and is asked again who that is.
local function push()
    state.roster = roster_now()
    state.asked = {}
    local live: any = {}
    local me = tostring(process.pid())
    for _, found in ipairs(running()) do
        local name = tostring(found.name)
        live[name] = true
        put(name)
        state.asked[tostring(found.pid)] = name
        local sent, err = process.send(tostring(found.pid), LIST, {reply_to = me})
        if not sent then log:warn("desktop not asked", {desktop = name, error = tostring(err)}) end
    end
    for name in pairs(state.seen) do
        if not live[name] then state.seen[name] = nil end
    end
end

-- A desktop's answer: remember whose it is and push its item.
local function answered(message: any)
    local answer: any = people.unwrap(message:payload())
    if answer.unsolicited then
        log:warn("the desktop refused a command", {command = tostring(answer.command), error = tostring(answer.error)})
        return
    end
    local name = state.asked[tostring(message:from())]
    if not name or answer.command ~= LIST then return end
    if answer.ok == false then
        log:warn("the desktop did not list", {desktop = name, error = tostring(answer.error)})
        return
    end
    local user: any = type(answer.user) == "table" and answer.user.id or nil
    local id = user ~= nil and tostring(user) or ""
    local shown: any = type(answer.user) == "table" and answer.user.name or nil
    state.seen[name] = {user = id ~= "" and id or false, name = type(shown) == "string" and shown or nil, at = now_s()}
    put(tostring(name))
end

-- refresh(user_id): that person's desktops get their item now.
local function refresh(user_id: any)
    if type(user_id) ~= "string" or user_id == "" then return end
    for name, seen in pairs(state.seen) do
        if seen.user == user_id then put(tostring(name)) end
    end
end

-- here() -> {[user_id] = name}: the people logged on to a desktop of this
-- node, from the answers of the last two ticks.
local function here(): any
    local out: any = {}
    local online = people.tally(state.seen, now_s(), aicq.REPORT_TTL_S)
    for _, seen in pairs(state.seen) do
        if type(seen.user) == "string" and online[seen.user] then
            out[seen.user] = seen.name or out[seen.user] or seen.user
        end
    end
    return out
end

-- join() — into the network's group; a refusal leaves aICQ on this node.
local function join()
    local scope, err = pg.open(network.SCOPE)
    if not scope then
        log:warn("aICQ stays on this computer: the network scope did not open", {error = tostring(err)})
        return
    end
    local _, jerr = scope:join(network.GROUP)
    if jerr then
        log:warn("aICQ stays on this computer: the network group was not joined", {error = tostring(jerr)})
        return
    end
    state.scope = scope
    if not network.node_ok(state.self) then
        log:warn("this node takes no part in aICQ between computers: its name is empty or has a colon",
            {node = tostring(state.self)})
    end
end

-- membership() -> the nodes that count, from the cluster and the group.
local function membership(): any
    local cluster = system.cluster.members()
    local group: any = nil
    if state.scope then group = state.scope:get_members(network.GROUP) end
    return network.members(cluster, group)
end

-- note() — the log says when another node changes: heard (and how many
-- people), unknown, gone. One line per change, so what a node hears is
-- visible without asking it.
local function note()
    local view = network.view(state.net, state.self, now_s(), state.members)
    local counts: any = {}
    for _, person in ipairs(view.people) do counts[person.node] = (counts[person.node] or 0) + 1 end
    local now_said: any = {}
    for node, verdict in pairs(view.nodes) do
        now_said[node] = verdict == "fresh" and ("fresh " .. tostring(counts[node] or 0)) or verdict
    end
    for node, text in pairs(now_said) do
        if state.said[node] ~= text then
            log:info("aICQ network: another computer", {node = node, state = text})
            -- Heard again after silence or absence: the messenger offers
            -- what waits for it now.
            local before: any = state.said[node]
            if view.nodes[node] == "fresh" and (before == nil or string.sub(tostring(before), 1, 5) ~= "fresh") then
                local messenger = process.registry.lookup(aicq.MESSENGER)
                if messenger then process.send(tostring(messenger), aicq.NODE_BACK, {node = node}) end
            end
        end
    end
    for node in pairs(state.said) do
        if now_said[node] == nil then log:info("aICQ network: another computer", {node = node, state = "gone"}) end
    end
    state.said = now_said
end

-- announce() — this node's people to the group, and the membership anew.
local function announce()
    if not state.scope then return end
    state.members = membership()
    network.forget(state.net, now_s(), state.members)
    if not network.node_ok(state.self) then return end
    local _, err = state.scope:broadcast(network.GROUP, network.ROSTER, network.roster(here()))
    if err then log:warn("roster not announced", {error = tostring(err)}) end
    note()
end

-- roster(message) — a node's roster, by the node of the process that sent it.
local function roster_heard(message: any)
    local node = network.node_of(message:from())
    local ok, payload = pcall(message.payload, message)
    local taken, why = network.heard(state.net, node, ok and aicq.unwrap(payload) or nil, now_s())
    if not taken and not state.refused[tostring(node)] then
        state.refused[tostring(node)] = true
        log:warn("a roster was refused", {node = tostring(node), reason = tostring(why)})
    end
    if taken then note() end
end

local function drop()
    for _, found in ipairs(running()) do
        desktop.tray({key = aicq.TRAY_KEY, remove = true}, tostring(found.name))
    end
end

local function hear(message: any)
    local topic = message:topic()
    if topic == aicq.REPORT then
        -- The list's report: remember it with its time and push now, not on the tick.
        local ok, payload = pcall(message.payload, message)
        state.report = aicq.heard(ok and aicq.unwrap(payload) or nil, now_s())
        push()
    elseif topic == people.REFRESH then
        local body: any = people.unwrap(message:payload())
        refresh(body.user_id)
    elseif topic == network.ROSTER then
        roster_heard(message)
    elseif topic == people.WHO then
        local online = people.tally(state.seen, now_s(), aicq.REPORT_TTL_S)
        local seen: any = nil
        if state.scope then seen = network.view(state.net, state.self, now_s(), state.members) end
        local sent, err = process.send(tostring(message:from()), people.ONLINE, {online = online, network = seen})
        if not sent then log:warn("presence not told", {to = tostring(message:from()), error = tostring(err)}) end
    end
end

local function main()
    local events = process.events()
    local inbox = process.inbox()
    local replies, lerr = desktop.replies()
    if not replies then
        log:error("aICQ presence cannot hear the desktops", {error = tostring(lerr)})
        return {status = "failed", error = tostring(lerr)}
    end
    local registered, rerr = process.registry.register(aicq.SERVICE)
    if not registered then
        -- A second instance would push the same item in a second voice, and
        -- the list would report to the first.
        log:error("aICQ presence not registered", {name = aicq.SERVICE, error = tostring(rerr)})
        return {status = "failed", error = tostring(rerr)}
    end
    state.self = network.node_of(process.pid())
    join()
    push()
    announce()
    local ticker = time.after(TICK)
    local announcer = time.after(tostring(network.ANNOUNCE_S) .. "s")
    while true do
        local picked = channel.select({events:case_receive(), inbox:case_receive(),
            replies:case_receive(), ticker:case_receive(), announcer:case_receive()})
        if not picked.ok then break end
        if picked.channel == events then
            if picked.value and picked.value.kind == process.event.CANCEL then break end
        elseif picked.channel == ticker then
            ticker = time.after(TICK)
            push()
        elseif picked.channel == announcer then
            announcer = time.after(tostring(network.ANNOUNCE_S) .. "s")
            local ok, err = pcall(announce)
            if not ok then log:error("roster not announced", {error = tostring(err)}) end
        elseif picked.channel == replies then
            local ok, err = pcall(answered, picked.value)
            if not ok then log:error("desktop answer not taken", {error = tostring(err)}) end
        elseif picked.value then
            local ok, err = pcall(hear, picked.value)
            if not ok then log:error("message not taken", {error = tostring(err)}) end
        end
    end
    drop()
    return {status = "completed"}
end

return {main = main}
