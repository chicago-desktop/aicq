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
        test.it("the migration made both tables and both indexes", function()
            local found = rows("SELECT name FROM sqlite_master WHERE name LIKE 'chicago_aicq_%'"
                .. " OR name LIKE 'idx_chicago_aicq_%' ORDER BY name")
            test.eq(names((function()
                local out = {}
                for _, row in ipairs(found) do out[#out + 1] = {name = row.name} end
                return out
            end)()), "chicago_aicq_contacts|chicago_aicq_dismissed|chicago_aicq_messages"
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
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
