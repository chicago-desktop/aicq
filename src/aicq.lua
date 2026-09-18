-- aICQ: the contact list, the message window, Add Contact and the agents'
-- tray item, in the manner of ICQ.
--
-- Everything the windows and the presence service decide lives here as pure
-- functions over plain data, so the harness checks it without the roster, the
-- people library, the registry or the compositor: a window hands its reads
-- over as `sys` (as Notepad does), the service calls `pick` with what it
-- read. The windows themselves are wiring: `contacts.lua`, `message.lua`,
-- `add_contact.lua`.
--
-- People and agents are apart (docs/aicq-people.md §1): two top-level groups,
-- People and Agents, each headed "People (2/7)" — online / total — with the
-- online rows first; the status is the picture. An agent is online when the
-- roster (`kickside.agents.traits:roster_list`) lists it, and the roster lists
-- ONLY reachable agents: an agent is offline only when the roster itself says
-- `reachable = false`. A person is online while a running desktop reports them
-- (`chicago.aicq:people`, §4).

local ui = require("ui")
local editor = require("editor")
local network = require("network")

local aicq = {}

aicq.TRAY_KEY = "chicago.aicq"
aicq.CONTACTS = "chicago.aicq:contacts"
aicq.DIALOG = "chicago.aicq:dialog"
aicq.MESSAGE = "chicago.aicq:message"
aicq.ADD_CONTACT_WINDOW = "chicago.aicq:add_contact"
aicq.ONLINE_IMAGE = "chicago.aicq:images/aicq"
aicq.OFFLINE_IMAGE = "chicago.aicq:images/aicq_off"
aicq.AGENT_IMAGE = "chicago.aicq:images/agent"
aicq.AGENT_OFF_IMAGE = "chicago.aicq:images/agent_off"
aicq.MESSAGE_IMAGE = "chicago.aicq:images/message"
-- One character one cell wide each: the flower and the envelope in a cells tray.
aicq.ICON = "✿"
aicq.MAIL_ICON = "✉"
aicq.TRAY_TTL = 180
aicq.TREE = "agents"
aicq.MENU = "agent_menu"
aicq.INFO_OK = "info_ok"
-- The buttons under the list — each group's own "Add…".
aicq.ADD = "add_agent"
aicq.ADD_CONTACT = "add_contact"
aicq.REMOVE_YES = "remove_yes"
aicq.REMOVE_NO = "remove_no"
aicq.GROUPS = {"people", "strangers", "network", "agents"}
-- The presence service and the report to it. An open list tells the service
-- its count of agents (the list runs under the logged-on person's actor and
-- sees their agents too); the service believes the report while it is younger
-- than two of its ticks, and the list reloads every tick, so the report does
-- not age while the list is open.
aicq.SERVICE = "chicago.aicq.presence"
aicq.REPORT = "aicq.presence_report"
aicq.TICK_S = 60
aicq.REPORT_TTL_S = 2 * aicq.TICK_S
-- The messenger (docs/aicq-people.md §5); the people library aliases these, so
-- they are said in one place. A window watches its OWN person: the messenger
-- pings the watchers of either end of a message with `aicq.new`. `aicq.read`
-- goes to the messenger after `mark_read` (the library sends it).
aicq.MESSENGER = "chicago.aicq.messenger"
aicq.NEW = "aicq.new"
aicq.WATCH = "aicq.watch"
aicq.UNWATCH = "aicq.unwatch"
aicq.READ = "aicq.read"
-- Presence → messenger: another computer is heard again; its undelivered
-- messages are offered at once instead of on the next retry.
aicq.NODE_BACK = "aicq.node_back"
-- Between aICQ's own windows, to the contact list that opened them: a message
-- window has shown someone's messages (they are read now), Add Contact has
-- added someone. Not `aicq.read`: that one is the messenger's.
aicq.SEEN = "aicq.seen"
aicq.CONTACT_ADDED = "aicq.contact_added"
aicq.HISTORY_LIMIT = 200

local TITLES: any = {people = "People", strangers = "Not in List", network = "Network", agents = "Agents"}
local HEADERS: any = {people = aicq.ONLINE_IMAGE, strangers = aicq.OFFLINE_IMAGE, network = aicq.ONLINE_IMAGE,
    agents = aicq.AGENT_IMAGE}
-- The groups shown only while someone is in them.
local SOMETIMES: any = {strangers = true, network = true}

local function trim(value: any): string
    if type(value) ~= "string" then return "" end
    return (value:gsub("^%s*(.-)%s*$", "%1"))
end

local function whole(value: any): integer
    return math.tointeger(tonumber(value) or 0) or 0
end

-- ask(fn, ...) -> value, nil | nil, reason. The people library answers
-- `value, nil` or `nil, reason`; a raise and a bare `false` are refusals too,
-- and a refusal always comes with words.
local function ask(fn: any, ...): (any, any)
    local ok, value, why = pcall(fn, ...)
    if not ok then return nil, tostring(value) end
    if value == nil or value == false then return nil, tostring(why or "no reason given") end
    return value, nil
end

local function online_in(members: any): integer
    local count = 0
    for _, entry in ipairs(members) do
        if entry.online then count = count + 1 end
    end
    return count
end

local function by_title(a: any, b: any): boolean
    local left, right = tostring(a.title or a.agent_id), tostring(b.title or b.agent_id)
    if left ~= right then return left < right end
    return tostring(a.agent_id) < tostring(b.agent_id)
end

-- groups(agents) -> {online = {agent…}, offline = {agent…}}, each by name: the
-- roster alone, as the presence service counts it. A row without `agent_id` is
-- skipped: there is nothing to open a dialog with.
function aicq.groups(agents: any): any
    local out: any = {online = {}, offline = {}}
    for _, agent in ipairs(type(agents) == "table" and agents or {}) do
        if type(agent) == "table" and agent.agent_id ~= nil and tostring(agent.agent_id) ~= "" then
            local side: any = agent.reachable == false and out.offline or out.online
            side[#side + 1] = agent
        end
    end
    table.sort(out.online, by_title)
    table.sort(out.offline, by_title)
    return out
end

local function persons(count: integer): string
    return count == 1 and "1 person online" or (tostring(count) .. " people online")
end

-- headline(people, agents) -> "2 people online, 4 agents": the two kinds
-- apart, as §1 keeps them — the tray's title and the list's bottom row.
local function headline(people: integer, agents: integer): string
    return persons(people) .. ", " .. (agents == 1 and "1 agent" or (tostring(agents) .. " agents"))
end

-- tray(online, why, people) -> the `desktop.tray` item of a desktop with
-- nothing unread: the green flower while anyone — a person or an agent — is
-- online, the grey one otherwise. `online` counts agents; `people` — the
-- persons online other than the desktop's own — is nil for a desktop without
-- a logged-on person, and the title then speaks of agents alone. `why` — why
-- the roster was not read: the title says so rather than passing it off as
-- "nobody".
function aicq.tray(online: any, why: any?, people: any?): any
    local count = whole(online)
    local lit = count > 0
    local title: string
    if people ~= nil then
        local others = whole(people)
        lit = lit or others > 0
        if why ~= nil then title = persons(others) .. ", agents not read: " .. tostring(why)
        else title = headline(others, count) end
    elseif count > 0 then title = count == 1 and "1 agent online" or (tostring(count) .. " agents online")
    elseif why ~= nil then title = "aICQ: offline, the roster was not read: " .. tostring(why)
    else title = "aICQ: offline" end
    return {key = aicq.TRAY_KEY, text = "aICQ", title = title,
        image = lit and aicq.ONLINE_IMAGE or aicq.OFFLINE_IMAGE, icon = aicq.ICON,
        entry = aicq.CONTACTS, ttl = aicq.TRAY_TTL}
end

-- mail(unread, base) -> the tray item of a desktop whose person has unread
-- messages: the envelope, `aICQ (N)` and "N new message(s)"; a click opens the
-- contact list, as the flower's does. With none unread it is `base` — the
-- flower `pick` built. The presence service pushes it per desktop
-- (docs/aicq-people.md §1, §5).
function aicq.mail(unread: any, base: any): any
    local count = whole(unread)
    if count <= 0 then return base end
    return {key = aicq.TRAY_KEY, text = "aICQ (" .. tostring(count) .. ")",
        title = count == 1 and "1 new message" or (tostring(count) .. " new messages"),
        image = aicq.MESSAGE_IMAGE, icon = aicq.MAIL_ICON, entry = aicq.CONTACTS, ttl = aicq.TRAY_TTL}
end

-- presence(agents, why, people) -> the tray item for the roster as read:
-- online is counted by the same rule the list uses.
function aicq.presence(agents: any, why: any?, people: any?): any
    local groups = aicq.groups(agents)
    return aicq.tray(#groups.online, why, people)
end

-- heard(body, now) -> the report as the service keeps it: {online, offline, at}.
-- nil — no report any more: the list closed (`closed = true`) or sent no count.
function aicq.heard(body: any, now: any): any
    if type(body) ~= "table" or body.closed == true then return nil end
    local online = math.tointeger(tonumber(body.online) or -1)
    local offline = whole(body.offline)
    if online == nil or online < 0 then return nil end
    return {online = online, offline = offline, at = now}
end

-- pick(agents, why, report, now, people) -> the tray item: the open list's
-- count of agents while its report is younger than two ticks, otherwise the
-- service's own reading; `people` goes to `tray` as it is.
function aicq.pick(agents: any, why: any, report: any, now: any, people: any?): any
    local at: any = type(report) == "table" and tonumber(report.at) or nil
    if at ~= nil and (tonumber(now) or 0) - at < aicq.REPORT_TTL_S then
        return aicq.tray(report.online, nil, people)
    end
    return aicq.presence(agents, why, people)
end

-- The arrival of a message ------------------------------------------------
--
-- What the messenger shows the recipient of a just-stored message: a balloon
-- tip by the notification area (the shell's chicago.shell.sdk:notify) and a
-- flash of their aICQ windows. Decided here, as pure data, so the harness
-- checks the balloon without a desktop.
--
-- Nothing is kept for a person with no desktop open: the shell has no
-- offline delivery (the owner's rule), and the message waits in the history
-- where it already lies.

aicq.BALLOON_TIMEOUT = 10
-- The balloon is at most 40 cells wide and four lines high: eighty
-- characters fill it, and what is longer ends in an ellipsis of our own
-- rather than in a line the theme cuts.
-- Both limits are locals first and fields after: to the typechecker a field
-- of this table is anything the table ever holds, and `shorten` takes an
-- integer. The fields stay because the harness and the docs name them.
local PREVIEW_MAX = 80
-- The compositor refuses a balloon whose title is longer than 64 characters
-- (`BALLOON_TITLE` in the base), and a refused balloon would cost the flash
-- with it: a long name is cut here instead, the ellipsis counted in.
local TITLE_MAX = 64
aicq.PREVIEW_MAX = PREVIEW_MAX
aicq.TITLE_MAX = TITLE_MAX
-- The title of a balloon whose sender's name could not be read. An id is
-- not a name, and would tell the person nothing.
aicq.NEW_MESSAGE = "New message"
aicq.NO_TEXT = "You have a new message."
-- The windows a flash asks attention of, in this order: the conversation
-- itself while one is open, else the contact list.
aicq.FLASH_ENTRIES = {aicq.MESSAGE, aicq.CONTACTS}

-- runes(text) -> how many characters: UTF-8 lead bytes, not bytes — what the
-- compositor counts its limits in.
local function runes(text: string): integer
    local _, count = string.gsub(text, "[^\128-\191]", "")
    return math.tointeger(count) or 0
end

-- shorten(text, max) -> the text whole while it is at most `max` characters,
-- else its first max-1 characters and an ellipsis: the answer never exceeds
-- `max`, the ellipsis counted in. Characters, not bytes: a cut inside a
-- UTF-8 sequence prints a broken rune.
local function shorten(text: string, max: integer): string
    if runes(text) <= max then return text end
    local count, cut = 0, #text
    for index = 1, #text do
        local byte = string.byte(text, index)
        -- A lead byte or an ASCII one: a character starts here.
        if byte < 128 or byte >= 192 then
            count = count + 1
            if count > max - 1 then
                cut = index - 1
                break
            end
        end
    end
    return trim(string.sub(text, 1, cut)) .. "…"
end

-- preview(text) -> the message on one line: trimmed, every run of blanks a
-- single space, at most PREVIEW_MAX characters and an ellipsis after them.
function aicq.preview(text: any): string
    return shorten(trim((string.gsub(tostring(text or ""), "%s+", " "))), PREVIEW_MAX)
end

-- arrival(row, name) -> the balloon for the recipient | nil when there is
-- none to show: a message whose two ends are one person, or a row without
-- them. `row` is the stored row (`people.ends`): {from_id, to_id, body}.
-- `name` is the sender's display name, nil when it could not be read.
--
-- A click on the balloon's body opens the conversation with the sender —
-- the message window with its arguments ("<id>\n<name>"), the same ones the
-- contact list opens it with. The tail points at aICQ's tray item, and the
-- key is the sender's: a burst from one person replaces its own balloon
-- instead of filling the desktop's queue (it holds eight).
function aicq.arrival(row: any, name: any): any
    if type(row) ~= "table" then return nil end
    local from, to = tostring(row.from_id or ""), tostring(row.to_id or "")
    if from == "" or to == "" or from == to then return nil end
    local known: any = trim(name)
    -- A name longer than the compositor takes would have the whole balloon
    -- refused, and the flash after it lost: it is cut to fit instead.
    if known == "" then known = nil else known = shorten(known, TITLE_MAX) end
    local text = aicq.preview(row.body)
    if text == "" then text = aicq.NO_TEXT end
    return {user = to, title = known or aicq.NEW_MESSAGE, text = text,
        image = aicq.MESSAGE_IMAGE, anchor = aicq.TRAY_KEY,
        entry = aicq.MESSAGE, args = from .. "\n" .. (known or ""),
        key = "aicq:" .. from, timeout = aicq.BALLOON_TIMEOUT}
end

-- unwrap(value) -> a message's body as a table. A message arrives wrapped:
-- the payload is userdata, and inside may be a one-element array; a field read
-- directly would be nil without an error.
function aicq.unwrap(value: any): any
    if type(value) == "userdata" then
        local ok, decoded = pcall(value.data, value)
        if ok and type(decoded) == "table" then return aicq.unwrap(decoded) end
        return {}
    end
    if type(value) ~= "table" then return {} end
    if value[1] ~= nil and #value > 0 then return aicq.unwrap(value[1]) end
    return value
end

-- By name without regard to case.
local function by_name(a: any, b: any): boolean
    local left, right = string.lower(tostring(a.name)), string.lower(tostring(b.name))
    if left ~= right then return left < right end
    return a.key < b.key
end

-- Online first, then by name: People and Agents.
local function by_presence(a: any, b: any): boolean
    if a.online ~= b.online then return a.online == true end
    return by_name(a, b)
end

-- The newest conversation first (`last_at`), then by name: Not in List.
local function by_recency(a: any, b: any): boolean
    local left, right = tostring(a.last_at or ""), tostring(b.last_at or "")
    if left ~= right then return left > right end
    return by_name(a, b)
end

-- arrange(agents, people) -> {people = {entry…}, strangers = {entry…},
-- network = {entry…}, agents = {entry…}}. Network is everyone on another
-- computer who is not a contact (`network = true`, docs/aicq-network.md §3),
-- online first, then by name; a remote person keeps `remote`, `node` and
-- `state` ("online", "offline", "unknown"). People and Agents online first, then by name; the
-- strangers — who wrote but are not contacts (`listed = false`, ICQ's "Not in
-- List") — the newest conversation first. An entry is {kind = "agent" |
-- "person", id, key, name, online}; an agent keeps its roster row in `agent`,
-- a person their contact row in `person` and `uin`, `desktops`, `unread`,
-- `listed` and `last_at`. A row without an id is skipped. The groups never mix.
function aicq.arrange(agents: any, people: any): any
    local out: any = {people = {}, strangers = {}, network = {}, agents = {}}
    for _, agent in ipairs(type(agents) == "table" and agents or {}) do
        if type(agent) == "table" and agent.agent_id ~= nil and tostring(agent.agent_id) ~= "" then
            local id = tostring(agent.agent_id)
            out.agents[#out.agents + 1] = {kind = "agent", id = id, key = "agent:" .. id,
                name = tostring(agent.title or id), online = agent.reachable ~= false, agent = agent}
        end
    end
    for _, person in ipairs(type(people) == "table" and people or {}) do
        if type(person) == "table" and person.id ~= nil and tostring(person.id) ~= "" then
            local id = tostring(person.id)
            local entry: any = {kind = "person", id = id, key = "person:" .. id,
                name = tostring(person.name or id), online = person.online == true, uin = person.uin,
                desktops = whole(person.desktops), unread = whole(person.unread),
                listed = person.listed ~= false, last_at = person.last_at, person = person,
                remote = person.remote == true, node = person.node, state = person.state}
            local side: any = entry.listed and out.people or (person.network == true and out.network or out.strangers)
            side[#side + 1] = entry
        end
    end
    table.sort(out.people, by_presence)
    table.sort(out.strangers, by_recency)
    table.sort(out.network, by_presence)
    table.sort(out.agents, by_presence)
    return out
end

-- summary(groups) -> "2 people online, 4 agents" — the list's bottom row, the
-- two kinds apart as the tray's title keeps them (docs/aicq-people.md §1).
function aicq.summary(groups: any): string
    -- Network's people count as people online: the row must agree with the
    -- groups above it.
    return headline(online_in(groups.people) + online_in(groups.network or {}), online_in(groups.agents))
end

-- counts(groups) -> {online, offline} of the AGENTS — what an open list tells
-- the service. The service's number is agents; people do not count in it.
function aicq.counts(groups: any): any
    local online = online_in(groups.agents)
    return {online = online, offline = #groups.agents - online}
end

-- A group the person has not touched is collapsed exactly when it is empty.
local function collapsed(model: any, group: string): boolean
    local chosen = model.collapsed[group]
    if chosen ~= nil then return chosen == true end
    return #model.groups[group] == 0
end

-- A member's row. An agent: the agent picture, grey when offline. A person:
-- the flower, grey when offline, or the envelope and "Name (N)" while N
-- messages are unread.
local function member_row(entry: any, group: string): any
    if entry.kind == "agent" then
        return {id = entry.key, label = entry.name, depth = 1, has_children = false, kind = "entry",
            image = entry.online and aicq.AGENT_IMAGE or aicq.AGENT_OFF_IMAGE, agent = entry.id, group = group}
    end
    local label, image = entry.name, entry.online and aicq.ONLINE_IMAGE or aicq.OFFLINE_IMAGE
    if entry.unread > 0 then
        label, image = entry.name .. " (" .. tostring(entry.unread) .. ")", aicq.MESSAGE_IMAGE
    end
    return {id = entry.key, label = label, depth = 1, has_children = false, kind = "entry",
        image = image, person = entry.id, group = group}
end

-- rows(model) -> the tree's rows: a header per group — People, Network and
-- Agents with their online/total counter, Not in List with how many; Not in
-- List and Network only while someone is in them — and the members under it
-- unless the group is collapsed.
-- A row carries ids, not tables: the tree goes to the compositor as frame
-- state.
function aicq.rows(model: any): any
    local rows: any = {}
    for _, group in ipairs(aicq.GROUPS) do
        local members: any = model.groups[group]
        if not SOMETIMES[group] or #members > 0 then
            local shut = collapsed(model, group)
            local counter = group == "strangers" and tostring(#members)
                or (tostring(online_in(members)) .. "/" .. tostring(#members))
            rows[#rows + 1] = {id = "group:" .. group, label = TITLES[group] .. " (" .. counter .. ")",
                depth = 0, has_children = true, expanded = not shut, kind = "entry", image = HEADERS[group], group = group}
            if not shut then
                for _, entry in ipairs(members) do rows[#rows + 1] = member_row(entry, group) end
            end
        end
    end
    return rows
end

local function entry_of(model: any, key: any): any
    for _, group in ipairs(aicq.GROUPS) do
        for _, entry in ipairs(model.groups[group]) do
            if entry.key == key then return entry end
        end
    end
    return nil
end

local function row_of(model: any, id: any): any
    for _, row in ipairs(aicq.rows(model)) do
        if row.id == id then return row end
    end
    return nil
end

local function member(row: any): boolean
    return row ~= nil and (row.agent ~= nil or row.person ~= nil)
end

-- load(model) — the roster and the contacts anew. Either may fail alone: the
-- other still shows, and the status row names what was not read; so does a
-- contact list whose presence was not read (its field `why`). The selection
-- holds by row, not by number: a vanished one gives way to the first member.
function aicq.load(model: any)
    local reasons: any = {}
    local ok, list, truncated = pcall(model.sys.roster)
    local agents: any = {}
    if ok then
        agents, model.truncated = list, truncated == true
    else
        reasons[#reasons + 1] = "roster not read: " .. tostring(list)
    end
    local people, why = ask(model.sys.contacts)
    if people == nil then reasons[#reasons + 1] = "contacts not read: " .. tostring(why) end
    model.groups = aicq.arrange(agents, people)
    model.failure = #reasons > 0 and table.concat(reasons, "; ") or nil
    model.unknown = type(people) == "table" and people.why ~= nil and tostring(people.why) or nil
    -- The count goes to the presence service. A roster not read is not
    -- reported: the service keeps its own reading. Not delivered — the tray
    -- stays on the service's own reading; nothing for the window to say.
    if ok and model.sys.report then pcall(model.sys.report, aicq.counts(model.groups)) end
    local rows = aicq.rows(model)
    for _, row in ipairs(rows) do
        if row.id == model.selected then return end
    end
    model.selected = nil
    for _, row in ipairs(rows) do
        if member(row) then
            model.selected = row.id
            return
        end
    end
    model.selected = rows[1] and rows[1].id or nil
end

-- watch(model) — the list tells the messenger it shows its person's messages;
-- again every tick, so a restarted messenger learns it within a minute. Not
-- heard: the list still reloads every minute, and the status row says so.
function aicq.watch(model: any)
    local ok, why = ask(model.sys.watch)
    if ok then model.live = nil else model.live = why end
end

-- init(sys) -> the model. `sys` — the window's reads:
--   roster() -> agents, truncated              (raises on a refusal)
--   contacts() -> people, why                  (chicago.aicq:people.contacts)
--   open(agent) -> ok, why                     (the agent's dialog window)
--   message({id, name}) -> ok, why             (the message window)
--   add() -> ok, why                           (the "Add Agent…" window)
--   add_contact() -> ok, why                   (the "Add Contact…" window)
--   add_person(user_id), remove(user_id) -> true, why
--   dismiss(user_id) -> true, why              (off Not in List until they write)
--   describe(agent) -> {kind, fields}, why     (a registry entry or a component)
--   dialog_open(agent) -> open?, why
--   report(counts) -> ok, why                  (the count to the presence service)
--   watch(), unwatch() -> ok, why              (the messenger, for the list's person)
function aicq.init(sys: any): any
    local model: any = {sys = sys, groups = {people = {}, strangers = {}, network = {}, agents = {}}, collapsed = {}, selected = nil,
        menu = nil, sheet = nil, confirm = nil, notice = nil, failure = nil, unknown = nil, live = nil,
        truncated = false}
    aicq.load(model)
    aicq.watch(model)
    return model
end

local function reveal(model: any, key: string)
    local entry = entry_of(model, key)
    if not entry then return end
    model.collapsed[entry.kind == "agent" and "agents" or (entry.listed and "people" or "strangers")] = false
    model.selected = key
end

-- added(model, agent_id) — "Add Agent…" created an agent: the list anew, the
-- new agent selected, the Agents group expanded.
function aicq.added(model: any, agent_id: any): boolean
    aicq.load(model)
    reveal(model, "agent:" .. tostring(agent_id))
    return true
end

-- contact_added(model, user_id) — "Add Contact…" added a person: the list
-- anew, the person selected, the People group expanded.
function aicq.contact_added(model: any, user_id: any): boolean
    aicq.load(model)
    reveal(model, "person:" .. tostring(user_id))
    return true
end

-- pinged(model) — the messenger's `aicq.new`: a message to or from the list's
-- person; the unread counts anew. Nothing opens on its own: a message shows
-- as a count and an envelope, never as a window over someone's work.
function aicq.pinged(model: any): boolean
    aicq.load(model)
    return true
end

-- hear(model, topic, body) — what aICQ's own windows told the list: a message
-- window has shown someone's messages (the counts anew), Add Contact has
-- added someone (loaded and selected).
function aicq.hear(model: any, topic: any, body: any): boolean
    if topic == aicq.SEEN then
        aicq.load(model)
        return true
    end
    if topic == aicq.CONTACT_ADDED then
        local id: any = type(body) == "table" and body.user_id or nil
        aicq.contact_added(model, id)
        return true
    end
    return false
end

-- dispose(model) — the window closes: the service stops believing its report
-- at once, not in two ticks, and the messenger stops pinging it.
function aicq.dispose(model: any)
    if model.sys.report then pcall(model.sys.report, {closed = true}) end
    pcall(model.sys.unwatch)
end

-- title(model) -> the window's caption while a sheet is up, nil otherwise.
function aicq.title(model: any): any
    if model.confirm then return "Remove Contact" end
    return model.sheet and model.sheet.title or nil
end

-- open(model, key) — an agent's dialog, a person's message window.
local function open(model: any, key: any)
    local entry = entry_of(model, key)
    if not entry then return end
    local ok, why
    if entry.kind == "agent" then ok, why = ask(model.sys.open, entry.agent)
    else ok, why = ask(model.sys.message, {id = entry.id, name = entry.name}) end
    if ok then model.notice = nil else model.notice = "did not open: " .. tostring(why) end
end

local function add(model: any)
    local ok, why = ask(model.sys.add)
    if ok then model.notice = nil else model.notice = "Add Agent did not open: " .. tostring(why) end
end

local function add_contact(model: any)
    local ok, why = ask(model.sys.add_contact)
    if ok then model.notice = nil else model.notice = "Add Contact did not open: " .. tostring(why) end
end

local function toggle(model: any, group: any)
    if TITLES[group] == nil then return end
    model.collapsed[group] = not collapsed(model, group)
end

-- The names of a list: strings as they are, tables by id or name.
local function names(value: any): any
    local out: any = {}
    for _, item in ipairs(value) do
        if type(item) == "table" then out[#out + 1] = tostring(item.id or item.name or "?")
        else out[#out + 1] = tostring(item) end
    end
    return out
end

-- "Label: value" — the value, "none declared", or the reason the field was
-- not read. What was not read is never left out silently.
local function field(facts: any, why: any, key: string, label: string): string
    if facts == nil then return label .. ": not read, " .. tostring(why or "no reason given") end
    local value: any = type(facts.fields) == "table" and facts.fields[key] or nil
    if value == nil then return label .. ": none declared" end
    if type(value) == "table" then
        local list = names(value)
        if #list == 0 then return label .. ": none declared" end
        return label .. ": " .. table.concat(list, ", ")
    end
    return label .. ": " .. tostring(value)
end

-- details(agent, online, facts, why, dialog, dialog_why) -> an agent's Info
-- lines: what the roster and the agent's entry give, and the reason for what
-- was not read.
function aicq.details(agent: any, online: any, facts: any, why: any, dialog: any, dialog_why: any): any
    local description = tostring(agent.description or "")
    local lines: any = {
        "Name: " .. tostring(agent.title or agent.agent_id),
        "ID: " .. tostring(agent.agent_id),
        "Description: " .. (description ~= "" and description or "none given"),
        "Status: " .. (online and "reachable" or "not reachable"),
        "Kind: " .. (facts ~= nil and tostring(facts.kind) or ("not read, " .. tostring(why or "no reason given"))),
        field(facts, why, "model", "Model"),
        field(facts, why, "traits", "Traits"),
        field(facts, why, "tools", "Tools"),
    }
    if dialog == nil then lines[#lines + 1] = "Dialog: not known, " .. tostring(dialog_why or "no reason given")
    elseif dialog then lines[#lines + 1] = "Dialog: open; its session's state is shown there"
    else lines[#lines + 1] = "Dialog: not open" end
    return lines
end

-- person_details(entry) -> a person's Info lines: name, UIN, online or not and
-- on how many desktops, what is unread.
function aicq.person_details(entry: any): any
    local status: string
    if entry.state == "unknown" then status = "not known: " .. tostring(entry.node) .. " has not been heard from lately"
    elseif not entry.online then status = "offline"
    elseif entry.desktops == 1 then status = "online, on 1 desktop"
    else status = "online, on " .. tostring(entry.desktops) .. " desktops" end
    local unread = "none"
    if entry.unread > 0 then unread = tostring(entry.unread) .. (entry.unread == 1 and " message" or " messages") end
    local lines: any = {"Name: " .. entry.name, "UIN: " .. tostring(entry.uin or "not known"), "Status: " .. status,
        "Unread: " .. unread}
    if entry.remote then lines[#lines + 1] = "Computer: " .. tostring(entry.node) end
    if entry.listed == false then lines[#lines + 1] = "Contact: not in your list" end
    return lines
end

local function info(model: any, key: any)
    local entry = entry_of(model, key)
    if not entry then return end
    if entry.kind == "person" then
        model.sheet = {title = entry.name .. " - Info", lines = aicq.person_details(entry),
            image = entry.online and aicq.ONLINE_IMAGE or aicq.OFFLINE_IMAGE}
        return
    end
    local agent = entry.agent
    local ok, facts, why = pcall(model.sys.describe, agent)
    if not ok then
        why = tostring(facts)
        facts = nil
    end
    local listed, dialog, dialog_why = pcall(model.sys.dialog_open, agent)
    if not listed then
        dialog_why = tostring(dialog)
        dialog = nil
    end
    model.sheet = {title = entry.name .. " - Info",
        lines = aicq.details(agent, entry.online, facts, why, dialog, dialog_why),
        image = entry.online and aicq.AGENT_IMAGE or aicq.AGENT_OFF_IMAGE}
end

-- Remove Contact asks first: a stray click must not drop someone.
local function ask_remove(model: any, key: any)
    local entry = entry_of(model, key)
    if entry then model.confirm = {id = entry.id, name = entry.name} end
end

local function remove(model: any)
    local chosen: any = model.confirm
    model.confirm = nil
    local ok, why = ask(model.sys.remove, chosen.id)
    if ok then model.notice = chosen.name .. " was removed from the list"
    else model.notice = chosen.name .. " was not removed: " .. tostring(why) end
    aicq.load(model)
end

-- Add to Contacts: someone from Not in List moves to People and is selected
-- there.
local function list_person(model: any, key: any)
    local entry = entry_of(model, key)
    if not entry then return end
    local ok, why = ask(model.sys.add_person, entry.id)
    if ok then model.notice = entry.name .. " is in your contacts now"
    else model.notice = entry.name .. " was not added: " .. tostring(why) end
    aicq.load(model)
    if ok then reveal(model, tostring(key)) end
end

-- Remove from List: off Not in List until they write again. No question:
-- nothing is lost, a new message brings them back.
local function dismiss(model: any, key: any)
    local entry = entry_of(model, key)
    if not entry then return end
    local ok, why = ask(model.sys.dismiss, entry.id)
    if ok then model.notice = entry.name .. " was removed from Not in List"
    else model.notice = entry.name .. " was not removed: " .. tostring(why) end
    aicq.load(model)
end

-- The menu at the pointer. A contact: Send Message / Info… / Remove Contact.
-- Someone in Not in List: Add to Contacts / Send Message / Info… / Remove from
-- List. An agent: Open / Info… / Add Agent…. People's and Agents' headers:
-- their own Add; the empty field: both. Not in List's header opens none.
local function menu_items(model: any): any
    local entry: any = model.menu.key and entry_of(model, model.menu.key) or nil
    -- Someone in Network: they never wrote, so there is nothing to dismiss.
    if entry and entry.kind == "person" and entry.remote and not entry.listed
        and type(entry.person) == "table" and entry.person.network == true then
        return {{id = "add_person", text = "Add to Contacts", accel = 1}, {id = "send", text = "Send Message", accel = 1},
            {id = "info", text = "Info…", accel = 1}}
    end
    if entry and entry.kind == "person" and not entry.listed then
        return {{id = "add_person", text = "Add to Contacts", accel = 1}, {id = "send", text = "Send Message", accel = 1},
            {id = "info", text = "Info…", accel = 1}, {separator = true},
            {id = "dismiss", text = "Remove from List", accel = 1}}
    end
    if entry and entry.kind == "person" then
        return {{id = "send", text = "Send Message", accel = 1}, {separator = true},
            {id = "info", text = "Info…", accel = 1}, {id = "remove", text = "Remove Contact", accel = 1}}
    end
    if entry then
        return {{id = "open", text = "Open", accel = 1}, {separator = true},
            {id = "info", text = "Info…", accel = 1}, {separator = true},
            {id = "add", text = "Add Agent…", accel = 1}}
    end
    local items: any = {}
    if model.menu.group ~= "agents" then items[#items + 1] = {id = "add_contact", text = "Add Contact…", accel = 5} end
    if model.menu.group ~= "people" then items[#items + 1] = {id = "add", text = "Add Agent…", accel = 1} end
    return items
end

-- view(model) -> the window's tree: the Remove question or the Info sheet
-- while one is up; otherwise the two groups, the two Add buttons and the
-- status row, and the menu at the pointer while it is open.
function aicq.view(model: any): any
    if model.confirm then
        return ui.confirm({title = "Remove Contact",
            lines = {"Remove " .. model.confirm.name .. " from your contact list?"},
            image = aicq.ONLINE_IMAGE, icon = aicq.ICON, yes = aicq.REMOVE_YES, no = aicq.REMOVE_NO})
    end
    if model.sheet then
        return ui.message({title = model.sheet.title, lines = model.sheet.lines, image = model.sheet.image,
            icon = aicq.ICON, ok = aicq.INFO_OK})
    end
    local rows = aicq.rows(model)
    local selected: any = nil
    for index, row in ipairs(rows) do
        if row.id == model.selected then selected = index end
    end
    local status: string
    if model.failure then status = tostring(model.failure)
    elseif model.notice then status = tostring(model.notice)
    elseif model.live then status = "not live, reloads each minute: " .. tostring(model.live)
    elseif model.unknown then status = "who is online is not known: " .. tostring(model.unknown)
    else status = aicq.summary(model.groups) .. (model.truncated and " (partial)" or "") end
    local children: any = {
        {kind = "tree", id = aicq.TREE, rows = rows, selected = selected},
        {kind = "row", size = 2, gap = 1, children = {
            {kind = "button", id = aicq.ADD_CONTACT, size = 15, text = "Add Contact…"},
            {kind = "button", id = aicq.ADD, size = 13, text = "Add Agent…"},
        }},
        {kind = "label", size = 1, text = status},
    }
    if model.menu then
        children[#children + 1] = ui.context_menu({id = aicq.MENU, x = model.menu.x, y = model.menu.y,
            items = menu_items(model)})
    end
    return {kind = "column", children = children}
end

-- update(model, action, context) — what the list does with an action.
function aicq.update(model: any, action: any, context: any): boolean
    if type(action) ~= "table" then return false end
    -- A tick reloads and reports to the service, under an open sheet too, or
    -- the report would age while the person reads; it watches again and lets
    -- a minute-old notice go.
    if action.type == "tick" then
        model.notice = nil
        aicq.load(model)
        aicq.watch(model)
        return true
    end
    if model.confirm then
        if action.type == "activate" and action.id == aicq.REMOVE_YES then
            remove(model)
            return true
        end
        if (action.type == "activate" and action.id == aicq.REMOVE_NO) or (action.type == "key" and action.key_type == "esc") then
            model.confirm = nil
            return true
        end
        return false
    end
    if model.sheet then
        -- OK and Esc return to the list; Esc does not close the window here.
        if (action.type == "activate" and action.id == aicq.INFO_OK) or (action.type == "key" and action.key_type == "esc") then
            model.sheet = nil
            return true
        end
        return false
    end
    if action.type == "dismiss" and action.id == aicq.MENU then
        model.menu = nil
        return true
    end
    if action.type == "activate" and action.menu == aicq.MENU then
        local key: any = model.menu and model.menu.key or nil
        model.menu = nil
        if action.id == "open" or action.id == "send" then open(model, key)
        elseif action.id == "info" then info(model, key)
        elseif action.id == "remove" then ask_remove(model, key)
        elseif action.id == "add_person" then list_person(model, key)
        elseif action.id == "dismiss" then dismiss(model, key)
        elseif action.id == "add_contact" then add_contact(model)
        elseif action.id == "add" then add(model) end
        return true
    end
    if action.type == "activate" and action.id == aicq.ADD then
        add(model)
        return true
    end
    if action.type == "activate" and action.id == aicq.ADD_CONTACT then
        add_contact(model)
        return true
    end
    if action.id == aicq.TREE then
        local row: any = type(action.value) == "table" and action.value or nil
        if action.type == "toggle" and row then
            toggle(model, row.group)
        elseif action.type == "context" then
            if member(row) then
                model.selected = row.id
                model.menu = {x = action.x, y = action.y, key = row.id}
            elseif row and (row.group == "strangers" or row.group == "network") then
                model.menu = nil
            else
                model.menu = {x = action.x, y = action.y, group = row and row.group or nil}
            end
        elseif action.type == "select" and row then
            -- A click on the row already selected is a double click: a member
            -- opens, a group folds. A key selecting the row again is not.
            if action.pointer and row.id == model.selected then
                if member(row) then open(model, row.id) else toggle(model, row.group) end
            end
            model.selected = row.id
        elseif action.type == "activate" then
            local current: any = row or row_of(model, model.selected)
            if member(current) then open(model, current.id)
            elseif current then toggle(model, current.group) end
        end
        return true
    end
    if action.type == "key" and action.key_type == "f5" then
        aicq.load(model)
        return true
    end
    if action.type == "key" and action.key_type == "esc" then
        context.close()
        return true
    end
    return false
end

-- The message window ---------------------------------------------------------
--
-- History above, the input below, Send (the default; Ctrl+Enter) and Close.
-- Opening marks the person's messages read; the messenger's ping about a
-- message between the two reloads the history (and marks it read: it is on
-- screen).

aicq.TALK = {log = "log", draft = "draft", send = "send", close = "close", add = "add_to_list"}

-- talk_args(args) -> {id, name} of the person, and the pid of the contact list
-- that opened the window: "<user_id>\n<name>\n<pid>".
function aicq.talk_args(args: any): (any, any)
    local id, name, opener = tostring(args or ""):match("^([^\n]*)\n?([^\n]*)\n?([^\n]*)")
    id, name, opener = trim(id), trim(name), trim(opener)
    return {id = id, name = name ~= "" and name or id}, opener ~= "" and opener or nil
end

-- Ctrl+Enter arrives in two shapes: `enter` with `ctrl` from a terminal that
-- reports modifiers (kitty's protocol), and Ctrl+J from one that sends a bare
-- line feed for it (x/input reads LF so). The editor takes neither, so both
-- reach the window.
function aicq.send_key(action: any): boolean
    if type(action) ~= "table" or action.type ~= "key" or action.ctrl ~= true then return false end
    return action.key_type == "enter" or (action.key_type == "runes" and tostring(action.key or ""):lower() == "j")
end

-- talk_load(model) — the history anew; what is shown is read, so the person's
-- messages are marked, and the list that opened the window hears of it. A
-- history not read marks nothing.
function aicq.talk_load(model: any)
    if not model.me then return end
    local history, why = ask(model.sys.history, model.peer.id, aicq.HISTORY_LIMIT)
    if history == nil then
        model.failure = "history not read: " .. tostring(why)
        return
    end
    model.history, model.failure = history, nil
    local count, unmarked = ask(model.sys.mark_read, model.peer.id)
    if count == nil then
        model.marking = "not marked read: " .. tostring(unmarked)
        return
    end
    model.marking = nil
    if whole(count) > 0 and model.opener then pcall(model.sys.seen, model.opener) end
end

-- talk_watch(model) — the window tells the messenger it shows its person's
-- messages (its own person: the pings go by the reader); again every tick,
-- as the list does.
function aicq.talk_watch(model: any)
    if not model.me then return end
    local ok, why = ask(model.sys.watch, tostring(model.me.id))
    if ok then model.live = nil else model.live = why end
end

-- talk_listed(model) — whether the person is a contact: true, false (Not in
-- List, or not in the list at all), nil when it could not be read — then the
-- window offers nothing rather than an Add that may be wrong.
function aicq.talk_listed(model: any)
    if not model.me then return end
    local ok, listed = pcall(model.sys.listed, model.peer.id)
    if ok and (listed == true or listed == false) then model.listed = listed else model.listed = nil end
end

-- talk_add(model) — Add to List: the person becomes a contact, the button
-- goes, and the contact list that opened the window moves them to People.
function aicq.talk_add(model: any)
    if model.listed ~= false then return end
    local ok, why = ask(model.sys.add, model.peer.id)
    if not ok then
        model.notice = "not added: " .. tostring(why)
        return
    end
    model.listed, model.notice = true, nil
    model.note = model.peer.name .. " is in your contacts now."
    if model.opener then pcall(model.sys.added, model.opener, model.peer.id) end
end

-- talk_init(sys, args, context) -> the model. `sys` — the window's reads
-- (docs/aicq-people.md §4, §5):
--   me() -> {id, name, uin}, why
--   history(user_id, limit) -> messages, why
--   send(to_id, text) -> the message id, why, notice
--   mark_read(user_id) -> count, why
--   watch(user_id), unwatch(user_id) -> ok, why     (the messenger)
--   seen(opener) -> ok, why                         (the contact list's counts)
--   listed(user_id) -> is the person a contact?, why
--   add(user_id) -> true, why; added(opener, user_id) -> ok, why   (Add to List)
-- The input takes the focus: the window is opened to write.
function aicq.talk_init(sys: any, args: any, context: any): any
    local peer, opener = aicq.talk_args(args)
    local model: any = {sys = sys, peer = peer, opener = opener, me = nil, history = {}, failure = nil,
        notice = nil, note = nil, marking = nil, live = nil, empty = true}
    if context and context.interaction then context.interaction.focus = aicq.TALK.draft end
    if peer.id == "" then
        model.failure = "no person named: open the message window from the contact list"
        return model
    end
    local me, why = ask(sys.me)
    if not me then
        model.failure = "who you are was not read: " .. tostring(why)
        return model
    end
    model.me = me
    aicq.talk_load(model)
    aicq.talk_watch(model)
    aicq.talk_listed(model)
    return model
end

local function stamp(at: any): string
    local text = tostring(at or "")
    local day, clock = text:match("^(%d%d%d%d%-%d%d%-%d%d)[T ](%d%d:%d%d)")
    if day then return day .. " " .. tostring(clock) end
    return text
end

-- talk_lines(model, width) -> the history as the list's lines: the sender and
-- the time, the text under it two cells in, broken by words at `width`, an
-- empty line between messages.
function aicq.talk_lines(model: any, width: any): any
    local room = math.max(8, whole(width))
    local out: any = {}
    for index, message in ipairs(model.history) do
        if index > 1 then out[#out + 1] = "" end
        local mine = model.me ~= nil and tostring(message.from_id) == tostring(model.me.id)
        local who = mine and tostring(model.me.name or "You") or model.peer.name
        out[#out + 1] = who .. "  " .. stamp(message.at)
        for _, line in ipairs(ui.wrap_text(tostring(message.body or ""), room - 2)) do
            out[#out + 1] = "  " .. line
        end
        -- A message to another computer until that computer confirms it
        -- (docs/aicq-network.md §5). The list has no grey for one line, so
        -- the state is said in words under the text.
        if message.pending or message.failed then
            local node = tostring(network.split(message.to_id) or "the other computer")
            local note = message.failed and ("(not delivered: " .. tostring(message.failed) .. ")")
                or ("(not delivered yet: it will be when " .. node .. " is back)")
            for _, line in ipairs(ui.wrap_text(note, room - 2)) do out[#out + 1] = "  " .. line end
        end
    end
    return out
end

local function talk_status(model: any): (string, boolean)
    if model.failure then return tostring(model.failure), true end
    if model.notice then return tostring(model.notice), true end
    if model.marking then return tostring(model.marking), true end
    if model.note then return tostring(model.note), false end
    if model.live then return "not live, reloads each minute: " .. tostring(model.live), false end
    if #model.history == 0 then return "No messages with " .. model.peer.name .. " yet. Ctrl+Enter sends.", false end
    return "Ctrl+Enter sends.", false
end

-- talk_view(model, context) -> the window's tree. The lines are broken at the
-- list's text width: the client minus the scrollbar and a cell on each side.
function aicq.talk_view(model: any, context: any): any
    local T = aicq.TALK
    local lines = aicq.talk_lines(model, whole(context.width) - whole(context.scroll_cols or 1) - 2)
    local ready = model.me ~= nil
    local status, alert = talk_status(model)
    local buttons: any = {}
    -- Add to List stands next to Send only while the person is not a contact.
    if model.listed == false then buttons[#buttons + 1] = {kind = "button", id = T.add, size = 13, text = "Add to List"} end
    buttons[#buttons + 1] = {kind = "button", id = T.send, size = 10, text = "Send", default = true,
        disabled = not ready or model.empty}
    buttons[#buttons + 1] = {kind = "button", id = T.close, size = 10, text = "Close"}
    return {kind = "column", children = {
        {kind = "list", id = T.log, items = lines, reveal = #lines},
        {kind = "editor", id = T.draft, text = "", wrap = true, size = 5, read_only = not ready},
        {kind = "row", size = 2, gap = 1, align = "right", children = buttons},
        {kind = "label", size = 1, text = status, alert = alert},
    }}
end

-- talk_send(model, context) — the input's text to the person. Sent: the input
-- empties and the history reloads. Refused: the text stays, the reason is the
-- status row's.
function aicq.talk_send(model: any, context: any)
    if not model.me then return end
    local document = context.editor(aicq.TALK.draft)
    local body = trim(editor.text(document))
    if body == "" then return end
    local ok, id, why, notice = pcall(model.sys.send, model.peer.id, body)
    if not ok then id, why = nil, tostring(id) end
    if id == nil or id == false then
        model.notice = "not sent: " .. tostring(why or "no reason given")
        return
    end
    editor.set(document, "")
    model.empty, model.notice = true, nil
    -- A third value: the row is stored, but the messenger was not reached, so
    -- the person sees it at their window's next reload. Not a failure —
    -- sending again would send it twice.
    if notice ~= nil then model.note = "sent, but the messenger was not reached: " .. tostring(notice)
    else model.note = nil end
    aicq.talk_load(model)
end

-- talk_ping(model, body) — the messenger's `aicq.new {from_id, to_id,
-- message_id}`: a message between the two — theirs, or this person's own from
-- another desktop — reloads the history; any other is the contact list's.
function aicq.talk_ping(model: any, body: any): boolean
    if type(body) ~= "table" or not model.me then return false end
    local peer = model.peer.id
    if tostring(body.from_id) ~= peer and tostring(body.to_id) ~= peer then return false end
    aicq.talk_load(model)
    return true
end

-- talk_update(model, action, context) — what the window does with an action.
function aicq.talk_update(model: any, action: any, context: any): boolean
    if type(action) ~= "table" then return false end
    local T = aicq.TALK
    if action.type == "change" and action.id == T.draft then
        local empty = trim(editor.text(context.editor(T.draft))) == ""
        if empty == model.empty then return false end
        model.empty = empty
        return true
    end
    if (action.type == "activate" and action.id == T.send) or aicq.send_key(action) then
        aicq.talk_send(model, context)
        return true
    end
    if action.type == "activate" and action.id == T.add then
        aicq.talk_add(model)
        return true
    end
    if action.type == "activate" and action.id == T.close then
        context.close()
        return true
    end
    -- A tick is the fallback of a messenger that does not ping: the history
    -- anew, the watch again, and whether the person became a contact
    -- elsewhere.
    if action.type == "tick" or (action.type == "key" and action.key_type == "f5") then
        aicq.talk_load(model)
        aicq.talk_watch(model)
        aicq.talk_listed(model)
        return true
    end
    return false
end

-- talk_dispose(model) — closing, the window stops the messenger's pings (the
-- messenger drops a gone process's watches by itself too).
function aicq.talk_dispose(model: any)
    if model.me then pcall(model.sys.unwatch, tostring(model.me.id)) end
end

-- talk_title(model) -> "<name> - aICQ".
function aicq.talk_title(model: any): string
    return tostring(model.peer.name) .. " - aICQ"
end

-- Add Contact ----------------------------------------------------------------
--
-- ICQ's "Add/Invite Users": one search field, a results table (Name, UIN) and
-- Add. The query's shapes — an exact e-mail, three letters of a name, a UIN —
-- are the people library's rule: its refusal is shown in its own words, the
-- dialog does not keep a second copy of the rule.

aicq.FIND = {query = "query", find = "find", results = "results", add = "add", close = "close"}
aicq.FIND_HINT = "Type an e-mail, a UIN or three letters of a name."

-- find_init(sys, args, context) -> the model. `args` is the pid of the contact
-- list that opened the dialog. `sys`:
--   find(query) -> {{id, name, uin}}, why
--   add(user_id) -> true, why
--   added(opener, user_id) -> ok, why       (the contact list's news)
function aicq.find_init(sys: any, args: any, context: any): any
    local opener = trim(tostring(args or ""))
    if context and context.interaction then context.interaction.focus = aicq.FIND.query end
    return {sys = sys, opener = opener ~= "" and opener or nil, query = "", results = {}, selected = nil,
        status = aicq.FIND_HINT, alert = false}
end

-- find_search(model) — the query to the library; the first person found is
-- selected, so an exact e-mail is one Add away.
function aicq.find_search(model: any)
    local query = trim(model.query)
    model.selected = nil
    if query == "" then
        model.results, model.status, model.alert = {}, aicq.FIND_HINT, false
        return
    end
    local found, why = ask(model.sys.find, query)
    if found == nil then
        model.results, model.status, model.alert = {}, tostring(why), true
        return
    end
    model.results, model.alert = found, false
    if #found == 0 then
        model.status = "Nobody found for \"" .. query .. "\"."
        return
    end
    model.selected = tostring(found[1].id)
    model.status = (#found == 1 and "1 person found" or (tostring(#found) .. " people found"))
        .. "; Add puts the selected one in your list."
end

-- find_add(model) — the selected person into the caller's list; the dialog
-- stays open for the next one, as ICQ's did.
function aicq.find_add(model: any)
    local person: any = nil
    for _, candidate in ipairs(model.results) do
        if tostring(candidate.id) == model.selected then person = candidate end
    end
    if not person then return end
    local id = tostring(person.id)
    local name = tostring(person.name or id)
    local ok, why = ask(model.sys.add, id)
    if not ok then
        model.status, model.alert = name .. " was not added: " .. tostring(why), true
        return
    end
    model.status, model.alert = name .. " is in your contact list now.", false
    if model.opener then pcall(model.sys.added, model.opener, id) end
end

function aicq.find_view(model: any): any
    local F = aicq.FIND
    local rows: any = {}
    for _, person in ipairs(model.results) do
        rows[#rows + 1] = {id = tostring(person.id), cells = {tostring(person.name or person.id), tostring(person.uin or "")}}
    end
    return {kind = "column", padding = 1, padding_bottom = 0, gap = 0, children = {
        {kind = "label", size = 1, text = "Find by e-mail, name or UIN:"},
        {kind = "row", size = 2, gap = 1, children = {
            {kind = "input", id = F.query, text = model.query, placeholder = "e-mail, name or UIN"},
            {kind = "button", id = F.find, size = 10, text = "Find"},
        }},
        {kind = "table", id = F.results, rows = rows, selected = model.selected,
            columns = {{title = "Name", weight = 1}, {title = "UIN", width = 11, align = "right"}}},
        {kind = "label", size = 2, wrap = true, text = model.status, alert = model.alert},
        {kind = "row", size = 2, gap = 1, align = "right", children = {
            {kind = "button", id = F.add, size = 10, text = "Add", default = true, disabled = model.selected == nil},
            {kind = "button", id = F.close, size = 10, text = "Close"},
        }},
    }}
end

-- find_update(model, action, context) — Enter in the field or Find searches;
-- Add, Enter on a row or a second click on the selected row adds.
function aicq.find_update(model: any, action: any, context: any): any
    if type(action) ~= "table" then return false end
    local F = aicq.FIND
    if action.type == "change" and action.id == F.query then
        -- The field takes its text from the tree: a skipped frame would lose
        -- letters, so the answer is "redraw" (nil), not false.
        model.query = tostring(action.value or "")
        return nil
    end
    if action.type == "activate" and (action.id == F.query or action.id == F.find) then
        aicq.find_search(model)
        return true
    end
    if action.id == F.results and action.type == "select" then
        local row: any = type(action.value) == "table" and action.value or nil
        if not row then return false end
        if action.pointer and row.id == model.selected then aicq.find_add(model) end
        model.selected = row.id
        return true
    end
    if (action.id == F.results and action.type == "activate") or (action.type == "activate" and action.id == F.add) then
        aicq.find_add(model)
        return true
    end
    if action.type == "activate" and action.id == F.close then
        context.close()
        return true
    end
    return false
end

return aicq
