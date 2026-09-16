-- aICQ's notifications (docs/aicq-people.md §5): what the recipient of an
-- arriving message sees — a balloon tip by the notification area and a flash
-- of their aICQ windows.
--
-- Two halves, as everywhere in this module. The decision is pure
-- (`aicq.arrival`, `aicq.preview`): the title, the one-line preview, the
-- picture, the tail's anchor, what a click opens and the key that collapses a
-- burst, checked without a desktop. The wiring is the messenger itself,
-- running in the harness as it does in the application: this suite answers as
-- a desktop of the shell's family (`control.SERVICE_NAME`, the family
-- `chicago.shell.sdk:notify` looks desktops up by), says who is logged on to
-- it, and keeps what the messenger sent it.
--
-- The harness stands the platform in, the users directory as a contract among
-- it (test/stubs/users/src/contract), so the messenger's whole road to a
-- sender's name — its actor, its policies, `contract.get`, the directory —
-- is walked here and not merely assumed. One case spawns a caller under the
-- messenger's very policies, so a missing grant is named rather than guessed
-- at; "New message" stays the fallback when the directory does not answer.
local test = require("test")
local people = require("people")
local aicq = require("aicq")
local directory = require("directory")
local user_repo = require("user_repo")
local control = require("control")
local sql = require("sql")
local process = require("process")
local channel = require("channel")
local time = require("time")
local json = require("json")
local security = require("security")

local ANNA = {user_id = "u-anna", email = "anna@example.com", full_name = "Anna Karenina"}
local BOB = {user_id = "u-bob", email = "bob@example.com", full_name = "Bob Marley"}
local CAROL = {user_id = "u-carol", email = "carol@example.com", full_name = ""}
local EVERYONE = {ANNA, BOB, CAROL}

local DESK = control.SERVICE_NAME

-- The roads the library takes for real: the messenger must hear of a
-- message, and the directory is opened as a contract (the harness stands one
-- in — test/stubs/users/src/contract).
local REAL = {send = people.deps.send, directory = people.deps.directory}

-- Tables, not locals: an error under pcall splits upvalues in go-lua.
local guard: any = {who = nil, granted = true}
local desk: any = {lists = nil, balloons = nil, flashes = nil, trays = nil, registered = false}

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

-- users(list) — the harness's users table holds exactly these.
local function users(list: any)
    exec("CREATE TABLE IF NOT EXISTS " .. user_repo.TABLE .. " (user_id TEXT PRIMARY KEY, email TEXT, full_name TEXT,"
        .. " status TEXT, created_at TEXT)")
    exec("DELETE FROM " .. user_repo.TABLE)
    for index, user in ipairs(list) do
        exec("INSERT INTO " .. user_repo.TABLE .. " (user_id, email, full_name, status, created_at)"
            .. " VALUES ($1, $2, $3, 'active', $4)",
            {user.user_id, user.email, user.full_name, string.format("2026-01-01 %06d", index)})
    end
end

local function fresh()
    exec("DELETE FROM chicago_aicq_contacts")
    exec("DELETE FROM chicago_aicq_messages")
    exec("DELETE FROM chicago_aicq_dismissed")
    guard.who, guard.granted = nil, true
    people.deps.security = {
        actor = function() return guard.who end,
        can = function(): boolean return guard.granted end,
    }
    people.deps.directory = function(method: string, args: any): (any, any)
        return directory[method](args), nil
    end
    people.deps.send = REAL.send
    people.deps.who = function(): (any, any) return {}, nil end
    users(EVERYONE)
end

-- ─── the stand-in desktop ───────────────────────────────────────────────
--
-- One process of this suite answers under the family's first name. The
-- notifications reach it as ordinary messages on their own topics, and every
-- question of the base's `ask` wants a reply on `desktop.reply` naming the
-- command it answers.

local function open_desk()
    desk.lists = assert(process.listen("desktop.list", {message = true}))
    desk.balloons = assert(process.listen("desktop.balloon", {message = true}))
    desk.flashes = assert(process.listen("desktop.flash", {message = true}))
    -- The presence service's item for this desktop: what an asked-for tray
    -- refresh looks like from outside the two services.
    desk.trays = assert(process.listen("desktop.tray", {message = true}))
    assert(process.registry.register(DESK))
    desk.registered = true
end

local function close_desk()
    if desk.registered then process.registry.unregister(DESK) end
    desk.registered = false
    for _, name in ipairs({"lists", "balloons", "flashes", "trays"}) do
        if desk[name] then process.unlisten(desk[name]) end
        desk[name] = nil
    end
end

local function reply(body: any, answer: any)
    if type(body.reply_to) == "string" and body.reply_to ~= "" then process.send(tostring(body.reply_to), "desktop.reply", answer) end
end

-- serve(user, windows, want, budget) -> the notification `want` accepted, nil
-- when none came in time. The desktop answers `desktop.list` as `user`'s with
-- `windows` open on it, and every notification with "ok"; the presence
-- service's questions are answered the same way and cost nothing.
-- While this is set the desktop refuses balloons, as one holding eight does.
-- A table, not a local: an error under pcall splits upvalues in go-lua.
local refusing: any = {balloon = false}

local function serve(user: any, windows: any, want: any, budget: string?): any
    local deadline = time.after(budget or "6s")
    while true do
        local picked = channel.select({desk.lists:case_receive(), desk.balloons:case_receive(),
            desk.flashes:case_receive(), desk.trays:case_receive(), deadline:case_receive()})
        if picked.channel == deadline or not picked.ok then return nil end
        local body: any = people.unwrap(picked.value:payload())
        if picked.channel == desk.lists then
            reply(body, {ok = true, command = "desktop.list", service = DESK,
                user = user and {id = user.user_id, name = user.full_name} or nil,
                screen = {width = 100, height = 30}, windows = windows or {}})
        else
            local topic = "desktop.tray"
            if picked.channel == desk.balloons then topic = "desktop.balloon"
            elseif picked.channel == desk.flashes then topic = "desktop.flash" end
            -- A tray item is pushed without a reply, as the base's `tray` does.
            if topic == "desktop.balloon" and refusing.balloon then
                reply(body, {ok = false, command = topic, error = "the desktop already holds 8 balloons"})
            elseif topic ~= "desktop.tray" then
                reply(body, {ok = true, command = topic})
            end
            local got: any = {topic = topic, body = body}
            if want(got) then return got end
        end
    end
end

local function is_balloon(got: any): boolean
    return got.topic == "desktop.balloon"
end

-- receive(ch, budget) -> the next message's body, nil when none came in time.
local function receive(ch: any, budget: string): any
    local timer = time.after(budget)
    local picked = channel.select({ch:case_receive(), timer:case_receive()})
    if picked.channel == timer or not picked.ok then return nil end
    return people.unwrap(picked.value:payload())
end

local function define_tests()
    test.describe("aICQ notifications", function()
        test.it("preview: one line, blanks squeezed, trimmed, cut at eighty characters with an ellipsis", function()
            test.eq(aicq.preview("  hi there  "), "hi there")
            test.eq(aicq.preview("two\nlines\there"), "two lines here", "no line break reaches a balloon")
            test.eq(aicq.preview(nil), "", "nothing to preview is no text")
            test.eq(aicq.preview("a b   c"), "a b c")
            local long = string.rep("x", aicq.PREVIEW_MAX)
            test.eq(aicq.preview(long), long, "exactly eighty characters are not cut")
            -- The ellipsis counts against the eighty: what is shown is never
            -- longer than the limit, here or in the title.
            test.eq(aicq.preview(long .. "y"), string.rep("x", aicq.PREVIEW_MAX - 1) .. "…",
                "the eighty-first makes an ellipsis, and the answer stays eighty characters")
            local cyrillic = string.rep("я", aicq.PREVIEW_MAX + 5)
            test.eq(aicq.preview(cyrillic), string.rep("я", aicq.PREVIEW_MAX - 1) .. "…",
                "characters, not bytes: two-byte runes are counted as one each")
            test.eq(aicq.preview(string.rep("x", aicq.PREVIEW_MAX - 1) .. "   tail"),
                string.rep("x", aicq.PREVIEW_MAX - 1) .. "…", "no blank is left before the ellipsis")
        end)

        test.it("arrival: the sender's name, the preview, the picture, the tail and the click that opens the conversation", function()
            local balloon = aicq.arrival({from_id = "u-anna", to_id = "u-bob", body = "  hi\nBob  "}, "Anna Karenina")
            test.not_nil(balloon)
            test.eq(balloon.user, "u-bob", "the recipient's desktops, never the sender's")
            test.eq(balloon.title, "Anna Karenina")
            test.eq(balloon.text, "hi Bob")
            test.eq(balloon.image, "chicago.aicq:images/message", "aICQ's own envelope from the module's pack")
            test.eq(balloon.anchor, aicq.TRAY_KEY, "the tail points at aICQ's tray item")
            test.eq(balloon.entry, aicq.MESSAGE, "a click opens the message window")
            test.eq(balloon.args, "u-anna\nAnna Karenina", "with the sender: the conversation with them, not a blank one")
            test.eq(balloon.key, "aicq:u-anna", "one key per sender: a burst replaces its own balloon")
            test.eq(balloon.timeout, aicq.BALLOON_TIMEOUT)

            local unnamed = aicq.arrival({from_id = "u-anna", to_id = "u-bob", body = "hi"}, nil)
            test.eq(unnamed.title, aicq.NEW_MESSAGE, "a name that was not read is not replaced by an id")
            test.eq(unnamed.args, "u-anna\n", "the window is still opened on the sender")
            test.eq(aicq.arrival({from_id = "u-anna", to_id = "u-bob", body = "hi"}, "   ").title, aicq.NEW_MESSAGE,
                "a blank name is no name")
            test.eq(aicq.arrival({from_id = "u-anna", to_id = "u-bob", body = "   "}, "Anna").text, aicq.NO_TEXT,
                "a body of blanks still says something")

            test.is_nil(aicq.arrival({from_id = "u-anna", to_id = "u-anna", body = "note"}, "Anna"),
                "a message to oneself shows no balloon")
            test.is_nil(aicq.arrival({from_id = "", to_id = "u-bob", body = "x"}, nil), "no sender, no balloon")
            test.is_nil(aicq.arrival({from_id = "u-anna", to_id = "", body = "x"}, nil), "no recipient, no balloon")
            test.is_nil(aicq.arrival(nil, nil))
        end)

        test.it("a name longer than the compositor takes is cut, not left to have the balloon refused", function()
            local long = string.rep("Ы", aicq.TITLE_MAX + 20)
            local title = aicq.arrival({from_id = "u-anna", to_id = "u-bob", body = "hi"}, long).title
            local count = select(2, string.gsub(title, "[^\128-\191]", ""))
            test.eq(count, aicq.TITLE_MAX, "exactly what the base takes, the ellipsis counted in")
            test.eq(string.sub(title, -3), "…", "and it ends in the ellipsis")
            local fits = string.rep("a", aicq.TITLE_MAX)
            test.eq(aicq.arrival({from_id = "u-anna", to_id = "u-bob", body = "hi"}, fits).title, fits,
                "a name that already fits is left whole")
            local over = string.rep("a", aicq.TITLE_MAX + 1)
            test.eq(aicq.arrival({from_id = "u-anna", to_id = "u-bob", body = "hi"}, over).title,
                string.rep("a", aicq.TITLE_MAX - 1) .. "…", "one character too many is cut to fit")
        end)

        test.it("name_of: the directory's name behind its gate, and a named refusal instead of an id", function()
            fresh()
            be(ANNA)
            test.eq(people.name_of(BOB.user_id), "Bob Marley")
            test.eq(people.name_of(CAROL.user_id), "carol@example.com", "no full name: the e-mail, as everywhere")
            local ghost, why = people.name_of("u-ghost")
            test.is_nil(ghost)
            test.eq(why, "the users directory does not know u-ghost")
            local blank, bwhy = people.name_of("  ")
            test.is_nil(blank)
            test.eq(bwhy, "no account named")
            guard.granted = false
            local denied, dwhy = people.name_of(BOB.user_id)
            test.is_nil(denied)
            test.eq(dwhy, "the users directory (resolve) is not granted to your account"
                .. " (kickside.users.directory:directory_resolve)")
        end)

        test.it("the harness's directory contract answers the library's own road", function()
            fresh()
            -- Not the stand-in used by the cases above: the real
            -- `contract.get(kickside.contract:directory)` road, which is what
            -- the messenger walks in its own process. Without this the
            -- messenger's title could only ever be the fallback, and nothing
            -- here would say why.
            people.deps.directory = REAL.directory
            be(ANNA)
            local name, why = people.name_of(BOB.user_id)
            test.eq(name, "Bob Marley", "the directory contract did not answer: " .. tostring(why))
            people.deps.directory = function(method: string, args: any): (any, any)
                return directory[method](args), nil
            end
        end)

        test.it("the messenger's own policies reach the name: its actor, its scope, nothing borrowed", function()
            fresh()
            -- Exactly what the module declares for the service, and nothing
            -- else: if this passes, the grant in src/_index.yaml is enough;
            -- if it fails, the answer names the right that is missing.
            local scoped: any = {}
            for _, id in ipairs({"chicago.aicq:messenger_scope", "chicago.aicq:messenger_db",
                "chicago.aicq:messenger_directory", "chicago.aicq:messenger_contract",
                "chicago.aicq:messenger_binding", "chicago.aicq:messenger_call",
                "chicago.aicq:db_name"}) do
                local policy, perr = security.policy(id)
                test.not_nil(policy, "policy " .. id .. ": " .. tostring(perr))
                scoped[#scoped + 1] = policy
            end
            local events = assert(process.events())
            local pid, err = process.with_context({})
                :with_actor(security.new_actor("chicago.aicq.messenger"))
                :with_scope(security.new_scope(scoped))
                :spawn_monitored("app:name_caller", "app:processes", json.encode({user_id = BOB.user_id}))
            test.not_nil(pid, "the caller did not start: " .. tostring(err))
            -- The answer is the process's result, read from its EXIT event.
            local got: any = {answer = nil}
            local deadline = time.after("10s")
            while got.answer == nil do
                local picked = channel.select({events:case_receive(), deadline:case_receive()})
                if picked.channel == deadline or not picked.ok then break end
                local event: any = picked.value
                if event.kind == process.event.EXIT and tostring(event.from) == tostring(pid) then
                    local result: any = event.result
                    if type(result) == "table" and type(result.value) == "table" then got.answer = result.value
                    else got.answer = {why = "the caller ended without an answer: " .. tostring(event.error)} end
                end
            end
            test.not_nil(got.answer, "the caller did not end")
            test.eq(got.answer and got.answer.name, "Bob Marley",
                "the messenger's policies did not reach the name: " .. tostring(got.answer and got.answer.why))
        end)

        test.it("an arriving message: the recipient's desktop gets the balloon and its aICQ window flashes", function()
            fresh()
            open_desk()
            be(ANNA)
            local id = assert(people.send(BOB.user_id, "  hello\nBob  "))
            local balloon = serve(BOB, {{id = "w1", entry = aicq.MESSAGE}}, is_balloon)
            test.not_nil(balloon, "Bob's desktop got no balloon")
            local body: any = balloon and balloon.body or {}
            test.eq(body.text, "hello Bob", "the stored text on one line")
            -- The whole road to the name, under the messenger's own actor and
            -- policies: the gate `chicago.aicq:messenger_directory` grants,
            -- the directory contract, `people.display_name`.
            test.eq(body.title, "Anna Karenina", "the sender's name, not the fallback")
            test.eq(body.image, "chicago.aicq:images/message")
            test.eq(body.anchor, aicq.TRAY_KEY)
            test.eq(body.entry, aicq.MESSAGE)
            test.eq(body.args, "u-anna\nAnna Karenina")
            test.eq(body.key, "aicq:u-anna")
            test.eq(body.timeout, aicq.BALLOON_TIMEOUT)
            test.not_nil(id)

            local flash = serve(BOB, {{id = "w1", entry = aicq.MESSAGE}}, function(got: any): boolean
                return got.topic == "desktop.flash"
            end)
            test.not_nil(flash, "the open conversation did not flash")
            test.eq(flash and flash.body.id, "w1", "the window of that entry, by the id the desktop listed")
            close_desk()
        end)

        test.it("a burst from one person replaces its own balloon, and the contact list flashes when no conversation is open", function()
            fresh()
            open_desk()
            be(ANNA)
            assert(people.send(BOB.user_id, "one"))
            local list_only: any = {{id = "w7", entry = aicq.CONTACTS}}
            local first = serve(BOB, list_only, is_balloon)
            test.not_nil(first, "no balloon for the first message")
            local flash = serve(BOB, list_only, function(got: any): boolean return got.topic == "desktop.flash" end)
            test.not_nil(flash, "no window flashed")
            test.eq(flash and flash.body.id, "w7", "no conversation open: the contact list asks for attention")

            assert(people.send(BOB.user_id, "two"))
            local second = serve(BOB, list_only, is_balloon)
            test.not_nil(second, "no balloon for the second message")
            -- The key is the sender's, not the message's: were it per
            -- message, two balloons would queue instead of one replacing the
            -- other, and eight of them fill a desktop.
            test.eq(first and first.body.key, "aicq:u-anna")
            test.eq(second and second.body.key, "aicq:u-anna",
                "the same sender, the same key: the queue does not fill up")
            test.eq(second and second.body.text, "two", "and the newest text is shown")
            close_desk()
        end)

        test.it("a refused balloon does not cost the flash: the window still asks for attention", function()
            fresh()
            open_desk()
            refusing.balloon = true
            be(ANNA)
            assert(people.send(BOB.user_id, "the desktop's queue is full"))
            local flash = serve(BOB, {{id = "w1", entry = aicq.MESSAGE}}, function(got: any): boolean
                return got.topic == "desktop.flash"
            end)
            refusing.balloon = false
            test.not_nil(flash, "the balloon was refused and the flash was lost with it")
            test.eq(flash and flash.body.id, "w1")
            close_desk()
        end)

        test.it("the sender gets nothing, and with no desktop open the pings and the tray refresh still happen", function()
            fresh()
            open_desk()
            local messenger = process.registry.lookup(people.MESSENGER)
            test.not_nil(messenger, "the messenger service runs in the harness as in the application")
            local pings = assert(process.listen(people.NEW, {message = true}))
            process.send(messenger, people.WATCH, {user_id = "u-anna"})
            be(ANNA)
            assert(people.send(BOB.user_id, "nothing for me"))
            test.not_nil(receive(pings, "3s"), "the sender's own window is pinged as before")
            -- Only the sender's desktop is open: Bob has none, so there is
            -- nobody to show a balloon to and none is sent anywhere.
            test.is_nil(serve(ANNA, {{id = "w1", entry = aicq.MESSAGE}}, is_balloon, "1500ms"),
                "a balloon reached the sender's desktop")
            close_desk()

            -- Nobody logged on anywhere: the ping still goes out, and a
            -- balloon with nowhere to go breaks nothing after it.
            assert(people.send(BOB.user_id, "still delivered"))
            test.not_nil(receive(pings, "3s"), "the ping is sent with no desktop open")

            -- And the tray refresh the messenger asks for is not lost either:
            -- with a desktop open again, the envelope follows the next message
            -- at once, without waiting for the presence service's tick. The
            -- service pushes to a desktop only once it has asked whose it is,
            -- and a report makes it ask now (as the contact list's does).
            open_desk()
            local presence = process.registry.lookup(people.PRESENCE)
            test.not_nil(presence, "the presence service runs in the harness as in the application")
            process.send(tostring(presence), aicq.REPORT, {online = 1, offline = 0})
            serve(BOB, {}, function(): boolean return false end, "800ms")
            assert(people.send(BOB.user_id, "and the tray follows"))
            local tray = serve(BOB, {}, function(got: any): boolean
                return got.topic == "desktop.tray" and string.find(tostring(got.body.text), "aICQ (", 1, true) == 1
            end)
            test.not_nil(tray, "the recipient's tray was not refreshed after the message")
            close_desk()
            process.send(messenger, people.UNWATCH, {})
            process.unlisten(pings)
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
