-- The aICQ contact list: People and Agents, apart, as ICQ 2000 kept its groups.
--
-- All the logic is in `windows.aicq:aicq`; here are only the window's reads, handed
-- over as `sys`. Agents come from the same library as the master agent's
-- (`roster_list`), people from `windows.aicq:people`, both under the logged-on
-- person's actor: the list shows what the web interface shows. Enter, a second
-- click on the selected row or a double click opens a person's message window
-- or an agent's dialog; the right click opens the menu.
--
-- While open, the list reloads every minute and tells the presence service
-- its count of agents, watches its person at the messenger, and reloads the
-- unread counts when a message arrives or a message window has shown some.

local app = require("app")
local process = require("process")
local desktop = require("desktop")
local roster = require("roster")
local registry = require("registry")
local component = require("component")
local agents = require("agents")
local people = require("people")
local aicq = require("aicq")

-- The "Add Agent…" window (`windows.aicq:agents` and `windows.aicq:new_agent`).
local NEW_AGENT = "windows.aicq:new_agent"

-- The topics the list listens to: a new agent, the messenger's ping, a message
-- window that has shown someone's messages, Add Contact's news.
local TOPICS = {agents.ADDED, aicq.NEW, aicq.SEEN, aicq.CONTACT_ADDED}

-- messenger(topic) — watch or unwatch the logged-on person at the messenger.
local function messenger(topic: string): (any, any)
    local me, err = people.me()
    if not me then return nil, tostring(err or "who you are was not read") end
    local pid = process.registry.lookup(aicq.MESSENGER)
    if not pid then return nil, "the messenger is not running" end
    local sent, serr = process.send(pid, topic, {user_id = tostring(me.id)})
    return sent, serr
end

local sys = {}

function sys.roster(): (any, any)
    local list, truncated = roster.reachable(nil, "")
    return list, truncated
end

function sys.contacts(): (any, any)
    local list, err = people.contacts()
    return list, err
end

function sys.open(agent: any): (any, any)
    -- The dialog's caption is made only here: "<agent> - aICQ". The dialog
    -- does not publish its own, so it holds in cells too.
    local ok, err = desktop.open({
        entry = aicq.DIALOG,
        title = tostring(agent.title) .. " - aICQ",
        args = tostring(agent.agent_id) .. "\n" .. tostring(agent.title),
    })
    return ok, err
end

-- The message window: the person, and this list's pid to tell when it has
-- shown their messages.
function sys.message(person: any): (any, any)
    local ok, err = desktop.open({
        entry = aicq.MESSAGE,
        title = tostring(person.name) .. " - aICQ",
        args = tostring(person.id) .. "\n" .. tostring(person.name) .. "\n" .. tostring(process.pid()),
    })
    return ok, err
end

-- "Add Agent…" and "Add Contact…" report success to this process: its pid
-- travels in their arguments.
function sys.add(): (any, any)
    local ok, err = desktop.open({entry = NEW_AGENT, args = tostring(process.pid())})
    return ok, err
end

function sys.add_contact(): (any, any)
    local ok, err = desktop.open({entry = aicq.ADD_CONTACT_WINDOW, args = tostring(process.pid())})
    return ok, err
end

function sys.add_person(user_id: any): (any, any)
    local done, err = people.add(user_id)
    return done, err
end

function sys.remove(user_id: any): (any, any)
    local done, err = people.remove(user_id)
    return done, err
end

-- Remove from List: off Not in List until they write again.
function sys.dismiss(user_id: any): (any, any)
    local done, err = people.dismiss(user_id)
    return done, err
end

-- What the Info sheet shows. A system agent — its registry entry; a user's
-- agent — the component's context, read with the logged-on person's rights.
function sys.describe(agent: any): (any, any)
    local id = tostring(agent.agent_id)
    local prefix = roster.USER_AGENT_PREFIX
    if id:sub(1, #prefix) == prefix then
        local component_id = id:sub(#prefix + 1)
        local context, err = component.get_context(component_id, component.ACCESS.READ)
        if not context then return nil, tostring(err or "the component's context was not read") end
        return {kind = "user agent, component " .. component_id, fields = context}, nil
    end
    local entry, err = registry.get(id)
    if not entry then return nil, tostring(err or "not in the registry") end
    local fields: any = type(entry.data) == "table" and entry.data or entry
    return {kind = "system agent, registry entry", fields = fields}, nil
end

-- Whether a dialog with the agent is open: the dialog carries the agent's id
-- as the first line of its arguments, and the compositor gives them in
-- `desktop.list`.
function sys.dialog_open(agent: any): (any, any)
    local answer, err = desktop.list()
    if not answer then return nil, tostring(err or "the desktop did not answer") end
    local prefix = tostring(agent.agent_id) .. "\n"
    for _, window in ipairs(type(answer.windows) == "table" and answer.windows or {}) do
        if window.entry == aicq.DIALOG and tostring(window.args or ""):sub(1, #prefix) == prefix then
            return true, nil
        end
    end
    return false, nil
end

-- The list's count goes to the presence service. The service not running is
-- not the window's error: the tray simply stays on the service's own reading.
function sys.report(counts: any): (any, any)
    local pid = process.registry.lookup(aicq.SERVICE)
    if not pid then return nil, "the presence service is not running" end
    local sent, err = process.send(pid, aicq.REPORT, counts)
    return sent, err
end

function sys.watch(): (any, any)
    local sent, err = messenger(aicq.WATCH)
    return sent, err
end

function sys.unwatch(): (any, any)
    local sent, err = messenger(aicq.UNWATCH)
    return sent, err
end

local definition = {}

-- The roster anew once per service tick: the report does not age while the
-- list is open.
definition.interval = tostring(aicq.TICK_S) .. "s"

function definition.init(args: any, context: any): any
    for _, topic in ipairs(TOPICS) do
        local heard = process.listen(topic, {message = true})
        if heard then context.watch(heard) end
    end
    local model = aicq.init(sys)
    return model
end

function definition.view(model: any, context: any): any
    local tree = aicq.view(model)
    return tree
end

function definition.update(model: any, action: any, context: any): boolean
    if action.type == "channel" then
        if not action.ok or action.value == nil then return false end
        local body: any = {}
        local ok, payload = pcall(action.value.payload, action.value)
        if ok then body = aicq.unwrap(payload) end
        local named, topic = pcall(action.value.topic, action.value)
        if not named then return false end
        if topic == agents.ADDED then
            local added = aicq.added(model, body.agent_id)
            return added
        end
        if topic == aicq.NEW then
            local pinged = aicq.pinged(model)
            return pinged
        end
        local changed = aicq.hear(model, topic, body)
        return changed
    end
    local changed = aicq.update(model, action, context)
    return changed
end

-- Closing, the list tells the service to stop believing its report, and the
-- messenger to stop pinging it.
function definition.dispose(model: any, context: any)
    aicq.dispose(model)
end

-- While a sheet is up, the window's caption is the sheet's.
function definition.title(model: any): any
    local title = aicq.title(model)
    return title
end

local function main(first: any, id: any, args: any, viewport: any)
    app.run(definition, first, id, args, viewport)
end

return {main = main, definition = definition}
