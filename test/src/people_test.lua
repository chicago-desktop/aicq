-- aICQ people, the data half (docs/aicq-people.md §6): the library on a real
-- SQLite — contacts, send, history order and limit, unread, mark_read,
-- find's three shapes and its caps, UIN stability; identity taken from the
-- actor; the messenger's pings; the tray per desktop for 0 and 3 unread.
--
-- Run in the module's harness (test/): the platform is stood in there. The
-- users directory adapter (`directory`, kickside/users' stand-in) reads the
-- harness's users table (`user_repo.TABLE`), which this file fills; the
-- messenger and the presence service run as the module declares them; and
-- this test answers as a desktop of the shell's own family
-- (`control.SERVICE_NAME`), which the presence service asks.
local test = require("test")
local people = require("people")
local directory = require("directory")
local user_repo = require("user_repo")
local control = require("control")
local sql = require("sql")
local process = require("process")
local channel = require("channel")
local time = require("time")
local pg = require("pg")
local network = require("network")

local ANNA = {user_id = "u-anna", email = "anna@example.com", full_name = "Anna Karenina"}
local BOB = {user_id = "u-bob", email = "bob@example.com", full_name = "Bob Marley"}
local BOBBY = {user_id = "u-bobby", email = "bobby@example.com", full_name = "Bobby Tables"}
local CAROL = {user_id = "u-carol", email = "carol@example.com", full_name = ""}
local DAVE = {user_id = "u-dave", email = "dave@example.com", full_name = "Dave Anderson"}
local YULIA = {user_id = "u-yulia", email = "yulia@example.com", full_name = "Юлия Петрова"}
local EVERYONE = {ANNA, BOB, BOBBY, CAROL, DAVE, YULIA}

local DESK = control.SERVICE_NAME

-- The roads the library takes for real, for the cases that run the services.
local REAL = {send = people.deps.send, who = people.deps.who}

-- The stand-in guard: whose window this is, and whether the directory's gate
-- lets them through. Tables, not locals: an error under pcall splits upvalues.
local guard: any = {who = nil, granted = true, asked = {}}
local told: any = {list = {}}

local function actor(id: string, meta: any): any
    return {id = function() return id end, meta = function() return meta end}
end

local function be(user: any)
    guard.who = actor(tostring(user.user_id), {user_id = user.user_id, email = user.email, full_name = user.full_name})
end

local function exec(query: string, params: any?)
    local db = assert(sql.get("app:db"))
    local _, err = db:execute(query, params or {})
    db:release()
    if err then error(tostring(err)) end
end

local function rows(query: string, params: any?): any
    local db = assert(sql.get("app:db"))
    local found, err = db:query(query, params or {})
    db:release()
    if err then error(tostring(err)) end
    return found or {}
end

-- users(list) — the harness's users table holds exactly these, the first the oldest.
local function users(list: any)
    exec("CREATE TABLE IF NOT EXISTS " .. user_repo.TABLE .. " (user_id TEXT PRIMARY KEY, email TEXT, full_name TEXT,"
        .. " status TEXT, created_at TEXT)")
    exec("DELETE FROM " .. user_repo.TABLE)
    for index, user in ipairs(list) do
        exec("INSERT INTO " .. user_repo.TABLE .. " (user_id, email, full_name, status, created_at) VALUES ($1, $2, $3, 'active', $4)",
            {user.user_id, user.email, user.full_name, string.format("2026-01-01 %06d", index)})
    end
end

-- fresh() — empty aICQ tables, everyone in the users table, and the library's
-- roads stood in: the guard, the real directory adapter, a recorder for what
-- would go to the messenger, nobody online.
local function fresh()
    exec("DELETE FROM chicago_aicq_contacts")
    exec("DELETE FROM chicago_aicq_messages")
    exec("DELETE FROM chicago_aicq_dismissed")
    exec("DELETE FROM chicago_aicq_remote")
    guard.who, guard.granted, guard.asked = nil, true, {}
    told.list = {}
    people.deps.security = {
        actor = function() return guard.who end,
        can = function(action: any, resource: any): boolean
            guard.asked[#guard.asked + 1] = tostring(action) .. " " .. tostring(resource)
            return guard.granted
        end,
    }
    people.deps.directory = function(method: string, args: any): (any, any)
        local answer = directory[method](args)
        return answer, nil
    end
    people.deps.send = function(name: string, topic: string, body: any): (boolean, any)
        told.list[#told.list + 1] = {name = name, topic = topic, body = body}
        return true, nil
    end
    people.deps.who = function(): (any, any) return {}, nil end
    users(EVERYONE)
end

local function bodies(history: any): string
    local out = {}
    for _, message in ipairs(history) do out[#out + 1] = message.body end
    return table.concat(out, "|")
end

local function names(list: any): string
    local out = {}
    for _, one in ipairs(list) do out[#out + 1] = one.name end
    return table.concat(out, "|")
end

local function ids(list: any): string
    local out = {}
    for _, one in ipairs(list) do out[#out + 1] = one.id end
    return table.concat(out, "|")
end

local function keys(value: any): string
    local out = {}
    for key in pairs(value) do out[#out + 1] = tostring(key) end
    table.sort(out)
    return table.concat(out, ",")
end

-- receive(ch, budget) -> the next message's body, nil when none came in time.
local function receive(ch: any, budget: string): any
    local timer = time.after(budget)
    local picked = channel.select({ch:case_receive(), timer:case_receive()})
    if picked.channel == timer or not picked.ok then return nil end
    return people.unwrap(picked.value:payload())
end

local function define_tests()
    test.describe("aICQ people", function()
        test.it("the migrations made the tables and both indexes", function()
            local found = rows("SELECT name FROM sqlite_master WHERE name LIKE 'chicago_aicq_%'"
                .. " OR name LIKE 'idx_chicago_aicq_%' ORDER BY name")
            test.eq(names((function()
                local out = {}
                for _, row in ipairs(found) do out[#out + 1] = {name = row.name} end
                return out
            end)()), "chicago_aicq_contacts|chicago_aicq_dismissed|chicago_aicq_messages|chicago_aicq_remote"
                .. "|idx_chicago_aicq_messages_pair|idx_chicago_aicq_messages_unread")
        end)

        test.it("display_name: the full name, else the e-mail, else the id", function()
            test.eq(people.display_name(ANNA), "Anna Karenina")
            test.eq(people.display_name(CAROL), "carol@example.com", "an empty full name is no name")
            test.eq(people.display_name({user_id = "u-x"}), "u-x", "no name, no e-mail: the id")
        end)

        test.it("identity is the actor: the sender is who the window runs under; a service actor or none is refused", function()
            fresh()
            be(ANNA)
            local me = assert(people.me())
            test.eq(me.id .. "|" .. me.name .. "|" .. tostring(me.uin), "u-anna|Anna Karenina|186565381")
            local id = assert(people.send(BOB.user_id, "hello"))
            local row = rows("SELECT from_id, to_id FROM chicago_aicq_messages WHERE id = $1", {id})[1]
            test.eq(row.from_id .. ">" .. row.to_id, "u-anna>u-bob", "the row's sender is the actor")

            guard.who = actor("chicago.aicq.presence", {})
            local none, why = people.send(BOB.user_id, "forged")
            test.is_nil(none)
            test.eq(why, "the window runs under chicago.aicq.presence, which is not a logged-on person")
            test.is_nil(people.me(), "a service actor has no me")
            guard.who = actor("u-bob", {user_id = "u-anna"})
            test.is_nil(people.contacts(), "an actor whose meta names another account is not a person either")
            guard.who = nil
            local list, lwhy = people.contacts()
            test.is_nil(list)
            test.eq(lwhy, "no one is logged on: the window runs without an actor")
            test.eq(#rows("SELECT id FROM chicago_aicq_messages"), 1, "the refused calls wrote nothing")
        end)

        test.it("contacts: add and its refusals, twice is once, names, presence, unread and the Not in list row", function()
            fresh()
            be(ANNA)
            test.eq(people.add(BOB.user_id), true)
            test.eq(people.add(BOB.user_id), true, "adding twice is not an error")
            test.eq(people.add(CAROL.user_id), true)
            local self_ok, self_why = people.add(ANNA.user_id)
            test.is_nil(self_ok)
            test.eq(self_why, "you cannot add yourself")
            local ghost_ok, ghost_why = people.add("u-ghost")
            test.is_nil(ghost_ok)
            test.eq(ghost_why, "no such account: u-ghost")
            test.eq(#rows("SELECT contact_id FROM chicago_aicq_contacts WHERE owner_id = 'u-anna'"), 2, "and no second row")

            be(DAVE)
            assert(people.send(ANNA.user_id, "hi Anna"))
            be(ANNA)
            people.deps.who = function(): (any, any) return {["u-bob"] = 2}, nil end
            local list = assert(people.contacts())
            local lines = {}
            for _, one in ipairs(list) do
                lines[#lines + 1] = table.concat({one.id, one.name, tostring(one.uin), tostring(one.online),
                    tostring(one.desktops), tostring(one.unread), tostring(one.listed)}, ",")
            end
            test.eq(table.concat(lines, "|"),
                "u-bob,Bob Marley,279391452,true,2,0,true"
                .. "|u-carol,carol@example.com," .. tostring(people.uin("u-carol")) .. ",false,0,0,true"
                .. "|u-dave,Dave Anderson," .. tostring(people.uin("u-dave")) .. ",false,0,1,false")
            test.is_nil(list.why)

            test.eq(people.remove(CAROL.user_id), true)
            test.eq(names(assert(people.contacts())), "Bob Marley|Dave Anderson")

            people.deps.who = function(): (any, any) return nil, "the presence service is not running (x)" end
            local blind = assert(people.contacts())
            test.is_nil(blind[1].online, "presence not read is unknown, not offline")
            test.eq(blind.why, "presence not read: the presence service is not running (x)")

            guard.granted = false
            local denied, dwhy = people.contacts()
            test.is_nil(denied)
            test.eq(dwhy, "the users directory (resolve) is not granted to your account"
                .. " (kickside.users.directory:directory_resolve)")
        end)

        test.it("other computers: Network by itself, a remote contact named as last heard, unknown kept, gone offline", function()
            fresh()
            be(ANNA)
            assert(people.add(BOB.user_id))
            local view: any = {
                people = {
                    {id = "net:node-b:u-zoe", node = "node-b", user_id = "u-zoe", name = "Zoe", state = "online"},
                    {id = "net:node-b:zoe@example.com", node = "node-b", user_id = "zoe@example.com", name = "Zoe Two",
                        state = "online"},
                },
                nodes = {["node-b"] = "fresh"},
            }
            people.deps.who = function(): (any, any, any) return {["u-bob"] = 1}, nil, view end
            local list = assert(people.contacts())
            local lines = {}
            for _, one in ipairs(list) do
                lines[#lines + 1] = table.concat({one.id, one.name, tostring(one.listed), tostring(one.network),
                    tostring(one.state), tostring(one.online)}, ",")
            end
            test.eq(table.concat(lines, "|"),
                "u-bob,Bob Marley,true,nil,nil,true"
                .. "|net:node-b:u-zoe,Zoe (node-b),false,true,online,true"
                .. "|net:node-b:zoe@example.com,Zoe Two (node-b),false,true,online,true",
                "the Network rows come without adding anyone; an id with @ stays whole")

            test.eq(people.add("net:node-b:u-zoe"), true)
            test.eq(#rows("SELECT id FROM chicago_aicq_remote WHERE id = 'net:node-b:u-zoe' AND name = 'Zoe'"), 1,
                "the name as heard is kept")
            local function zoe(): any
                for _, one in ipairs(assert(people.contacts())) do
                    if one.id == "net:node-b:u-zoe" then return one end
                end
                return nil
            end
            test.eq(tostring(zoe().listed) .. "," .. tostring(zoe().network) .. "," .. zoe().state, "true,nil,online",
                "a contact now: out of Network, into the list")
            local copies = 0
            for _, one in ipairs(assert(people.contacts())) do
                if one.id == "net:node-b:u-zoe" then copies = copies + 1 end
            end
            test.eq(copies, 1, "a contact is not in Network as well")

            -- node-b silent, still a member: unknown, the name last heard.
            view.people = {{id = "net:node-b:u-zoe", node = "node-b", user_id = "u-zoe", name = "Zoe", state = "unknown"}}
            view.nodes = {["node-b"] = "unknown"}
            test.eq(zoe().state .. "," .. tostring(zoe().online) .. "," .. zoe().name, "unknown,false,Zoe (node-b)")

            -- node-b gone: offline, still a contact, the remembered name.
            view.people, view.nodes = {}, {}
            test.eq(zoe().state .. "," .. zoe().name, "offline,Zoe (node-b)", "as in ICQ, a contact stays offline")
            -- Presence not read at all: unknown, not offline.
            people.deps.who = function(): (any, any, any) return nil, "not running" end
            test.eq(zoe().state, "unknown")

            -- Nobody heard of: refused.
            people.deps.who = function(): (any, any, any) return {}, nil, {people = {}, nodes = {}} end
            local ghost, why = people.add("net:node-b:u-ghost")
            test.is_nil(ghost)
            test.eq(why, "nobody by that id has been heard of on node-b")
            test.eq(people.remove("net:node-b:u-zoe"), true)
            test.is_nil(zoe(), "removed, and node-b is gone: nowhere")
        end)

        test.it("messages between computers: stored pending, offered until confirmed or refused, received once", function()
            fresh()
            be(ANNA)
            local view: any = {people = {{id = "net:node-b:u-zoe", node = "node-b", user_id = "u-zoe", name = "Zoe",
                state = "online"}}, nodes = {["node-b"] = "fresh"}}
            people.deps.who = function(): (any, any, any) return {}, nil, view end
            local id = assert(people.send("net:node-b:u-zoe", "hello Zoe"))
            test.eq(told.list[#told.list].topic, people.SENT, "the messenger is told, as for any message")
            local outbox = assert(people.outbox(10))
            test.eq(#outbox, 1)
            test.eq(outbox[1].id .. "|" .. outbox[1].to_id, id .. "|net:node-b:u-zoe")
            local history = assert(people.history("net:node-b:u-zoe", 10))
            test.is_true(history[1].pending == true, "pending until node-b confirms")
            test.eq(people.delivered(id), true)
            test.eq(people.delivered(id), false, "confirmed twice is marked once")
            test.eq(#assert(people.outbox(10)), 0, "a confirmed message is not offered again")
            test.is_nil(assert(people.history("net:node-b:u-zoe", 10))[1].pending)

            local other = assert(people.send("net:node-b:u-zoe", "second"))
            test.eq(people.failed(other, "no such person there"), true)
            local last = assert(people.history("net:node-b:u-zoe", 10))[2]
            test.eq(tostring(last.failed) .. "|" .. tostring(last.pending), "no such person there|nil")
            test.eq(#assert(people.outbox(10)), 0, "a refused message is not offered again")

            -- Nobody heard of on node-b: nothing is stored.
            view.people = {}
            local none, why = people.send("net:node-b:u-ghost", "hi")
            test.is_nil(none)
            test.eq(why, "nobody by that id has been heard of on node-b")

            -- From another computer: stored once under the sender's id, the
            -- sender's name remembered, unread for Anna.
            local incoming = {id = "remote-1", from_id = "net:node-b:u-zoe", to_id = ANNA.user_id, body = "hi Anna",
                name = "Zoe Z"}
            test.eq(people.receive(incoming), true)
            test.eq(people.receive(incoming), false, "offered again: stored once")
            test.eq(#rows("SELECT id FROM chicago_aicq_messages WHERE id = 'remote-1'"), 1)
            test.eq(people.remote_name("net:node-b:u-zoe"), "Zoe Z")
            test.eq(people.count_unread(ANNA.user_id), 1)
            local seen = assert(people.history("net:node-b:u-zoe", 10))
            test.eq(seen[#seen].body .. "|" .. tostring(seen[#seen].pending), "hi Anna|nil", "an incoming message is not pending")

            -- Someone elsewhere who wrote and is not a contact: Not in List,
            -- with the unread count, and not in Network as well.
            local stranger = {id = "remote-2", from_id = "net:node-b:u-yan", to_id = ANNA.user_id, body = "hey", name = "Yan"}
            assert(people.receive(stranger))
            view.people = {{id = "net:node-b:u-yan", node = "node-b", user_id = "u-yan", name = "Yan", state = "online"}}
            local rows_of: any = {}
            for _, one in ipairs(assert(people.contacts())) do
                if one.id == "net:node-b:u-yan" then rows_of[#rows_of + 1] = one end
            end
            test.eq(#rows_of, 1, "one row for Yan")
            test.eq(table.concat({tostring(rows_of[1].listed), tostring(rows_of[1].network), tostring(rows_of[1].unread),
                rows_of[1].name}, ","), "false,nil,1,Yan (node-b)")
            test.eq(people.dismiss("net:node-b:u-yan"), true, "dismissed without asking the users directory")
        end)

        test.it("the messenger offers a message to the other computer's messenger until answered, and believes only that node", function()
            fresh()
            people.deps.send = REAL.send
            local messenger = process.registry.lookup(people.MESSENGER)
            test.not_nil(messenger)
            -- This test stands in for node-x's messenger.
            local here = tostring(network.node_of(process.pid()))
            local offers = assert(process.listen(network.DELIVER, {message = true}))
            local answers = assert(process.listen(network.DELIVERED, {message = true}))
            assert(process.registry.register(network.messenger_name("node-x")))
            exec("INSERT INTO chicago_aicq_remote (id, node, name, seen_at) VALUES ('net:node-x:zed@example.com', 'node-x', 'Zed', 'x')")
            people.deps.who = function(): (any, any, any) return {}, nil, {people = {}, nodes = {}} end
            be(ANNA)
            local id = assert(people.send("net:node-x:zed@example.com", "hello Zed"))
            -- At once, not on the retry tick (every RETRY_S): a tick can
            -- still land inside this window by chance, one run in ~7.
            local first = receive(offers, "700ms")
            test.not_nil(first, "offered at once")
            test.eq(table.concat({tostring(first and first.i), tostring(first and first.f), tostring(first and first.t),
                tostring(first and first.b)}, "|"), id .. "|u-anna|zed@example.com|hello Zed")
            test.eq(first and first.m, "Anna Karenina", "with the sender's name")
            local again = receive(offers, tostring(network.RETRY_S + 2) .. "s")
            test.eq(again and again.i, id, "not answered: offered again")

            -- An answer from a node the message was not for is not believed.
            process.send(tostring(messenger), network.DELIVERED, {i = id})
            time.sleep("300ms")
            local row = rows("SELECT delivered_at FROM chicago_aicq_messages WHERE id = $1", {id})[1]
            test.is_nil(row.delivered_at, "only node-x confirms a message to node-x, not " .. here)

            -- A delivery from this very node is refused, not stored, and not
            -- answered: a computer does not talk to itself in a loop.
            process.send(tostring(messenger), network.DELIVER, {i = "loop-1", f = "u-bob", t = ANNA.user_id, b = "x"})
            test.is_nil(receive(answers, "1s"), "no answer to itself")
            test.eq(#rows("SELECT id FROM chicago_aicq_messages WHERE id = 'loop-1'"), 0, "and not stored")
            process.registry.unregister(network.messenger_name("node-x"))
            process.unlisten(offers)
            process.unlisten(answers)
        end)

        test.it("net: is reserved: a local account whose id starts with it is not taken for a local contact", function()
            -- A tripwire on the users module: it mints UUIDs and e-mail
            -- addresses today. Should it ever mint net:…, this breaks here and
            -- not in someone's contact list.
            fresh()
            users({ANNA, {user_id = "net:node-z:u", email = "z@example.com", full_name = "Zed"}})
            be(ANNA)
            people.deps.who = function(): (any, any, any) return {}, nil, {people = {}, nodes = {}} end
            local added, why = people.add("net:node-z:u")
            test.is_nil(added, "the users directory knows it, and still it is not added as local")
            test.eq(why, "nobody by that id has been heard of on node-z")
        end)

        test.it("Not in List: a read message keeps the sender; newest conversation first; last_at either way", function()
            fresh()
            be(ANNA)
            assert(people.add(BOB.user_id))
            be(DAVE)
            assert(people.send(ANNA.user_id, "hello from Dave"))
            be(YULIA)
            assert(people.send(ANNA.user_id, "hello from Yulia"))
            be(BOB)
            assert(people.send(ANNA.user_id, "hi"))
            be(ANNA)
            test.eq(people.mark_read(DAVE.user_id), 1)
            test.eq(people.mark_read(YULIA.user_id), 1)
            local list = assert(people.contacts())
            local lines = {}
            for _, one in ipairs(list) do lines[#lines + 1] = one.id .. "," .. tostring(one.listed) .. "," .. tostring(one.unread) end
            test.eq(table.concat(lines, "|"), "u-bob,true,1|u-yulia,false,0|u-dave,false,0",
                "the contact first; then who wrote, read or not, newest conversation first")
            local newest = rows("SELECT MAX(created_at) AS at FROM chicago_aicq_messages WHERE from_id = 'u-yulia'")[1].at
            test.eq(list[2].last_at, newest, "last_at is the pair's newest message")
            assert(people.send(DAVE.user_id, "a reply to Dave"))
            test.eq(ids(assert(people.contacts())), "u-bob|u-dave|u-yulia", "the caller's reply makes Dave's conversation the newest")
        end)

        test.it("dismiss: off the list until they write again; unread always shows; add clears it", function()
            fresh()
            be(DAVE)
            assert(people.send(ANNA.user_id, "one"))
            be(ANNA)
            test.eq(people.dismiss(DAVE.user_id), true)
            test.eq(ids(assert(people.contacts())), "u-dave", "dismissed with an unread message: still shown")
            assert(people.mark_read(DAVE.user_id))
            test.eq(#assert(people.contacts()), 0, "read and dismissed: gone")
            be(DAVE)
            assert(people.send(ANNA.user_id, "two"))
            be(ANNA)
            local back = assert(people.contacts())
            test.eq(back[1].id .. "," .. tostring(back[1].listed) .. "," .. tostring(back[1].unread), "u-dave,false,1",
                "a newer message brings him back")
            assert(people.mark_read(DAVE.user_id))
            test.eq(ids(assert(people.contacts())), "u-dave", "and read, he stays: that message is newer than the dismissal")
            test.eq(people.dismiss(DAVE.user_id), true)
            test.eq(#assert(people.contacts()), 0, "dismissed again")
            assert(people.send(DAVE.user_id, "my reply"))
            test.eq(#assert(people.contacts()), 0, "the caller's own message does not undo the dismissal")

            test.eq(people.add(DAVE.user_id), true)
            test.eq(#rows("SELECT other_id FROM chicago_aicq_dismissed WHERE owner_id = 'u-anna'"), 0, "add clears the dismissal")
            local added = assert(people.contacts())
            test.eq(added[1].id .. "," .. tostring(added[1].listed), "u-dave,true")
            test.eq(people.remove(DAVE.user_id), true)
            local removed = assert(people.contacts())
            test.eq(removed[1].id .. "," .. tostring(removed[1].listed), "u-dave,false",
                "removed again, he is Not in List: nothing dismisses him now")

            local self_ok, self_why = people.dismiss(ANNA.user_id)
            test.is_nil(self_ok)
            test.eq(self_why, "you cannot dismiss yourself")
            local ghost_ok, ghost_why = people.dismiss("u-ghost")
            test.is_nil(ghost_ok)
            test.eq(ghost_why, "no such account: u-ghost")
            local blank_ok, blank_why = people.dismiss("  ")
            test.is_nil(blank_ok)
            test.eq(blank_why, "no account named")
        end)

        test.it("send and history: the pair oldest first, the limit, the refusals, the messenger told", function()
            fresh()
            be(ANNA)
            assert(people.send(BOB.user_id, "one"))
            be(BOB)
            assert(people.send(ANNA.user_id, "two"))
            be(ANNA)
            assert(people.send(BOB.user_id, "three"))
            be(BOB)
            assert(people.send(ANNA.user_id, "four"))
            be(ANNA)
            local last = assert(people.send(BOB.user_id, "  five  "))
            be(DAVE)
            assert(people.send(ANNA.user_id, "not in this pair"))
            be(ANNA)
            local all = assert(people.history(BOB.user_id))
            test.eq(bodies(all), "one|two|three|four|five", "oldest first, trimmed, only the pair")
            test.eq(all[5].id .. "|" .. all[5].from_id .. ">" .. all[5].to_id, last .. "|u-anna>u-bob")
            test.eq(tostring(all[4].read) .. "|" .. tostring(all[4].at ~= ""), "false|true")
            test.eq(bodies(assert(people.history(BOB.user_id, 2))), "four|five", "the last two")
            test.eq(bodies(assert(people.history(BOB.user_id, 0))), "five", "a limit under one is one")

            local heard: any = nil
            for _, entry in ipairs(told.list) do
                if entry.body.message_id == last then heard = entry end
            end
            test.not_nil(heard, "the messenger is told of each message")
            test.eq(heard.name .. "|" .. heard.topic .. "|" .. heard.body.to_id, "chicago.aicq.messenger|aicq.sent|u-bob")

            local function refused(to: string, text: string): any
                local id, why = people.send(to, text)
                test.is_nil(id)
                return why
            end
            test.eq(refused(BOB.user_id, "   "), "the message is empty")
            test.eq(refused(ANNA.user_id, "me"), "a message to yourself is not sent")
            test.eq(refused("u-ghost", "x"), "no such account: u-ghost")
            test.eq(refused("", "x"), "no recipient")
            test.eq(refused(BOB.user_id, string.rep("я", 4001)), "the message is longer than 4000 characters")
            test.not_nil(people.send(BOB.user_id, string.rep("я", 4000)), "4000 characters (8000 bytes) are not too long")

            people.deps.send = function(): (boolean, any) return false, "chicago.aicq.messenger is not running (x)" end
            local id, err, notice = people.send(BOB.user_id, "stored anyway")
            test.not_nil(id)
            test.is_nil(err)
            test.eq(notice, "the message is stored, but the messenger did not hear of it: chicago.aicq.messenger is not running (x)")
            test.eq(#rows("SELECT id FROM chicago_aicq_messages WHERE id = $1", {id}), 1)
        end)

        test.it("unread and mark_read: per sender, one person's only, once, the messenger told once", function()
            fresh()
            be(BOB)
            for index = 1, 3 do assert(people.send(ANNA.user_id, "b" .. index)) end
            be(CAROL)
            assert(people.send(ANNA.user_id, "c1"))
            be(ANNA)
            assert(people.send(BOB.user_id, "a1"))
            local counts = assert(people.unread())
            test.eq(keys(counts) .. "=" .. tostring(counts["u-bob"]) .. "," .. tostring(counts["u-carol"]), "u-bob,u-carol=3,1")
            test.eq(people.count_unread("u-anna"), 4)
            test.eq(people.count_unread("u-bob"), 1)

            told.list = {}
            test.eq(people.mark_read(BOB.user_id), 3)
            test.eq(#told.list .. "|" .. told.list[1].topic .. "|" .. told.list[1].body.user_id, "1|aicq.read|u-anna")
            test.eq(people.mark_read(BOB.user_id), 0, "twice marks nothing")
            test.eq(#told.list, 1, "and tells nobody")
            test.eq(keys(assert(people.unread())), "u-carol")
            test.eq(people.count_unread("u-anna"), 1)
            local flags = {}
            for _, message in ipairs(assert(people.history(BOB.user_id))) do
                flags[#flags + 1] = message.body .. ":" .. tostring(message.read)
            end
            test.eq(table.concat(flags, "|"), "b1:true|b2:true|b3:true|a1:false")
        end)

        test.it("find: an exact e-mail, a name prefix of three letters, a UIN; no e-mail in the answer, not the caller", function()
            fresh()
            be(ANNA)
            local exact = assert(people.find("BOB@Example.com"))
            test.eq(#exact, 1)
            test.eq(exact[1].id, "u-bob")
            test.eq(keys(exact[1]), "id,name,uin", "never an e-mail in the answer")
            test.eq(names(assert(people.find("bob"))), "Bob Marley|Bobby Tables")
            test.eq(names(assert(people.find("  BOBBY "))), "Bobby Tables")
            test.eq(#assert(people.find("marley")), 0, "a prefix of the full name, not a word inside it")
            test.eq(#assert(people.find("carol")), 0, "a name query never matches an e-mail")
            test.eq(names(assert(people.find("carol@example.com"))), "carol@example.com",
                "no full name: the e-mail is the name, as everywhere on the stand")
            test.eq(#assert(people.find("anna@example.com")), 0, "the caller is left out")
            test.eq(#assert(people.find("Anna")), 0, "by name too")
            test.eq(names(assert(people.find(tostring(people.uin("u-bob"))))), "Bob Marley")
            test.eq(#assert(people.find("123456789")), 0, "a UIN nobody has while the directory's list is not full: nobody")
            test.eq(#assert(people.find("nobody@example.com")), 0, "an e-mail nobody has: nobody")
            test.eq(names(assert(people.find("Юли"))), "Юлия Петрова", "three letters are six bytes here")
            local short, swhy = people.find("Юл")
            test.is_nil(short)
            test.eq(swhy, "a name needs three letters or more")
            local two, twhy = people.find("bo")
            test.is_nil(two)
            test.eq(twhy, "a name needs three letters or more")
            local blank, bwhy = people.find("  ")
            test.is_nil(blank)
            test.eq(bwhy, "type an e-mail, a name or a UIN")

            guard.granted = false
            local denied, dwhy = people.find("bob")
            test.is_nil(denied)
            test.eq(dwhy, "the users directory (search) is not granted to your account"
                .. " (kickside.users.directory:directory_search)")
            test.eq(guard.asked[#guard.asked], "access kickside.users.directory:directory_search")
        end)

        test.it("find: at most twenty, and what lies past the directory's 50 newest accounts is said, not hidden", function()
            fresh()
            be(ANNA)
            local many = {}
            for index = 1, 60 do
                many[index] = {user_id = string.format("u-t%02d", index), email = string.format("t%02d@example.com", index),
                    full_name = string.format("Test User %02d", index)}
            end
            users(many)
            local found = assert(people.find("test"))
            test.eq(#found, 20, "at most twenty")
            test.eq(found[1].name .. "|" .. found[20].name, "Test User 11|Test User 30",
                "by name, from the 50 newest the directory reads")
            local old, owhy = people.find(tostring(people.uin("u-t01")))
            test.is_nil(old)
            test.eq(owhy, "UIN " .. tostring(people.uin("u-t01"))
                .. " is not among the 50 newest accounts the users directory reads; search by e-mail or name")
            test.eq(names(assert(people.find(tostring(people.uin("u-t60"))))), "Test User 60")
            local gone, gwhy = people.find("t01@example.com")
            test.is_nil(gone)
            test.eq(gwhy, "an account with this e-mail exists, but it is not among the 50 newest accounts"
                .. " the users directory reads")
            test.eq(names(assert(people.find("t60@example.com"))), "Test User 60")
        end)

        test.it("UIN: nine digits, the same for the same id, apart for different ids", function()
            test.eq(people.uin("u-anna"), 186565381)
            test.eq(people.uin("u-bob"), 279391452)
            test.eq(people.uin("01a0685d-4516-7180-8d42-bcf6064c0136"), 671442736, "a uuid-shaped id")
            test.eq(people.uin(nil), 100000000, "no id: the lowest")
            test.eq(people.uin("u-anna"), people.uin("u-anna"))
            local seen: any = {}
            for index = 1, 200 do
                local value = people.uin("user-" .. tostring(index))
                test.is_true(value >= 100000000 and value <= 999999999, tostring(value))
                seen[value] = true
            end
            local distinct = 0
            for _ in pairs(seen) do distinct = distinct + 1 end
            test.eq(distinct, 200, "two hundred ids, two hundred UINs")
        end)

        test.it("the messenger's watch table and the presence tally", function()
            local watch = people.watchers()
            test.eq(people.watch(watch, "p1", "u-anna"), true, "a new pid: monitor it")
            test.eq(people.watch(watch, "p1", "u-bob"), false, "the same pid again: already monitored")
            test.eq(people.watch(watch, "p2", "u-anna"), true)
            test.eq(people.watch(watch, "p3", ""), false, "no person: no watch")
            test.eq(table.concat(people.targets(watch, {to_id = "u-anna", from_id = "u-bob"}), ","), "p1,p2",
                "both ends, each pid once")
            test.eq(people.unwatch(watch, "p1", "u-anna"), false, "p1 still watches Bob")
            test.eq(table.concat(people.targets(watch, {to_id = "u-bob", from_id = "u-x"}), ","), "p1")
            people.forget(watch, "p1")
            test.eq(#people.targets(watch, {to_id = "u-bob", from_id = "u-x"}), 0, "an exited pid watches nothing")
            test.eq(people.unwatch(watch, "p2"), true, "all of p2's watches go")
            test.is_nil(next(watch.by_user), "nobody is watched any more")

            local seen = {a = {user = "u-anna", at = 100}, b = {user = "u-anna", at = 100},
                c = {user = false, at = 100}, d = {user = "u-bob", at = 0}}
            local now = people.tally(seen, 110, 120)
            test.eq(keys(now) .. "=" .. tostring(now["u-anna"]) .. "," .. tostring(now["u-bob"]), "u-anna,u-bob=2,1")
            local later = people.tally(seen, 125, 120)
            test.eq(keys(later), "u-anna", "an answer as old as the ttl no longer counts")
        end)

        test.it("the messenger pings the watchers of both ends from the stored row, not the body", function()
            fresh()
            people.deps.send = REAL.send
            local messenger = process.registry.lookup(people.MESSENGER)
            test.not_nil(messenger, "the messenger service runs in the harness as on the stand")
            local pings = assert(process.listen(people.NEW, {message = true}))
            process.send(messenger, people.WATCH, {user_id = "u-bob"})
            be(ANNA)
            local id, err, notice = people.send(BOB.user_id, "ping me")
            test.not_nil(id, tostring(err))
            test.is_nil(notice)
            local ping = receive(pings, "2s")
            test.not_nil(ping, "the recipient's watcher is pinged")
            test.eq(ping.from_id .. ">" .. ping.to_id .. "|" .. tostring(ping.message_id == id), "u-anna>u-bob|true")

            process.send(messenger, people.WATCH, {user_id = "u-carol"})
            process.send(messenger, people.SENT, {message_id = id, to_id = "u-carol", from_id = "u-mallory"})
            local forged = receive(pings, "2s")
            test.not_nil(forged, "a forged aicq.sent about a real row")
            test.eq(forged.from_id .. ">" .. forged.to_id, "u-anna>u-bob", "the ends come from the stored row")
            test.is_nil(receive(pings, "300ms"), "one ping per watching pid")
            process.send(messenger, people.SENT, {message_id = "no-such-message", to_id = "u-bob"})
            test.is_nil(receive(pings, "300ms"), "a message id that does not read pings nobody")

            process.send(messenger, people.UNWATCH, {})
            process.send(messenger, people.WATCH, {user_id = "u-anna"})
            local second = assert(people.send(BOB.user_id, "again"))
            local own = receive(pings, "2s")
            test.eq(own and own.message_id, second, "the sender's watcher is pinged too")
            process.send(messenger, people.UNWATCH, {})
            assert(people.send(BOB.user_id, "after unwatch"))
            test.is_nil(receive(pings, "300ms"), "unwatched: no more pings")
            process.unlisten(pings)
        end)

        test.it("the tray per desktop: the envelope with 3 unread, the flower with 0 and on a desktop without a person", function()
            fresh()
            people.deps.send = REAL.send
            people.deps.who = REAL.who
            local presence = process.registry.lookup(people.PRESENCE)
            test.not_nil(presence, "the presence service runs in the harness as on the stand")
            local lists = assert(process.listen("desktop.list", {message = true}))
            local trays = assert(process.listen("desktop.tray", {message = true}))
            assert(process.registry.register(DESK))

            -- desk(user, want) — answer this desktop's questions as `user`'s until
            -- an item `want` accepts is pushed to its tray.
            local function desk(user: any, want: any): any
                local deadline = time.after("4s")
                while true do
                    local picked = channel.select({lists:case_receive(), trays:case_receive(), deadline:case_receive()})
                    if picked.channel == deadline or not picked.ok then return nil end
                    local body: any = people.unwrap(picked.value:payload())
                    if picked.channel == lists then
                        process.send(tostring(body.reply_to), "desktop.reply", {ok = true, command = "desktop.list",
                            user = user and {id = user.user_id, name = user.full_name} or nil})
                    elseif want(body) then
                        return body
                    end
                end
            end

            be(BOB)
            for index = 1, 3 do assert(people.send(ANNA.user_id, "b" .. index)) end
            -- The list's report makes the service push now, not on its minute tick.
            process.send(presence, "aicq.presence_report", {online = 4, offline = 0})
            local mail = desk(ANNA, function(item: any): boolean return item.text == "aICQ (3)" end)
            test.not_nil(mail, "Anna's desktop gets the envelope")
            test.eq(table.concat({mail.key, mail.title, mail.image, mail.entry}, "|"),
                "chicago.aicq|3 new messages|chicago.aicq:images/message|chicago.aicq:contacts")
            local online = assert(people.online())
            test.eq(online["u-anna"], 1, "the service tells who is online and on how many desktops")

            be(ANNA)
            test.eq(people.mark_read(BOB.user_id), 3)
            local flower = desk(ANNA, function(item: any): boolean return item.text == "aICQ" end)
            test.not_nil(flower, "0 unread: the flower again, without waiting for the tick")
            test.eq(flower.title .. "|" .. flower.image, "0 people online, 4 agents|chicago.aicq:images/aicq",
                "nobody besides Anna online; the agents as the list reported")

            be(BOB)
            assert(people.send(ANNA.user_id, "b4"))
            process.send(presence, "aicq.presence_report", {online = 4, offline = 0})
            -- Late flowers for Anna's desktop may still be queued (the messenger's
            -- refreshes of the three messages can arrive after mark_read): only a
            -- flower without a people count answers "nobody logged on".
            local plain = desk(nil, function(item: any): boolean
                return item.text == "aICQ" and not string.find(tostring(item.title), "people", 1, true)
            end)
            test.not_nil(plain, "a desktop nobody logged on to keeps the flower")
            test.eq(plain.title, "4 agents online", "and speaks of agents alone")
            process.registry.unregister(DESK)
            process.unlisten(lists)
            process.unlisten(trays)
        end)

        test.it("the presence service joins aICQ's network and announces who is logged on here, by name, an e-mail id too", function()
            fresh()
            people.deps.send = REAL.send
            people.deps.who = REAL.who
            local presence = process.registry.lookup(people.PRESENCE)
            test.not_nil(presence)
            local scope = assert(pg.open(network.SCOPE))
            local members = assert(scope:get_members(network.GROUP))
            local joined = false
            for _, pid in ipairs(members) do if tostring(pid) == tostring(presence) then joined = true end end
            test.is_true(joined, "the service is a member of " .. network.GROUP)

            -- Zed on a desktop here, as the tray sees him: an id that is an
            -- e-mail address, as the users module mints them (the owner's
            -- butschster@gmail.com).
            local ZED = {user_id = "zed@example.com", full_name = "Zed Zero"}
            local lists = assert(process.listen("desktop.list", {message = true}))
            local rosters = assert(process.listen(network.ROSTER, {message = true}))
            assert(scope:join(network.GROUP))
            assert(process.registry.register(DESK))
            process.send(presence, "aicq.presence_report", {online = 0, offline = 0})
            local heard: any = nil
            local deadline = time.after(tostring(network.ANNOUNCE_S + 3) .. "s")
            while heard == nil do
                local picked = channel.select({lists:case_receive(), rosters:case_receive(), deadline:case_receive()})
                if picked.channel == deadline or not picked.ok then break end
                local body: any = people.unwrap(picked.value:payload())
                if picked.channel == lists then
                    process.send(tostring(body.reply_to), "desktop.reply", {ok = true, command = "desktop.list",
                        user = {id = ZED.user_id, name = ZED.full_name}})
                elseif tostring(picked.value:from()) == tostring(presence) then
                    for _, item in ipairs(body.p or {}) do
                        if item.i == ZED.user_id then heard = item end
                    end
                end
            end
            test.not_nil(heard, "a roster with Zed within one announcement")
            test.eq(heard and heard.m, "Zed Zero", "by the name his desktop gives")

            -- A window is told the network too; alone, nobody is elsewhere.
            local online, why, seen = people.deps.who()
            test.not_nil(online, tostring(why))
            test.eq(type(seen), "table", "the network's view comes with who is online")
            test.eq(#seen.people, 0, "this node is never its own Network")
            scope:leave(network.GROUP)
            process.registry.unregister(DESK)
            process.unlisten(lists)
            process.unlisten(rosters)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
