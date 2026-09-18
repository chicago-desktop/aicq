-- aICQ's message window: opening loads the pair's history, marks it read and
-- watches the window's own person at the messenger; Send and Ctrl+Enter (both
-- of its shapes) send the input; the messenger's ping about a message between
-- the two reloads; failures are named; the layout stands apart — through the
-- model `chicago.aicq:aicq` (`talk_*`) with a stand-in `sys`, the SDK's own
-- context, editor and plan.
local test = require("test")
local ui = require("ui")
local app = require("app")
local editor = require("editor")
local aicq = require("aicq")

local ME = {id = "u-me", name = "Pavel", uin = "111111111"}
local LIST = "<pid.list>"
local ARGS = "u-anna\nAnna\n" .. LIST
local T = aicq.TALK

local function conversation(): any
    return {
        {id = "m1", from_id = "u-anna", to_id = "u-me", body = "Hello! Are you there?", at = "2026-09-15T10:21:07Z", read = true},
        {id = "m2", from_id = "u-me", to_id = "u-anna", body = "Yes.", at = "2026-09-15 10:22:30", read = true},
    }
end

-- The window's reads stood in. `rows` is the pair's history, `unread` what
-- `mark_read` finds; both live in the table, so a case changes them between
-- calls and the closures see it.
local function stand_in(over: any?): any
    local given: any = over or {}
    local sys: any = {given = given, rows = given.rows or conversation(), unread = given.unread or 0,
        contact = given.listed ~= false,
        calls = {history = {}, marked = {}, sent = {}, watched = {}, unwatched = {}, seen = {}, added = {}, told = {}}}
    function sys.me(): (any, any)
        if given.me_error then return nil, given.me_error end
        return ME, nil
    end
    function sys.history(user_id: any, limit: any): (any, any)
        sys.calls.history[#sys.calls.history + 1] = tostring(user_id) .. "/" .. tostring(limit)
        if given.history_error then return nil, given.history_error end
        return sys.rows, nil
    end
    function sys.mark_read(user_id: any): (any, any)
        sys.calls.marked[#sys.calls.marked + 1] = user_id
        if given.mark_error then return nil, given.mark_error end
        local count = sys.unread
        sys.unread = 0
        return count, nil
    end
    function sys.send(to_id: any, text: any): (any, any, any)
        sys.calls.sent[#sys.calls.sent + 1] = tostring(to_id) .. "|" .. tostring(text)
        if given.send_error then return nil, given.send_error end
        sys.rows[#sys.rows + 1] = {id = "m" .. tostring(#sys.rows + 1), from_id = ME.id, to_id = to_id, body = text,
            at = "2026-09-15T10:30:00Z"}
        return "m-new", nil, given.send_notice
    end
    function sys.watch(user_id: any): (any, any)
        sys.calls.watched[#sys.calls.watched + 1] = user_id
        if given.watch_error then return nil, given.watch_error end
        return true, nil
    end
    function sys.unwatch(user_id: any): (any, any)
        sys.calls.unwatched[#sys.calls.unwatched + 1] = user_id
        return true, nil
    end
    function sys.seen(opener: any): (any, any)
        sys.calls.seen[#sys.calls.seen + 1] = opener
        return true, nil
    end
    function sys.listed(user_id: any): (any, any)
        if given.listed_error then return nil, given.listed_error end
        return sys.contact, nil
    end
    function sys.add(user_id: any): (any, any)
        sys.calls.added[#sys.calls.added + 1] = user_id
        if given.add_error then return nil, given.add_error end
        sys.contact = true
        return true, nil
    end
    function sys.added(opener: any, user_id: any): (any, any)
        sys.calls.told[#sys.calls.told + 1] = tostring(opener) .. "|" .. tostring(user_id)
        return true, nil
    end
    return sys
end

local function window(width: integer?, height: integer?): any
    return app.context({width = width or 58, height = height or 20})
end

local function node(tree: any, id: string): any
    for _, item in ipairs(tree.children) do
        if item.id == id then return item end
        for _, inner in ipairs(item.children or {}) do
            if inner.id == id then return inner end
        end
    end
    return nil
end

local function status(model: any, ctx: any): string
    local tree = aicq.talk_view(model, ctx)
    return tostring(tree.children[#tree.children].text)
end

local function alert(model: any, ctx: any): boolean
    local tree = aicq.talk_view(model, ctx)
    return tree.children[#tree.children].alert == true
end

local function type_in(ctx: any, model: any, text: string)
    editor.set(ctx.editor(T.draft), text)
    aicq.talk_update(model, {type = "change", id = T.draft, drawn = true}, ctx)
end

local LEAVES: any = {button = true, label = true, list = true, editor = true}

local function clash(plan: any, width: integer, height: integer): string
    local items: any = {}
    for _, item in ipairs(plan.items) do
        if LEAVES[item.node.kind] and item.rect.w > 0 and item.rect.h > 0 then items[#items + 1] = item end
    end
    for index, a in ipairs(items) do
        local r = a.rect
        if r.x < 1 or r.y < 1 or r.x + r.w > width + 1 or r.y + r.h > height + 1 then
            return tostring(a.node.kind) .. ":" .. tostring(a.node.id) .. " leaves the client"
        end
        for other = index + 1, #items do
            local s = items[other].rect
            if r.x < s.x + s.w and s.x < r.x + r.w and r.y < s.y + s.h and s.y < r.y + r.h then
                return tostring(a.node.kind) .. ":" .. tostring(a.node.id) .. " overlaps "
                    .. tostring(items[other].node.kind) .. ":" .. tostring(items[other].node.id)
            end
        end
    end
    return "none"
end

local function define_tests()
    test.describe("aICQ message window", function()
        test.it("opening loads the last 200 of the pair, marks them read, watches its own person and tells the list", function()
            local sys = stand_in({unread = 2})
            local ctx = window()
            local model = aicq.talk_init(sys, ARGS, ctx)
            test.eq(table.concat(sys.calls.history, ","), "u-anna/200")
            test.eq(table.concat(sys.calls.marked, ","), "u-anna", "opening marks the person's messages read")
            test.eq(table.concat(sys.calls.watched, ","), "u-me", "the window watches its own person: pings go by the reader")
            test.eq(table.concat(sys.calls.seen, ","), LIST, "the list hears the count changed")
            test.eq(aicq.talk_title(model), "Anna - aICQ")
            test.eq(ctx.interaction.focus, T.draft, "the input has the focus: the window is opened to write")
            local quiet = stand_in({unread = 0})
            aicq.talk_init(quiet, ARGS, window())
            test.eq(#quiet.calls.seen, 0, "nothing was unread: the list is not bothered")
            local orphan = stand_in({unread = 3})
            local alone = aicq.talk_init(orphan, "u-anna\nAnna", window())
            test.eq(#orphan.calls.seen, 0, "no list opened it: nobody to tell")
            test.eq(alone.peer.name, "Anna")
            test.eq(aicq.talk_init(stand_in(), "u-anna", window()).peer.name, "u-anna", "without a name the id is the name")
        end)

        test.it("a message to another computer says under it that it waits, or why it never arrived", function()
            local rows = {
                {from_id = "u-me", to_id = "net:node-b:u-zoe", body = "are you there?", at = "2026-09-18T10:00:00.000000000Z",
                    pending = true},
                {from_id = "u-me", to_id = "net:node-b:u-zoe", body = "again", at = "2026-09-18T10:01:00.000000000Z",
                    failed = "a delivery without a recipient here"},
                {from_id = "u-me", to_id = "net:node-b:u-zoe", body = "arrived", at = "2026-09-18T10:02:00.000000000Z"},
            }
            local model = aicq.talk_init(stand_in({rows = rows}), "net:node-b:u-zoe\nZoe (node-b)\n" .. LIST, window())
            test.eq(table.concat(aicq.talk_lines(model, 60), "|"),
                "Pavel  2026-09-18 10:00|  are you there?|  (not delivered yet: it will be when node-b is back)"
                .. "||Pavel  2026-09-18 10:01|  again|  (not delivered: a delivery without a recipient here)"
                .. "||Pavel  2026-09-18 10:02|  arrived")
        end)

        test.it("shows the history as sender and time over the text, broken by words, own messages under own name", function()
            local model = aicq.talk_init(stand_in(), ARGS, window())
            test.eq(table.concat(aicq.talk_lines(model, 40), "|"),
                "Anna  2026-09-15 10:21|  Hello! Are you there?||Pavel  2026-09-15 10:22|  Yes.")
            local narrow = aicq.talk_lines(model, 16)
            test.eq(narrow[2] .. "|" .. narrow[3], "  Hello! Are |  you there?", "broken after the last space that fits")
            local odd = aicq.talk_init(stand_in({rows = {{from_id = "u-anna", body = "hi", at = "yesterday"}}}), ARGS, window())
            test.eq(aicq.talk_lines(odd, 40)[1], "Anna  yesterday", "a time of another shape is shown as it came")
            local ctx = window()
            local tree = aicq.talk_view(model, ctx)
            local log = node(tree, T.log)
            test.eq(#log.items, 5)
            test.eq(log.reveal, 5, "the newest message is brought into view")
            test.eq(status(model, ctx), "Ctrl+Enter sends.")
            test.is_nil(ui.problem(tree))
            local empty = aicq.talk_init(stand_in({rows = {}}), ARGS, window())
            test.eq(status(empty, ctx), "No messages with Anna yet. Ctrl+Enter sends.")
        end)

        test.it("Send and Ctrl+Enter send the input and empty it; plain Enter is the editor's new line", function()
            local sys = stand_in()
            local ctx = window()
            local model = aicq.talk_init(sys, ARGS, ctx)
            test.is_true(node(aicq.talk_view(model, ctx), T.send).disabled, "nothing typed: Send is off")
            test.is_true(node(aicq.talk_view(model, ctx), T.send).default, "Send is the default button")
            type_in(ctx, model, "  See you at noon  ")
            test.is_false(node(aicq.talk_view(model, ctx), T.send).disabled, "typed: Send is on")
            aicq.talk_update(model, {type = "activate", id = T.send}, ctx)
            test.eq(sys.calls.sent[1], "u-anna|See you at noon", "the text is trimmed")
            test.eq(editor.text(ctx.editor(T.draft)), "", "the input empties")
            test.is_true(node(aicq.talk_view(model, ctx), T.send).disabled)
            test.eq(#sys.calls.history, 2, "the history is read anew")
            local lines = aicq.talk_lines(model, 40)
            test.eq(lines[#lines], "  See you at noon")
            type_in(ctx, model, "one")
            aicq.talk_update(model, {type = "key", key_type = "enter", ctrl = true}, ctx)
            test.eq(sys.calls.sent[2], "u-anna|one", "Ctrl+Enter as a terminal with modifiers reports it")
            type_in(ctx, model, "two")
            aicq.talk_update(model, {type = "key", key_type = "runes", key = "j", ctrl = true}, ctx)
            test.eq(sys.calls.sent[3], "u-anna|two", "Ctrl+Enter as the line feed a plain terminal sends: Ctrl+J")
            type_in(ctx, model, "three")
            aicq.talk_update(model, {type = "key", key_type = "enter"}, ctx)
            aicq.talk_update(model, {type = "key", key_type = "runes", key = "k", ctrl = true}, ctx)
            aicq.talk_update(model, {type = "key", key_type = "runes", key = "j"}, ctx)
            test.eq(#sys.calls.sent, 3, "neither plain Enter, nor Ctrl+K, nor a j sends")
            type_in(ctx, model, "   \n  ")
            aicq.talk_update(model, {type = "activate", id = T.send}, ctx)
            test.eq(#sys.calls.sent, 3, "blank input is not sent")
            -- The SDK's side of it: a focused editor takes Enter as a new line
            -- and leaves both shapes of Ctrl+Enter alone, so the loop hands
            -- them to the window as keys.
            local state = ctx.interaction
            local plan = ui.plan(aicq.talk_view(model, ctx), 58, 20, state)
            state.focus = T.draft
            local plain = ui.event(plan, state, {type = "key", action = "press", key_type = "enter", key = "enter"})
            test.eq(plain and plain.type, "change", "Enter types a new line")
            test.is_nil(ui.event(plan, state, {type = "key", action = "press", key_type = "enter", key = "enter", ctrl = true}))
            test.is_nil(ui.event(plan, state, {type = "key", action = "press", key_type = "runes", key = "j", ctrl = true}))
        end)

        test.it("a refused send keeps the text and names the reason; a messenger not reached is not a refusal", function()
            local sys = stand_in({send_error = "denied"})
            local ctx = window()
            local model = aicq.talk_init(sys, ARGS, ctx)
            type_in(ctx, model, "hello")
            aicq.talk_update(model, {type = "activate", id = T.send}, ctx)
            test.eq(editor.text(ctx.editor(T.draft)), "hello", "the text stays to be sent again")
            test.eq(status(model, ctx), "not sent: denied")
            test.is_true(alert(model, ctx), "in red")
            sys.given.send_error = nil
            sys.given.send_notice = "the messenger is not running"
            aicq.talk_update(model, {type = "key", key_type = "enter", ctrl = true}, ctx)
            test.eq(#sys.calls.sent, 2)
            test.eq(editor.text(ctx.editor(T.draft)), "", "stored: the input empties, nothing to send twice")
            test.eq(status(model, ctx), "sent, but the messenger was not reached: the messenger is not running")
            test.is_false(alert(model, ctx), "said, not in red")
            sys.given.send_notice = nil
            type_in(ctx, model, "again")
            aicq.talk_update(model, {type = "activate", id = T.send}, ctx)
            test.eq(status(model, ctx), "Ctrl+Enter sends.", "a send that reached the messenger clears it")
        end)

        test.it("a message between the two arriving reloads and marks it read; any other is not this window's; a tick and closing", function()
            local sys = stand_in()
            local ctx = window()
            local model = aicq.talk_init(sys, ARGS, ctx)
            sys.rows[#sys.rows + 1] = {id = "m3", from_id = "u-anna", to_id = "u-me", body = "Lunch?", at = "2026-09-15T10:40:00Z"}
            sys.unread = 1
            test.is_true(aicq.talk_ping(model, {from_id = "u-anna", to_id = "u-me", message_id = "m3"}))
            test.eq(#sys.calls.history, 2, "the history is read anew")
            test.eq(#sys.calls.marked, 2, "and marked read: it is on screen")
            test.eq(table.concat(sys.calls.seen, ","), LIST, "the list hears of it")
            local lines = aicq.talk_lines(model, 40)
            test.eq(lines[#lines], "  Lunch?")
            test.is_true(aicq.talk_ping(model, {from_id = "u-me", to_id = "u-anna", message_id = "m4"}),
                "one's own message from another desktop shows here too")
            test.eq(#sys.calls.history, 3)
            test.is_false(aicq.talk_ping(model, {from_id = "u-boris", to_id = "u-me", message_id = "m5"}), "another person's")
            test.is_false(aicq.talk_ping(model, "junk"))
            test.eq(#sys.calls.history, 3, "reloads nothing")
            aicq.talk_update(model, {type = "tick"}, ctx)
            test.eq(#sys.calls.history .. "/" .. #sys.calls.watched, "4/2", "a tick reads anew and watches again")
            aicq.talk_update(model, {type = "key", key_type = "f5"}, ctx)
            test.eq(#sys.calls.history, 5, "so does F5")
            aicq.talk_update(model, {type = "activate", id = T.close}, ctx)
            test.is_true(ctx.closing, "Close closes the window")
            aicq.talk_dispose(model)
            test.eq(table.concat(sys.calls.unwatched, ","), "u-me", "closing stops the messenger's pings")
        end)

        test.it("names what failed: no person, no actor, a history not read (nothing is marked), a mark or a watch refused", function()
            local ctx = window()
            local nobody = stand_in()
            local lost = aicq.talk_init(nobody, "", ctx)
            test.eq(status(lost, ctx), "no person named: open the message window from the contact list")
            test.eq(#nobody.calls.history + #nobody.calls.watched, 0)
            local anonymous = aicq.talk_init(stand_in({me_error = "no actor"}), ARGS, ctx)
            test.eq(status(anonymous, ctx), "who you are was not read: no actor")
            local tree = aicq.talk_view(anonymous, ctx)
            test.is_true(node(tree, T.send).disabled and node(tree, T.draft).read_only, "nothing to send as")
            test.is_false(aicq.talk_ping(anonymous, {from_id = "u-anna"}), "nor a history to reload")
            local denied = stand_in({history_error = "denied", unread = 2})
            local closed = aicq.talk_init(denied, ARGS, ctx)
            test.eq(status(closed, ctx), "history not read: denied")
            test.eq(#denied.calls.marked, 0, "a history not shown is not marked read")
            test.is_true(alert(closed, ctx))
            local busy = aicq.talk_init(stand_in({mark_error = "busy"}), ARGS, ctx)
            test.eq(status(busy, ctx), "not marked read: busy")
            local deaf = stand_in({watch_error = "the messenger is not running"})
            local slow = aicq.talk_init(deaf, ARGS, ctx)
            test.eq(status(slow, ctx), "not live, reloads each minute: the messenger is not running")
            deaf.given.watch_error = nil
            aicq.talk_update(slow, {type = "tick"}, ctx)
            test.eq(status(slow, ctx), "Ctrl+Enter sends.", "until a tick's watch is heard")
        end)

        test.it("Add to List stands next to Send only while the person is not a contact; adding hides it and tells the list", function()
            local ctx = window()
            local friend = aicq.talk_init(stand_in(), ARGS, ctx)
            test.is_nil(node(aicq.talk_view(friend, ctx), T.add), "a contact: no button")
            local sys = stand_in({listed = false})
            local model = aicq.talk_init(sys, ARGS, ctx)
            local tree = aicq.talk_view(model, ctx)
            test.eq(node(tree, T.add) and node(tree, T.add).text, "Add to List")
            local plan = ui.plan(tree, 58, 20, ctx.interaction)
            test.eq(clash(plan, 58, 20), "none")
            local add, send, close = plan.by_id[T.add].rect, plan.by_id[T.send].rect, plan.by_id[T.close].rect
            test.is_true(add.x + add.w <= send.x and send.x + send.w <= close.x, "Add to List, Send, Close")
            aicq.talk_update(model, {type = "activate", id = T.add}, ctx)
            test.eq(table.concat(sys.calls.added, ","), "u-anna")
            test.eq(table.concat(sys.calls.told, ","), LIST .. "|u-anna", "the list hears of it")
            test.is_nil(node(aicq.talk_view(model, ctx), T.add), "the button is gone")
            test.eq(status(model, ctx), "Anna is in your contacts now.")
            test.is_false(alert(model, ctx))
            local stubborn = stand_in({listed = false, add_error = "the directory does not know them"})
            local refused = aicq.talk_init(stubborn, ARGS, ctx)
            aicq.talk_update(refused, {type = "activate", id = T.add}, ctx)
            test.eq(status(refused, ctx), "not added: the directory does not know them")
            test.not_nil(node(aicq.talk_view(refused, ctx), T.add), "the button stays")
            test.eq(#stubborn.calls.told, 0)
            local blind = aicq.talk_init(stand_in({listed_error = "presence down"}), ARGS, ctx)
            test.is_nil(node(aicq.talk_view(blind, ctx), T.add), "not known: no button rather than a wrong one")
            local elsewhere = stand_in({listed = false})
            local later = aicq.talk_init(elsewhere, ARGS, ctx)
            elsewhere.contact = true
            aicq.talk_update(later, {type = "tick"}, ctx)
            test.is_nil(node(aicq.talk_view(later, ctx), T.add), "added from the list meanwhile: a tick hides it")
            local orphan = stand_in({listed = false})
            local alone = aicq.talk_init(orphan, "u-anna\nAnna", ctx)
            aicq.talk_update(alone, {type = "activate", id = T.add}, ctx)
            test.eq(#orphan.calls.added .. "/" .. #orphan.calls.told, "1/0", "no list opened it: added, nobody told")
        end)

        test.it("lays the window out: history above, the input, Send and Close at the right, the status row; nothing overlaps", function()
            local ctx = window(58, 20)
            local model = aicq.talk_init(stand_in(), ARGS, ctx)
            local plan = ui.plan(aicq.talk_view(model, ctx), 58, 20, ctx.interaction)
            test.eq(clash(plan, 58, 20), "none")
            local log, draft = plan.by_id[T.log].rect, plan.by_id[T.draft].rect
            local send, close = plan.by_id[T.send].rect, plan.by_id[T.close].rect
            test.is_true(log.y < draft.y and draft.y < send.y, "history, input, buttons from the top")
            test.eq(draft.h, 5)
            test.is_true(send.x + send.w <= close.x and close.x + close.w == 59, "Send, then Close at the right edge")
            local small = window(30, 12)
            local tight = ui.plan(aicq.talk_view(model, small), 30, 12, small.interaction)
            test.eq(clash(tight, 30, 12), "none", "at a small size too")
            test.is_true(tight.by_id[T.log].rect.h >= 3, "the history keeps rows")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
