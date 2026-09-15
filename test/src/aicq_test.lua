-- aICQ's contact list: People and Agents apart with their online/total
-- counters, online rows first, the unread envelope, collapsing, the tray
-- items, the context menus, the Info sheets, Remove Contact, Add Agent… and
-- Add Contact…, the messenger's pings and the layout — all through the model
-- `windows.aicq:aicq` with a stand-in for the window's `sys`, without the roster,
-- the people library, the registry or the compositor.
local test = require("test")
local ui = require("ui")
local aicq = require("aicq")

local WRITER = {agent_id = "app.agents:writer", title = "Writer", description = "Writes the drafts"}
local ANALYST = {agent_id = "user_agent:01abc", title = "Analyst", description = ""}
local SCOUT = {agent_id = "app.agents:scout", title = "Scout", description = "Finds topics"}
-- Unreachable, and first by name: it must still come after the online ones.
local ARCHIVE = {agent_id = "app.agents:archive", title = "Archive", description = "", reachable = false}

local function roster(): any
    return {WRITER, ANALYST, SCOUT}
end

-- Contacts as `windows.aicq:people.contacts` answers them. `boris` is in lower
-- case (names sort without regard to case); Alice is offline and first by
-- name (online rows still come first).
local function people(): any
    return {
        {id = "u-anna", name = "Anna", uin = "123456789", online = true, desktops = 2, unread = 2, listed = true},
        {id = "u-boris", name = "boris", uin = "234567890", online = true, desktops = 1, unread = 0, listed = true},
        {id = "u-alice", name = "Alice", uin = "345678901", online = false, desktops = 0, unread = 0, listed = true},
    }
end

-- The window's reads stood in; what the window asked for piles up in `calls`.
-- `over.people` is what `contacts()` answers, kept by reference so a case can
-- change it between loads.
local function stand_in(agents: any, over: any?): any
    local given: any = over or {}
    local sys: any = {given = given, calls = {opened = {}, messages = {}, adds = 0, contact_adds = 0, reports = {},
        removed = {}, listed = {}, dismissed = {}, watches = 0, unwatches = 0}}
    function sys.report(counts: any): (any, any)
        sys.calls.reports[#sys.calls.reports + 1] = counts
        return true, nil
    end
    function sys.roster(): (any, any)
        if given.roster_error then error(given.roster_error) end
        return agents, false
    end
    function sys.contacts(): (any, any)
        if given.contacts_error then return nil, given.contacts_error end
        return given.people or {}, nil
    end
    function sys.open(agent: any): (any, any)
        sys.calls.opened[#sys.calls.opened + 1] = agent.agent_id
        if given.open_error then return nil, given.open_error end
        return true, nil
    end
    function sys.message(person: any): (any, any)
        sys.calls.messages[#sys.calls.messages + 1] = tostring(person.id) .. "|" .. tostring(person.name)
        if given.open_error then return nil, given.open_error end
        return true, nil
    end
    function sys.add(): (any, any)
        sys.calls.adds = sys.calls.adds + 1
        if given.add_error then return nil, given.add_error end
        return true, nil
    end
    function sys.add_contact(): (any, any)
        sys.calls.contact_adds = sys.calls.contact_adds + 1
        if given.add_error then return nil, given.add_error end
        return true, nil
    end
    function sys.remove(user_id: any): (any, any)
        sys.calls.removed[#sys.calls.removed + 1] = user_id
        if given.remove_error then return nil, given.remove_error end
        local kept: any = {}
        for _, person in ipairs(given.people or {}) do
            if person.id ~= user_id then kept[#kept + 1] = person end
        end
        given.people = kept
        return true, nil
    end
    function sys.add_person(user_id: any): (any, any)
        sys.calls.listed[#sys.calls.listed + 1] = user_id
        for _, person in ipairs(given.people or {}) do
            if person.id == user_id then person.listed = true end
        end
        return true, nil
    end
    function sys.dismiss(user_id: any): (any, any)
        sys.calls.dismissed[#sys.calls.dismissed + 1] = user_id
        if given.dismiss_error then return nil, given.dismiss_error end
        local kept: any = {}
        for _, person in ipairs(given.people or {}) do
            if person.id ~= user_id then kept[#kept + 1] = person end
        end
        given.people = kept
        return true, nil
    end
    function sys.describe(agent: any): (any, any)
        if given.describe_raises then error(given.describe_raises) end
        if given.describe_error then return nil, given.describe_error end
        return {kind = "system agent, registry entry", fields = {model = "class:premium",
            traits = {"app.traits:web", {id = "app.traits:memory"}}, tools = {}}}, nil
    end
    function sys.dialog_open(agent: any): (any, any)
        if given.list_error then return nil, given.list_error end
        return agent.agent_id == "app.agents:writer", nil
    end
    function sys.watch(): (any, any)
        sys.calls.watches = sys.calls.watches + 1
        if given.watch_error then return nil, given.watch_error end
        return true, nil
    end
    function sys.unwatch(): (any, any)
        sys.calls.unwatches = sys.calls.unwatches + 1
        return true, nil
    end
    return sys
end

-- A window stand-in: closing is counted in a table, not in a local.
local function window(): any
    local ctx: any = {closed = {count = 0}}
    function ctx.close() ctx.closed.count = ctx.closed.count + 1 end
    return ctx
end

local function labels(model: any): string
    local out = {}
    for _, line in ipairs(aicq.rows(model)) do out[#out + 1] = string.rep("  ", line.depth) .. line.label end
    return table.concat(out, "|")
end

local function row(model: any, id: string): any
    for _, line in ipairs(aicq.rows(model)) do
        if line.id == id then return line end
    end
    return nil
end

-- The first child of this view's root of a kind: the status row, the menu,
-- the row of buttons.
local function child(model: any, kind: string): any
    for _, node in ipairs(aicq.view(model).children or {}) do
        if node.kind == kind then return node end
    end
    return nil
end

local function status(model: any): string
    local label = child(model, "label")
    return tostring(label and label.text)
end

local function menu_ids(model: any): string
    local menu = child(model, "menu")
    if not menu then return "no menu" end
    local out = {}
    for _, item in ipairs(menu.items) do out[#out + 1] = item.separator and "-" or tostring(item.id) end
    return table.concat(out, "|")
end

local function menu_texts(model: any): string
    local menu = child(model, "menu")
    if not menu then return "no menu" end
    local out = {}
    for _, item in ipairs(menu.items) do
        if not item.separator then out[#out + 1] = tostring(item.text) end
    end
    return table.concat(out, "|")
end

local function right_click(model: any, id: string, x: integer, y: integer, ctx: any)
    aicq.update(model, {type = "context", id = aicq.TREE, index = 1, value = row(model, id), x = x, y = y}, ctx)
end

local function choose(model: any, item: string, ctx: any)
    aicq.update(model, {type = "activate", id = item, menu = aicq.MENU}, ctx)
end

local function info_of(model: any, id: string, ctx: any): any
    right_click(model, id, 4, 4, ctx)
    choose(model, "info", ctx)
    return model.sheet
end

-- The components a plan laid out, by the kinds this window has.
local LEAVES: any = {tree = true, button = true, label = true}

-- The first pair of laid out components that overlap or leave the client,
-- "none" when they all stand apart inside it.
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
    test.describe("aICQ contact list", function()
        test.it("keeps people and agents apart: People and Agents with online/total, online first, then by name", function()
            local model = aicq.init(stand_in(roster(), {people = people()}))
            test.eq(labels(model), "People (2/3)|  Anna (2)|  boris|  Alice|Agents (3/3)|  Analyst|  Scout|  Writer")
            test.eq(row(model, "group:people").image, aicq.ONLINE_IMAGE, "People is headed by the flower")
            test.eq(row(model, "group:agents").image, aicq.AGENT_IMAGE, "Agents by the agent")
            test.eq(row(model, "person:u-anna").image, aicq.MESSAGE_IMAGE, "unread: the envelope instead of the flower")
            test.eq(row(model, "person:u-boris").image, aicq.ONLINE_IMAGE, "online: the green flower")
            test.eq(row(model, "person:u-alice").image, aicq.OFFLINE_IMAGE, "offline: the grey one")
            test.eq(row(model, "agent:app.agents:writer").image, aicq.AGENT_IMAGE)
            test.eq(row(model, "person:u-boris").person .. "|" .. row(model, "person:u-boris").group, "u-boris|people",
                "a row carries the id, not the table")
            test.eq(row(model, "agent:app.agents:scout").depth, 1)
            test.eq(model.selected, "person:u-anna", "the first member is selected")
            test.eq(status(model), "2 people online, 3 agents")
            test.is_nil(ui.problem(aicq.view(model)))
            local grouped = aicq.arrange({{title = "no id"}, {agent_id = "a:x", title = "X"}},
                {{name = "no id"}, "text", {id = ""}, {id = "u-x", online = "yes"}})
            test.eq(#grouped.people .. "/" .. #grouped.agents, "1/1", "rows without an id are skipped")
            test.eq(grouped.people[1].kind .. "|" .. grouped.agents[1].kind, "person|agent", "and the two never mix")
            test.is_false(grouped.people[1].online, "only true is online")
            test.eq(grouped.people[1].name, "u-x", "a person without a name shows the id")
        end)

        test.it("an agent the roster calls unreachable comes after the online ones, with the grey agent picture", function()
            local model = aicq.init(stand_in({WRITER, ARCHIVE, SCOUT}))
            test.eq(labels(model), "People (0/0)|Agents (2/3)|  Scout|  Writer|  Archive")
            test.is_false(row(model, "group:people").expanded, "the empty People starts collapsed")
            test.eq(row(model, "agent:app.agents:archive").image, aicq.AGENT_OFF_IMAGE)
            test.eq(status(model), "0 people online, 2 agents")
            local grouped = aicq.groups({WRITER, ARCHIVE, SCOUT})
            test.eq(#grouped.online .. "/" .. #grouped.offline, "2/1", "the service's grouping of the roster")
            test.eq(#aicq.groups({{title = "no id"}, "text", {agent_id = ""}}).online, 0, "rows without an id are skipped")
        end)

        test.it("names what was not read and still shows the rest", function()
            local model = aicq.init(stand_in(roster(), {contacts_error = "no actor"}))
            test.eq(labels(model), "People (0/0)|Agents (3/3)|  Analyst|  Scout|  Writer", "the agents stay")
            test.eq(status(model), "contacts not read: no actor")
            local blind = aicq.init(stand_in(roster(), {people = people(), roster_error = "boom"}))
            test.eq(labels(blind), "People (2/3)|  Anna (2)|  boris|  Alice|Agents (0/0)", "the people stay")
            test.not_nil(status(blind):find("roster not read: ", 1, true), status(blind))
            local neither = aicq.init(stand_in(roster(), {roster_error = "boom", contacts_error = "no actor"}))
            test.not_nil(status(neither):find("; contacts not read: no actor", 1, true), status(neither))
            test.eq(labels(neither), "People (0/0)|Agents (0/0)")
            local unknown: any = {{id = "u-anna", name = "Anna", unread = 2}, {id = "u-boris", name = "boris"},
                {id = "u-alice", name = "Alice"}}
            unknown.why = "the presence service did not answer"
            local dim = aicq.init(stand_in(roster(), {people = unknown}))
            test.eq(labels(dim), "People (0/3)|  Alice|  Anna (2)|  boris|Agents (3/3)|  Analyst|  Scout|  Writer",
                "presence not read: nobody shown online")
            test.eq(status(dim), "who is online is not known: the presence service did not answer", "and the status says why")
        end)

        test.it("collapses and expands a group by its toggle and by a second click on its header; F5 keeps it", function()
            local model = aicq.init(stand_in(roster()))
            local ctx = window()
            aicq.update(model, {type = "toggle", id = aicq.TREE, value = row(model, "group:agents")}, ctx)
            test.eq(labels(model), "People (0/0)|Agents (3/3)")
            aicq.update(model, {type = "toggle", id = aicq.TREE, value = row(model, "group:people")}, ctx)
            test.is_true(row(model, "group:people").expanded, "an empty group opens too, showing nothing")
            aicq.update(model, {type = "toggle", id = aicq.TREE, value = row(model, "group:agents")}, ctx)
            test.eq(labels(model), "People (0/0)|Agents (3/3)|  Analyst|  Scout|  Writer")
            local header = row(model, "group:agents")
            aicq.update(model, {type = "select", id = aicq.TREE, value = header, pointer = true}, ctx)
            test.eq(model.selected, "group:agents")
            test.eq(labels(model), "People (0/0)|Agents (3/3)|  Analyst|  Scout|  Writer", "the first click selects")
            aicq.update(model, {type = "select", id = aicq.TREE, value = header, pointer = true}, ctx)
            test.eq(labels(model), "People (0/0)|Agents (3/3)", "the second click on the header collapses it")
            aicq.update(model, {type = "activate", id = aicq.TREE}, ctx)
            test.eq(labels(model), "People (0/0)|Agents (3/3)|  Analyst|  Scout|  Writer", "Enter on a header toggles it")
            aicq.update(model, {type = "toggle", id = aicq.TREE, value = header}, ctx)
            aicq.update(model, {type = "key", key_type = "f5"}, ctx)
            test.eq(labels(model), "People (0/0)|Agents (3/3)", "F5 keeps what the person collapsed")
        end)

        test.it("opens a person's message window or an agent's dialog by a double click and by Enter; a refusal is the status row's", function()
            local sys = stand_in(roster(), {people = people()})
            local model = aicq.init(sys)
            local ctx = window()
            local scout = row(model, "agent:app.agents:scout")
            aicq.update(model, {type = "select", id = aicq.TREE, value = scout, pointer = true}, ctx)
            test.eq(#sys.calls.opened, 0, "the first click selects")
            aicq.update(model, {type = "select", id = aicq.TREE, value = scout, pointer = true}, ctx)
            test.eq(sys.calls.opened[1], "app.agents:scout", "the second opens")
            aicq.update(model, {type = "select", id = aicq.TREE, value = scout}, ctx)
            test.eq(#sys.calls.opened, 1, "a key re-selecting the row does not open")
            aicq.update(model, {type = "activate", id = aicq.TREE}, ctx)
            test.eq(sys.calls.opened[2], "app.agents:scout", "Enter opens the selected agent")
            aicq.update(model, {type = "key", key_type = "f5"}, ctx)
            test.eq(model.selected, "agent:app.agents:scout", "F5 keeps the selected member, not the first one")
            local anna = row(model, "person:u-anna")
            aicq.update(model, {type = "select", id = aicq.TREE, value = anna, pointer = true}, ctx)
            aicq.update(model, {type = "select", id = aicq.TREE, value = anna, pointer = true}, ctx)
            test.eq(table.concat(sys.calls.messages, ","), "u-anna|Anna", "a person's double click opens the message window")
            test.eq(#sys.calls.opened, 2, "and not an agent dialog")
            aicq.update(model, {type = "activate", id = aicq.TREE}, ctx)
            test.eq(sys.calls.messages[2], "u-anna|Anna", "Enter on a person opens it too")
            local refused = aicq.init(stand_in(roster(), {open_error = "no desktop"}))
            aicq.update(refused, {type = "activate", id = aicq.TREE}, ctx)
            test.eq(status(refused), "did not open: no desktop")
            aicq.update(model, {type = "key", key_type = "esc"}, ctx)
            test.eq(ctx.closed.count, 1, "Esc on the list closes the window")
        end)

        test.it("right click: a person has Send Message / Info… / Remove Contact, an agent Open / Info… / Add Agent…, a header its own Add", function()
            local sys = stand_in(roster(), {people = people()})
            local model = aicq.init(sys)
            local ctx = window()
            right_click(model, "group:people", 3, 1, ctx)
            test.eq(menu_ids(model), "add_contact", "People's header: Add Contact… alone")
            test.eq(menu_texts(model), "Add Contact…")
            test.eq(model.selected, "person:u-anna", "and the selection stays")
            aicq.update(model, {type = "dismiss", id = aicq.MENU}, ctx)
            right_click(model, "group:agents", 3, 5, ctx)
            test.eq(menu_ids(model), "add", "Agents' header: Add Agent… alone")
            aicq.update(model, {type = "dismiss", id = aicq.MENU}, ctx)
            aicq.update(model, {type = "context", id = aicq.TREE, index = 0, x = 3, y = 11}, ctx)
            test.eq(menu_ids(model), "add_contact|add", "the empty field has both")
            aicq.update(model, {type = "dismiss", id = aicq.MENU}, ctx)
            test.eq(menu_ids(model), "no menu", "Esc or a press outside closes the menu")
            test.eq(ctx.closed.count, 0, "and not the window")
            right_click(model, "person:u-boris", 4, 3, ctx)
            test.eq(model.selected, "person:u-boris", "the right click selects the person")
            test.eq(menu_ids(model), "send|-|info|remove")
            test.eq(menu_texts(model), "Send Message|Info…|Remove Contact")
            choose(model, "send", ctx)
            test.eq(sys.calls.messages[1], "u-boris|boris", "Send Message opens the message window")
            test.eq(menu_ids(model), "no menu")
            -- Through a real plan: a right press on a tree row gives `context`.
            local state = ui.interaction()
            local plan = ui.plan(aicq.view(model), 34, 12, state)
            local rect = plan.by_id[aicq.TREE].rect
            local pressed = ui.event(plan, state, {type = "mouse", action = "press", button = "right", x = rect.x + 5, y = rect.y + 6})
            test.eq(pressed and pressed.type, "context")
            test.eq(pressed and pressed.value and pressed.value.id, "agent:app.agents:scout", "the seventh row is Scout")
            aicq.update(model, pressed, ctx)
            test.eq(model.selected, "agent:app.agents:scout", "the right click selects the agent")
            test.eq(menu_ids(model), "open|-|info|-|add")
            test.eq(menu_texts(model), "Open|Info…|Add Agent…")
            local menu = child(model, "menu")
            test.eq(menu.id, aicq.MENU)
            test.eq(tostring(menu.popup.x) .. "," .. tostring(menu.popup.y), tostring(rect.x + 5) .. "," .. tostring(rect.y + 6))
            test.is_nil(ui.problem(aicq.view(model)))
            choose(model, "open", ctx)
            test.eq(sys.calls.opened[1], "app.agents:scout", "Open opens the dialog")
            local wrote = people()
            wrote[#wrote + 1] = {id = "u-dora", name = "Dora", online = true, desktops = 1, unread = 1, listed = false,
                last_at = "2026-09-15T10:00:00Z"}
            local stranger = aicq.init(stand_in(roster(), {people = wrote}))
            right_click(stranger, "person:u-dora", 4, 5, ctx)
            test.eq(menu_ids(stranger), "add_person|send|info|-|dismiss", "Not in List: add them, write, look, or let them go")
            test.eq(menu_texts(stranger), "Add to Contacts|Send Message|Info…|Remove from List")
            aicq.update(stranger, {type = "dismiss", id = aicq.MENU}, ctx)
            right_click(stranger, "group:strangers", 3, 5, ctx)
            test.eq(menu_ids(stranger), "no menu", "Not in List's header has nothing to add")
        end)

        test.it("Info… shows an agent's entry with reasons for what was not read, and a person's UIN, status and desktops", function()
            local model = aicq.init(stand_in({WRITER, ANALYST, SCOUT, ARCHIVE}, {people = people()}))
            local ctx = window()
            local sheet = info_of(model, "agent:app.agents:writer", ctx)
            test.eq(sheet.title, "Writer - Info")
            test.eq(aicq.title(model), "Writer - Info", "the sheet's title is the window's")
            test.eq(sheet.image, aicq.AGENT_IMAGE)
            test.eq(table.concat(sheet.lines, "\n"), table.concat({
                "Name: Writer", "ID: app.agents:writer", "Description: Writes the drafts",
                "Status: reachable", "Kind: system agent, registry entry", "Model: class:premium",
                "Traits: app.traits:web, app.traits:memory", "Tools: none declared",
                "Dialog: open; its session's state is shown there"}, "\n"))
            test.is_nil(ui.problem(aicq.view(model)))
            aicq.update(model, {type = "activate", id = aicq.INFO_OK}, ctx)
            test.is_nil(model.sheet, "OK returns to the list")
            test.is_nil(aicq.title(model), "and the window's own title")
            sheet = info_of(model, "agent:app.agents:archive", ctx)
            test.eq(sheet.lines[4] .. "|" .. sheet.lines[#sheet.lines], "Status: not reachable|Dialog: not open")
            test.eq(sheet.image, aicq.AGENT_OFF_IMAGE)
            aicq.update(model, {type = "activate", id = aicq.INFO_OK}, ctx)
            sheet = info_of(model, "person:u-anna", ctx)
            test.eq(sheet.title, "Anna - Info")
            test.eq(table.concat(sheet.lines, "|"), "Name: Anna|UIN: 123456789|Status: online, on 2 desktops|Unread: 2 messages")
            test.eq(sheet.image, aicq.ONLINE_IMAGE)
            aicq.update(model, {type = "key", key_type = "esc"}, ctx)
            test.is_nil(model.sheet, "Esc returns to the list")
            test.eq(ctx.closed.count, 0, "without closing the window")
            sheet = info_of(model, "person:u-boris", ctx)
            test.eq(table.concat(sheet.lines, "|"), "Name: boris|UIN: 234567890|Status: online, on 1 desktop|Unread: none")
            aicq.update(model, {type = "activate", id = aicq.INFO_OK}, ctx)
            sheet = info_of(model, "person:u-alice", ctx)
            test.eq(table.concat(sheet.lines, "|"), "Name: Alice|UIN: 345678901|Status: offline|Unread: none")
            test.eq(sheet.image, aicq.OFFLINE_IMAGE)
            test.eq(aicq.person_details({name = "X", online = true, desktops = 3, unread = 1})[4], "Unread: 1 message")
            test.eq(aicq.person_details({name = "X", online = true, desktops = 3, unread = 0})[2], "UIN: not known")

            local blind = aicq.init(stand_in(roster(), {describe_error = "no access", list_error = "desktop silent"}))
            sheet = info_of(blind, "agent:user_agent:01abc", ctx)
            test.eq(table.concat(sheet.lines, "\n"), table.concat({
                "Name: Analyst", "ID: user_agent:01abc", "Description: none given",
                "Status: reachable", "Kind: not read, no access", "Model: not read, no access",
                "Traits: not read, no access", "Tools: not read, no access", "Dialog: not known, desktop silent"}, "\n"))
            local raising = aicq.init(stand_in(roster(), {describe_raises = "boom"}))
            sheet = info_of(raising, "agent:app.agents:scout", ctx)
            test.not_nil(sheet.lines[6]:find("Model: not read, ", 1, true), tostring(sheet.lines[6]))
            test.not_nil(sheet.lines[6]:find("boom", 1, true), "the error is the reason")
        end)

        test.it("Remove Contact asks first; Yes removes and reloads, No and Esc keep; a refusal is named", function()
            local sys = stand_in(roster(), {people = people()})
            local model = aicq.init(sys)
            local ctx = window()
            right_click(model, "person:u-boris", 4, 3, ctx)
            choose(model, "remove", ctx)
            test.eq(#sys.calls.removed, 0, "nothing is removed before the answer")
            test.eq(aicq.title(model), "Remove Contact")
            local sheet = aicq.view(model)
            test.is_nil(ui.problem(sheet))
            test.eq(sheet.children[2].text, "Remove boris from your contact list?")
            local buttons = sheet.children[#sheet.children].children
            test.eq(buttons[1].id .. "|" .. tostring(buttons[1].default) .. "|" .. buttons[2].id .. "|" .. tostring(buttons[2].default),
                aicq.REMOVE_YES .. "|false|" .. aicq.REMOVE_NO .. "|true", "No is the default: a stray Enter keeps the person")
            aicq.update(model, {type = "activate", id = aicq.REMOVE_NO}, ctx)
            test.is_nil(model.confirm, "No closes the question")
            test.eq(#sys.calls.removed, 0)
            right_click(model, "person:u-boris", 4, 3, ctx)
            choose(model, "remove", ctx)
            aicq.update(model, {type = "tick"}, ctx)
            test.not_nil(model.confirm, "a tick leaves the question up")
            aicq.update(model, {type = "key", key_type = "esc"}, ctx)
            test.is_nil(model.confirm, "Esc closes it")
            test.eq(ctx.closed.count, 0, "and not the window")
            right_click(model, "person:u-boris", 4, 3, ctx)
            choose(model, "remove", ctx)
            aicq.update(model, {type = "activate", id = aicq.REMOVE_YES}, ctx)
            test.eq(table.concat(sys.calls.removed, ","), "u-boris")
            test.eq(labels(model), "People (1/2)|  Anna (2)|  Alice|Agents (3/3)|  Analyst|  Scout|  Writer", "the list is read anew")
            test.eq(status(model), "boris was removed from the list")
            aicq.update(model, {type = "tick"}, ctx)
            test.eq(status(model), "1 person online, 3 agents", "a tick lets the notice go")
            local stubborn = aicq.init(stand_in(roster(), {people = people(), remove_error = "denied"}))
            right_click(stubborn, "person:u-anna", 4, 2, ctx)
            choose(stubborn, "remove", ctx)
            aicq.update(stubborn, {type = "activate", id = aicq.REMOVE_YES}, ctx)
            test.eq(status(stubborn), "Anna was not removed: denied")
            test.not_nil(row(stubborn, "person:u-anna"), "and stays")
        end)

        test.it("Add Contact… and Add Agent… open from their buttons and their headers; what they added is loaded, selected and shown", function()
            local agents = roster()
            local sys = stand_in(agents, {people = people()})
            local model = aicq.init(sys)
            local ctx = window()
            local bar = child(model, "row")
            test.eq(bar and (bar.children[1].id .. "|" .. bar.children[1].text .. "|" .. bar.children[2].id .. "|" .. bar.children[2].text),
                aicq.ADD_CONTACT .. "|Add Contact…|" .. aicq.ADD .. "|Add Agent…")
            aicq.update(model, {type = "activate", id = aicq.ADD_CONTACT}, ctx)
            test.eq(sys.calls.contact_adds .. "/" .. sys.calls.adds, "1/0", "one button opens Add Contact…")
            aicq.update(model, {type = "activate", id = aicq.ADD}, ctx)
            test.eq(sys.calls.contact_adds .. "/" .. sys.calls.adds, "1/1", "the other Add Agent…")
            right_click(model, "group:people", 3, 1, ctx)
            choose(model, "add_contact", ctx)
            right_click(model, "group:agents", 3, 5, ctx)
            choose(model, "add", ctx)
            test.eq(sys.calls.contact_adds .. "/" .. sys.calls.adds, "2/2", "so do the headers' items")
            test.eq(menu_ids(model), "no menu")
            local refused = aicq.init(stand_in(roster(), {add_error = "unknown entry"}))
            aicq.update(refused, {type = "activate", id = aicq.ADD}, ctx)
            test.eq(status(refused), "Add Agent did not open: unknown entry")
            aicq.update(refused, {type = "activate", id = aicq.ADD_CONTACT}, ctx)
            test.eq(status(refused), "Add Contact did not open: unknown entry")
            -- "Add Agent…" created an agent: the list read anew, the agent
            -- selected, the collapsed Agents expanded.
            aicq.update(model, {type = "toggle", id = aicq.TREE, value = row(model, "group:agents")}, ctx)
            agents[#agents + 1] = {agent_id = "user_agent:02new", title = "Newcomer", description = ""}
            test.is_true(aicq.added(model, "user_agent:02new"))
            test.eq(model.selected, "agent:user_agent:02new")
            test.is_true(row(model, "group:agents").expanded)
            -- "Add Contact…" added a person: the same, by its news.
            aicq.update(model, {type = "toggle", id = aicq.TREE, value = row(model, "group:people")}, ctx)
            sys.given.people[#sys.given.people + 1] = {id = "u-eve", name = "Eve", uin = "456789012", online = false}
            test.is_true(aicq.hear(model, aicq.CONTACT_ADDED, {user_id = "u-eve"}))
            test.eq(model.selected, "person:u-eve")
            test.eq(labels(model),
                "People (2/4)|  Anna (2)|  boris|  Alice|  Eve|Agents (4/4)|  Analyst|  Newcomer|  Scout|  Writer")
        end)

        test.it("Not in List: who wrote without being a contact, between People and Agents, newest first, only while not empty", function()
            local list = people()
            list[#list + 1] = {id = "u-dora", name = "Dora", online = true, desktops = 1, unread = 1, listed = false,
                last_at = "2026-09-15T10:00:00Z"}
            list[#list + 1] = {id = "u-egor", name = "Egor", online = false, desktops = 0, unread = 0, listed = false,
                last_at = "2026-09-15T11:30:00Z"}
            list[#list + 1] = {id = "u-fay", name = "Fay", online = true, desktops = 1, unread = 0, listed = false,
                last_at = "2026-09-15T10:00:00Z"}
            local sys = stand_in(roster(), {people = list})
            local model = aicq.init(sys)
            local ctx = window()
            test.eq(labels(model),
                "People (2/3)|  Anna (2)|  boris|  Alice|Not in List (3)|  Egor|  Dora (1)|  Fay|Agents (3/3)|  Analyst|  Scout|  Writer",
                "the newest conversation first, a tie by name; being online does not reorder them")
            test.eq(row(model, "person:u-dora").image, aicq.MESSAGE_IMAGE, "unread: the envelope, as for people")
            test.eq(row(model, "person:u-egor").image, aicq.OFFLINE_IMAGE)
            test.eq(row(model, "person:u-fay").image, aicq.ONLINE_IMAGE)
            test.eq(row(model, "person:u-egor").group, "strangers")
            test.eq(status(model), "2 people online, 3 agents", "Not in List is not counted among people online")
            test.eq(info_of(model, "person:u-fay", ctx).lines[5], "Contact: not in your list")
            aicq.update(model, {type = "activate", id = aicq.INFO_OK}, ctx)
            -- Remove from List: dismissed at once, no question.
            right_click(model, "person:u-egor", 4, 5, ctx)
            choose(model, "dismiss", ctx)
            test.eq(table.concat(sys.calls.dismissed, ","), "u-egor")
            test.is_nil(model.confirm, "no question: a new message brings them back")
            test.eq(status(model), "Egor was removed from Not in List")
            test.is_nil(row(model, "person:u-egor"))
            -- Add to Contacts: into People, selected there, People opened.
            aicq.update(model, {type = "toggle", id = aicq.TREE, value = row(model, "group:people")}, ctx)
            right_click(model, "person:u-dora", 4, 5, ctx)
            choose(model, "add_person", ctx)
            test.eq(table.concat(sys.calls.listed, ","), "u-dora")
            test.eq(row(model, "person:u-dora").group, "people", "moved to People")
            test.eq(model.selected, "person:u-dora")
            test.is_true(row(model, "group:people").expanded, "People opens to show them")
            test.eq(status(model), "Dora is in your contacts now")
            right_click(model, "person:u-fay", 4, 7, ctx)
            choose(model, "dismiss", ctx)
            test.is_nil(row(model, "group:strangers"), "the last one gone: the group is gone")
            test.eq(labels(model), "People (3/4)|  Anna (2)|  boris|  Dora (1)|  Alice|Agents (3/3)|  Analyst|  Scout|  Writer")
            local stubborn = people()
            stubborn[#stubborn + 1] = {id = "u-fay", name = "Fay", online = true, listed = false, last_at = "2026-09-15T10:00:00Z"}
            local refused = aicq.init(stand_in(roster(), {people = stubborn, dismiss_error = "denied"}))
            right_click(refused, "person:u-fay", 4, 5, ctx)
            choose(refused, "dismiss", ctx)
            test.eq(status(refused), "Fay was not removed: denied")
            test.not_nil(row(refused, "person:u-fay"), "and stays")
        end)

        test.it("a ping from the messenger and a message window's news reload the unread counts; nothing opens on its own", function()
            local sys = stand_in(roster(), {people = people()})
            local model = aicq.init(sys)
            sys.given.people[2].unread = 1
            test.is_true(aicq.pinged(model))
            test.eq(row(model, "person:u-boris").label, "boris (1)")
            test.eq(row(model, "person:u-boris").image, aicq.MESSAGE_IMAGE)
            sys.given.people[1].unread = 0
            test.is_true(aicq.hear(model, aicq.SEEN, {}))
            test.eq(row(model, "person:u-anna").label, "Anna", "read: the count goes")
            test.eq(row(model, "person:u-anna").image, aicq.ONLINE_IMAGE, "and the flower comes back")
            test.eq(#sys.calls.messages + #sys.calls.opened, 0, "no window opened")
            test.is_false(aicq.hear(model, aicq.READ, {}), "the messenger's own topic is not the list's")
            test.is_false(aicq.hear(model, "something.else", {}))
        end)

        test.it("the open list watches its person at the messenger and reports agents to the service; again every tick", function()
            local agents = roster()
            local sys = stand_in(agents, {people = people()})
            local model = aicq.init(sys)
            local ctx = window()
            local reports = sys.calls.reports
            test.eq(sys.calls.watches, 1, "the list watches on opening")
            test.eq(#reports, 1, "and reports after the first load")
            test.eq(tostring(reports[1].online) .. "/" .. tostring(reports[1].offline), "3/0", "agents only: people are not the service's number")
            aicq.update(model, {type = "key", key_type = "f5"}, ctx)
            test.eq(#reports, 2, "after F5")
            aicq.update(model, {type = "tick"}, ctx)
            test.eq(#reports, 3, "after the minute's tick: the report stays fresh while the list is open")
            test.eq(sys.calls.watches, 2, "and the watch is said again: a restarted messenger learns it")
            info_of(model, "agent:app.agents:writer", ctx)
            aicq.update(model, {type = "tick"}, ctx)
            test.eq(#reports, 4, "a tick reloads under the Info sheet too")
            test.not_nil(model.sheet, "and leaves the sheet open")
            agents[#agents + 1] = {agent_id = "user_agent:02new", title = "Newcomer", description = ""}
            aicq.added(model, "user_agent:02new")
            test.eq(#reports, 5, "after Add Agent… created one")
            test.eq(reports[5].online, 4)
            aicq.dispose(model)
            test.is_true(reports[6] and reports[6].closed == true, "closing, the list says so")
            test.eq(sys.calls.unwatches, 1, "and stops the messenger's pings")
            local failed = stand_in(roster(), {roster_error = "no actor"})
            aicq.init(failed)
            test.eq(#failed.calls.reports, 0, "a roster not read is not reported: the service keeps its own count")
            local mixed = stand_in({WRITER, ARCHIVE, SCOUT})
            aicq.init(mixed)
            test.eq(tostring(mixed.calls.reports[1].online) .. "/" .. tostring(mixed.calls.reports[1].offline), "2/1",
                "online and offline counted apart")
            local deaf = aicq.init(stand_in(roster(), {watch_error = "the messenger is not running"}))
            test.eq(status(deaf), "not live, reloads each minute: the messenger is not running", "a watch not heard is said")
            deaf.sys.given.watch_error = nil
            aicq.update(deaf, {type = "tick"}, ctx)
            test.eq(status(deaf), "0 people online, 3 agents", "until a tick's watch is heard")
        end)

        test.it("the service believes a fresh report, and its own reading when the report is stale, absent or withdrawn", function()
            local own = {WRITER}
            local report = aicq.heard({online = 5, offline = 1}, 1000)
            test.eq(tostring(report.online) .. "/" .. tostring(report.offline) .. "@" .. tostring(report.at), "5/1@1000")
            test.eq(aicq.REPORT_TTL_S, 2 * aicq.TICK_S, "two ticks")
            test.eq(aicq.pick(own, nil, report, 1000).title, "5 agents online", "a fresh report wins")
            test.eq(aicq.pick(own, nil, report, 1000 + aicq.REPORT_TTL_S - 1).title, "5 agents online", "until two ticks old")
            test.eq(aicq.pick(own, nil, report, 1000 + aicq.REPORT_TTL_S).title, "1 agent online", "then the service's own reading")
            test.eq(aicq.pick(own, nil, nil, 1000).title, "1 agent online", "no report")
            test.eq(aicq.pick(nil, "no actor", report, 1010).title, "5 agents online", "the list's count even when the service's read failed")
            test.eq(aicq.pick(nil, "no actor", nil, 1010).title, "aICQ: offline, the roster was not read: no actor")
            local nobody = aicq.heard({online = 0, offline = 2}, 1000)
            test.eq(aicq.pick(own, nil, nobody, 1001).image, aicq.OFFLINE_IMAGE, "the list saying nobody is online is believed too")
            test.eq(aicq.pick(own, nil, report, 1000, 2).title, "2 people online, 5 agents", "a desktop's person: people too")
            test.eq(aicq.pick(nil, "no actor", nil, 1010, 1).title, "1 person online, agents not read: no actor")
            test.is_nil(aicq.heard({closed = true}, 1000), "a closing list withdraws its report")
            test.is_nil(aicq.heard({closed = true, online = 3}, 1000), "closed wins over a count in the same message")
            test.is_nil(aicq.heard({online = "many"}, 1000), "not a count")
            test.is_nil(aicq.heard({online = -1}, 1000))
            test.is_nil(aicq.heard("5", 1000))
            test.eq(aicq.unwrap({{online = 2}}).online, 2, "the message's one-element array")
            test.is_nil(next(aicq.unwrap("text")), "not a table: an empty body")
        end)

        test.it("the tray: the flower while anyone is online, people and agents apart; the envelope with aICQ (N) while unread", function()
            local on = aicq.tray(3)
            test.eq(table.concat({on.key, on.text, on.title, on.image, on.icon, on.entry, tostring(on.ttl)}, "|"),
                "windows.aicq|aICQ|3 agents online|windows.aicq:images/aicq|✿|windows.aicq:contacts|180")
            test.eq(aicq.tray(1).title, "1 agent online")
            local off = aicq.tray(0)
            test.eq(off.title .. "|" .. off.image .. "|" .. off.entry, "aICQ: offline|windows.aicq:images/aicq_off|windows.aicq:contacts")
            test.eq(aicq.tray(0, "denied").title, "aICQ: offline, the roster was not read: denied")
            test.eq(aicq.presence({WRITER, ARCHIVE}).title, "1 agent online", "the service counts by the list's rule")
            test.eq(aicq.presence(nil, "no actor").image, aicq.OFFLINE_IMAGE)
            test.eq(aicq.tray(4, nil, 2).title, "2 people online, 4 agents")
            local person = aicq.tray(0, nil, 1)
            test.eq(person.title .. "|" .. person.image, "1 person online, 0 agents|" .. aicq.ONLINE_IMAGE, "a person online lights it")
            test.eq(aicq.tray(1, nil, 0).title, "0 people online, 1 agent")
            test.eq(aicq.tray(0, nil, 0).image, aicq.OFFLINE_IMAGE, "nobody at all: grey")
            test.eq(aicq.tray(0, "denied", 3).title, "3 people online, agents not read: denied")
            local mail = aicq.mail(3, on)
            test.eq(table.concat({mail.key, mail.text, mail.title, mail.image, mail.icon, mail.entry, tostring(mail.ttl)}, "|"),
                "windows.aicq|aICQ (3)|3 new messages|windows.aicq:images/message|✉|windows.aicq:contacts|180")
            test.eq(aicq.mail(1, on).title, "1 new message")
            test.is_true(aicq.mail(0, on) == on, "nothing unread: the flower as it was")
            test.is_true(aicq.mail(nil, off) == off)
        end)

        test.it("lays the list out without overlaps: the tree, both Add buttons whole, the status row", function()
            local model = aicq.init(stand_in(roster(), {people = people()}))
            local plan = ui.plan(aicq.view(model), 32, 21, ui.interaction())
            test.eq(clash(plan, 32, 21), "none")
            local contact, agent = plan.by_id[aicq.ADD_CONTACT].rect, plan.by_id[aicq.ADD].rect
            test.eq(contact.w .. "/" .. agent.w, "15/13", "both buttons whole at the window's width")
            test.eq(plan.by_id[aicq.TREE].rect.h, 18, "the tree takes what the buttons and the status leave")
            right_click(model, "person:u-anna", 20, 20, window())
            local menu_plan = ui.plan(aicq.view(model), 32, 21, ui.interaction())
            test.eq(clash(menu_plan, 32, 21), "none", "the menu floats: it takes no room in the column")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
