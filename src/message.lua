-- The aICQ message window: a conversation with one person.
--
-- The history above (sender, time, text), the input below, Send (the
-- default; Ctrl+Enter) and Close. All the logic is in `windows.aicq:aicq`
-- (`talk_*`); here are only the window's reads, handed over as `sys`: the
-- people library under the logged-on person's actor (who sends and who reads
-- is that actor, never a field of a message — docs/aicq-people.md §2) and the
-- messenger's pings.
--
-- The argument is "<user_id>\n<name>\n<pid of the contact list>": the list
-- opens the window with the person's name, and hears from it when it has
-- shown their messages. The caption "<name> - aICQ" is the list's too.

local app = require("app")
local process = require("process")
local people = require("people")
local aicq = require("aicq")

-- messenger(topic, user_id) — watch or unwatch the window's own person: the
-- messenger pings the watchers of either end of a message.
local function messenger(topic: string, user_id: any): (any, any)
    local pid = process.registry.lookup(aicq.MESSENGER)
    if not pid then return nil, "the messenger is not running" end
    local sent, err = process.send(pid, topic, {user_id = tostring(user_id)})
    return sent, err
end

local sys = {}

function sys.me(): (any, any)
    local me, err = people.me()
    return me, err
end

function sys.history(user_id: any, limit: any): (any, any)
    local list, err = people.history(user_id, limit)
    return list, err
end

-- The third value: the row is stored, the messenger was not reached.
function sys.send(to_id: any, text: any): (any, any, any)
    local id, err, notice = people.send(to_id, text)
    return id, err, notice
end

function sys.mark_read(user_id: any): (any, any)
    local count, err = people.mark_read(user_id)
    return count, err
end

function sys.watch(user_id: any): (any, any)
    local sent, err = messenger(aicq.WATCH, user_id)
    return sent, err
end

function sys.unwatch(user_id: any): (any, any)
    local sent, err = messenger(aicq.UNWATCH, user_id)
    return sent, err
end

-- The contact list that opened the window reloads its unread counts.
function sys.seen(opener: any): (any, any)
    local sent, err = process.send(tostring(opener), aicq.SEEN, {})
    return sent, err
end

-- Whether the person is a contact: a row of contacts() with `listed` not
-- false. Not there at all is not a contact either.
function sys.listed(user_id: any): (any, any)
    local list, err = people.contacts()
    if not list then return nil, err end
    for _, row in ipairs(list) do
        if tostring(row.id) == tostring(user_id) then return row.listed ~= false, nil end
    end
    return false, nil
end

-- Add to List, and the news to the contact list that opened the window.
function sys.add(user_id: any): (any, any)
    local done, err = people.add(user_id)
    return done, err
end

function sys.added(opener: any, user_id: any): (any, any)
    local sent, err = process.send(tostring(opener), aicq.CONTACT_ADDED, {user_id = user_id})
    return sent, err
end

local definition = {}

-- The fallback of a messenger that does not ping: the history once a minute.
definition.interval = tostring(aicq.TICK_S) .. "s"
definition.close_on_escape = true

function definition.init(args: any, context: any): any
    local pings = process.listen(aicq.NEW, {message = true})
    if pings then context.watch(pings) end
    local model = aicq.talk_init(sys, args, context)
    return model
end

function definition.view(model: any, context: any): any
    local tree = aicq.talk_view(model, context)
    return tree
end

function definition.update(model: any, action: any, context: any): boolean
    if action.type == "channel" then
        if not action.ok or action.value == nil then return false end
        local body: any = {}
        local ok, payload = pcall(action.value.payload, action.value)
        if ok then body = aicq.unwrap(payload) end
        local changed = aicq.talk_ping(model, body)
        return changed
    end
    local changed = aicq.talk_update(model, action, context)
    return changed
end

function definition.dispose(model: any, context: any)
    aicq.talk_dispose(model)
end

function definition.title(model: any): any
    local title = aicq.talk_title(model)
    return title
end

local function main(first: any, id: any, args: any, viewport: any)
    app.run(definition, first, id, args, viewport)
end

return {main = main, definition = definition}
