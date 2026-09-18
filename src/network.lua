-- aICQ between computers (docs/aicq-network.md): who is where, as data.
--
-- Pure: no IO, no runtime modules. The presence service feeds it what it
-- hears (rosters from the pg group, the cluster's membership) and asks it
-- what to say; the people library asks it how to read an id.
--
-- A person on another computer is `net:<node>:<user_id>`. The node comes
-- first, so an id containing ":" or "@" stays whole: a local user_id is
-- sometimes an e-mail address, which is why `user@node` was not usable. A
-- node whose name contains ":" cannot be written this way and takes no part
-- (`network.node_ok`).
--
-- Presence is judged PER NODE, in three states (`network.judge`): `fresh`
-- while a roster from the node is younger than FRESH_S, `unknown` while it
-- is older but the node is still a member, `gone` once the membership no
-- longer has it. The absence of news alone never means offline: pg skips a
-- node silently while its breaker is open.
local network = {}

-- The pg scope, group and topic of the rosters.
network.SCOPE = "chicago.aicq:network"
network.GROUP = "aicq.presence"
network.ROSTER = "aicq.roster"
-- How often a node announces its roster, and how long one stays fresh:
-- three announcements and a margin.
network.ANNOUNCE_S = 10
network.FRESH_S = 35
-- The most people one roster carries, and the longest name kept.
network.ROSTER_MAX = 500
network.NAME_MAX = 64

local PREFIX = "net:"

-- node_ok(node) -> whether a node can take part: a non-empty name without ":".
function network.node_ok(node: any): boolean
    return type(node) == "string" and node ~= "" and string.find(node, ":", 1, true) == nil
end

-- id(node, user_id) -> "net:<node>:<user_id>" | nil when either is unusable.
function network.id(node: any, user_id: any): string?
    if not network.node_ok(node) then return nil end
    if type(user_id) ~= "string" or user_id == "" then return nil end
    return PREFIX .. node .. ":" .. user_id
end

-- split(id) -> node, user_id | nil — only for an id of that form.
function network.split(id: any): (string?, string?)
    if type(id) ~= "string" or string.sub(id, 1, #PREFIX) ~= PREFIX then return nil, nil end
    local rest = string.sub(id, #PREFIX + 1)
    local found = string.find(rest, ":", 1, true)
    local colon: integer = math.tointeger(found) or 0
    if colon <= 1 or colon == #rest then return nil, nil end
    return string.sub(rest, 1, colon - 1), string.sub(rest, colon + 1)
end

-- remote(id) -> whether the id names a person on another computer.
function network.remote(id: any): boolean
    local node = network.split(id)
    return node ~= nil
end

-- node_of(pid) -> node | nil — the node in "{node@host|0x…}", the relay's
-- id, which is the cluster's name of the node (relay.node_name ==
-- cluster.name, a precondition of the cluster stand).
function network.node_of(pid: any): string?
    local node = string.match(tostring(pid or ""), "^{([^@|}]+)@")
    return node
end

-- members(cluster, group) -> {[node] = true} | nil
--
-- The nodes that still count: in the cluster's membership
-- (`system.cluster.members()`, a list of {id}) AND with a member in the pg
-- group (`get_members`, a list of pids). Either list may be nil when it could
-- not be read; then the other decides alone, and with neither nothing is
-- known (nil).
function network.members(cluster: any, group: any): any
    local in_cluster: any = nil
    if type(cluster) == "table" then
        in_cluster = {}
        for _, member in ipairs(cluster) do
            if type(member) == "table" and type(member.id) == "string" then in_cluster[member.id] = true end
        end
    end
    local in_group: any = nil
    if type(group) == "table" then
        in_group = {}
        for _, pid in ipairs(group) do
            local node = network.node_of(pid)
            if node then in_group[node] = true end
        end
    end
    if in_cluster == nil then return in_group end
    if in_group == nil then return in_cluster end
    local both: any = {}
    for node in pairs(in_cluster) do
        if in_group[node] then both[node] = true end
    end
    return both
end

-- label(name, node) -> "<name> (<node>)", how a remote person is shown.
function network.label(name: any, node: any): string
    return tostring(name) .. " (" .. tostring(node) .. ")"
end

local function clip(text: string, max: integer): string
    if #text <= max then return text end
    return string.sub(text, 1, max)
end

-- roster(people) -> the body a node broadcasts: {p = {{i = user_id, m =
-- name}, …}}, a gapless list with string keys (integer keys with a hole do
-- not survive the hop between nodes). `people` is {[user_id] = name}.
-- Sorted by id, so equal rosters are equal bodies.
function network.roster(people: any): any
    local ids: {string} = {}
    for id in pairs(type(people) == "table" and people or {}) do
        if type(id) == "string" and id ~= "" then ids[#ids + 1] = id end
    end
    table.sort(ids)
    local list: any = {}
    for index, id in ipairs(ids) do
        if index > network.ROSTER_MAX then break end
        local name: any = people[id]
        list[#list + 1] = {i = id, m = clip(type(name) == "string" and name ~= "" and name or id, network.NAME_MAX)}
    end
    return {p = list}
end

-- heard(state, node, body, now) -> true | false, why
--
-- Takes a roster heard from `node` — the node of the SENDING process, never
-- a field of the body — at `now` (seconds). `state` is {nodes = {[node] =
-- {at, people = {[user_id] = name}}}}. An unusable node or body is refused
-- and the state is left as it was.
function network.heard(state: any, node: any, body: any, now: integer): (boolean, string?)
    if not network.node_ok(node) then
        return false, "the node's name " .. tostring(node) .. " cannot take part: it is empty or has a colon"
    end
    if type(body) ~= "table" or type(body.p) ~= "table" then return false, "the roster has no list of people" end
    local people: any = {}
    local count = 0
    for _, item in ipairs(body.p) do
        if count >= network.ROSTER_MAX then break end
        if type(item) == "table" and type(item.i) == "string" and item.i ~= "" then
            local name: any = item.m
            people[item.i] = clip(type(name) == "string" and name ~= "" and name or item.i, network.NAME_MAX)
            count = count + 1
        end
    end
    state.nodes[node] = {at = now, people = people}
    return true, nil
end

-- judge(state, node, now, members) -> "fresh" | "unknown" | "gone"
--
-- `members` is the set of nodes the cluster and the group still have
-- ({[node] = true}), or nil when it could not be read — then nothing is
-- declared gone on that account.
function network.judge(state: any, node: any, now: integer, members: any): string
    if type(members) == "table" and not members[node] then return "gone" end
    local heard: any = state.nodes[node]
    if heard and now - heard.at < network.FRESH_S then return "fresh" end
    if heard == nil and type(members) ~= "table" then return "gone" end
    return "unknown"
end

-- forget(state, now, members) — drop the nodes the membership no longer has.
function network.forget(state: any, now: integer, members: any)
    if type(members) ~= "table" then return end
    for node in pairs(state.nodes) do
        if not members[node] then state.nodes[node] = nil end
    end
end

-- people(state, self, now, members) -> {{id, node, user_id, name, state}, …}
--
-- Everyone last heard on another computer whose node is not gone: `state`
-- "online" while the node is fresh, "unknown" while it is not. `self` is this
-- node, left out. Sorted by name, then id.
function network.people(state: any, self: any, now: integer, members: any): any
    local out: any = {}
    for node, heard in pairs(state.nodes) do
        if node ~= self then
            local verdict = network.judge(state, node, now, members)
            if verdict ~= "gone" then
                for user_id, name in pairs(heard.people) do
                    out[#out + 1] = {id = network.id(node, user_id), node = node, user_id = user_id, name = name,
                        state = verdict == "fresh" and "online" or "unknown"}
                end
            end
        end
    end
    table.sort(out, function(a: any, b: any): boolean
        local left, right = string.lower(tostring(a.name)), string.lower(tostring(b.name))
        if left ~= right then return left < right end
        return tostring(a.id) < tostring(b.id)
    end)
    return out
end

-- view(state, self, now, members) -> {people = network.people(…), nodes =
-- {[node] = "fresh" | "unknown"}} — what the presence service answers a
-- window with. A node that is gone is not in `nodes`.
function network.view(state: any, self: any, now: integer, members: any): any
    local nodes: any = {}
    local seen: any = {}
    for node in pairs(state.nodes) do seen[node] = true end
    for node in pairs(type(members) == "table" and members or {}) do seen[node] = true end
    for node in pairs(seen) do
        if node ~= self and network.node_ok(node) then
            local verdict = network.judge(state, node, now, members)
            if verdict ~= "gone" then nodes[node] = verdict end
        end
    end
    return {people = network.people(state, self, now, members), nodes = nodes}
end

-- status_in(view, id) -> "online" | "offline" | "unknown", name?
--
-- One remote person, for a contact, from a `view`: online while their node
-- is fresh and lists them, offline while it is fresh without them or is not
-- there at all (gone), unknown while the node is unknown. `name` is the one
-- last heard, when the view has it. Without a view (presence not read) the
-- answer is unknown.
function network.status_in(view: any, id: any): (string, any)
    local node, user_id = network.split(id)
    if node == nil or user_id == nil then return "offline", nil end
    if type(view) ~= "table" or type(view.nodes) ~= "table" then return "unknown", nil end
    local name: any = nil
    for _, person in ipairs(type(view.people) == "table" and view.people or {}) do
        if person.id == id then name = person.name end
    end
    local verdict: any = view.nodes[node]
    if verdict == "fresh" then return name ~= nil and "online" or "offline", name end
    if verdict == "unknown" then return "unknown", name end
    return "offline", nil
end

-- ─── Messages (phase 2, docs/aicq-network.md §5) ──────────────────────

-- The name each node's messenger answers to in the cluster's EVENTUAL
-- registry, and the topics between two messengers.
network.MESSENGER_PREFIX = "chicago.aicq.messenger@"
network.DELIVER = "aicq.deliver"
network.DELIVERED = "aicq.delivered"
-- How often undelivered messages are offered again.
network.RETRY_S = 5
-- The longest text taken from another computer: the sender's own limit.
network.BODY_MAX = 4000

function network.messenger_name(node: string): string
    return network.MESSENGER_PREFIX .. node
end

-- delivery(row, name) -> the body a messenger sends for one stored message
-- to another computer: {i = id, f = the sender's own id, t = the
-- recipient's id THERE, b = text, m = the sender's name} | nil, why. String
-- keys only.
function network.delivery(row: any, name: any): (any, string?)
    local _, user_id = network.split(row and row.to_id)
    if user_id == nil then return nil, "not a message to another computer" end
    if network.remote(row.from_id) then return nil, "a message from another computer is not sent on" end
    return {i = tostring(row.id), f = tostring(row.from_id), t = user_id, b = tostring(row.body or ""),
        m = type(name) == "string" and name ~= "" and clip(name, network.NAME_MAX) or tostring(row.from_id)}, nil
end

-- accept(node, body, self) -> {id, from_id, to_id, body, name} | nil, why
--
-- A delivery heard from `node` — the node of the SENDING process, never a
-- field of the body — as the row this computer stores: `from_id` is
-- net:<node>:<f>. Refused: a node that cannot take part, this node itself,
-- a body without an id, a sender or a text, a recipient that is itself
-- another computer's id, a text over BODY_MAX.
function network.accept(node: any, body: any, self: any): (any, string?)
    if not network.node_ok(node) then return nil, "the node's name " .. tostring(node) .. " cannot take part" end
    if node == self then return nil, "a computer does not deliver to itself" end
    if type(body) ~= "table" then return nil, "no delivery" end
    local id, from, to, text = body.i, body.f, body.t, body.b
    if type(id) ~= "string" or id == "" then return nil, "a delivery without a message id" end
    if type(from) ~= "string" or from == "" then return nil, "a delivery without a sender" end
    if type(to) ~= "string" or to == "" or network.remote(to) then return nil, "a delivery without a recipient here" end
    if type(text) ~= "string" or text == "" then return nil, "a delivery without a text" end
    if #text > network.BODY_MAX * 4 then return nil, "a text longer than the sender's limit" end
    local name: any = body.m
    return {id = id, from_id = network.id(node, from), to_id = to, body = text,
        name = type(name) == "string" and name ~= "" and clip(name, network.NAME_MAX) or from}, nil
end

-- acked(node, row) -> whether an acknowledgement from `node` may confirm
-- that stored message: only the node it was addressed to confirms it.
function network.acked(node: any, row: any): boolean
    local to_node = network.split(row and row.to_id)
    return to_node ~= nil and to_node == node
end

return network
