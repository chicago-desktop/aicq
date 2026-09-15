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

local process = require("process")
local channel = require("channel")
local time = require("time")
local logger = require("logger")
local desktop = require("desktop")
local roster = require("roster")
local control = require("control")
local aicq = require("aicq")
local people = require("people")

local log = logger:named("chicago.aicq.presence")

local TICK = tostring(aicq.TICK_S) .. "s"
-- The desktop families, from their owners: the Windows 95 shell's and the base's own.
local FAMILIES = {control.SERVICE_NAME, desktop.DEFAULT_SERVICE}
-- The compositor's command that names the person logged on.
local LIST = "desktop.list"

-- The service's state is a table, not locals: after an error under pcall in
-- go-lua a closure and its owner stop sharing a local.
--   report — the contact list's last report (aicq.heard);
--   seen   — {[desktop name] = {user = id | false, at = seconds}};
--   asked  — {[compositor pid] = desktop name} of this tick's questions;
--   roster — this tick's roster read, {list} or {why}.
local state: any = {report = nil, seen = {}, asked = {}, roster = nil}

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
    state.seen[name] = {user = id ~= "" and id or false, at = now_s()}
    put(tostring(name))
end

-- refresh(user_id): that person's desktops get their item now.
local function refresh(user_id: any)
    if type(user_id) ~= "string" or user_id == "" then return end
    for name, seen in pairs(state.seen) do
        if seen.user == user_id then put(tostring(name)) end
    end
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
    elseif topic == people.WHO then
        local online = people.tally(state.seen, now_s(), aicq.REPORT_TTL_S)
        local sent, err = process.send(tostring(message:from()), people.ONLINE, {online = online})
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
    push()
    local ticker = time.after(TICK)
    while true do
        local picked = channel.select({events:case_receive(), inbox:case_receive(),
            replies:case_receive(), ticker:case_receive()})
        if not picked.ok then break end
        if picked.channel == events then
            if picked.value and picked.value.kind == process.event.CANCEL then break end
        elseif picked.channel == ticker then
            ticker = time.after(TICK)
            push()
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
