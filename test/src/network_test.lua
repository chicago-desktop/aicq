-- aICQ between computers as data (chicago.aicq:network_lib,
-- docs/aicq-network.md): the remote id and its reading, the roster a node
-- broadcasts and hears, each node judged fresh, unknown or gone, and what a
-- window is told.
local test = require("test")
local network = require("network")

-- safe(value) — a table that survives the hop between nodes: a gapless list
-- 1..n with nothing else, or string keys only (integer keys with a hole are
-- lost silently).
local function safe(value: any): boolean
    if type(value) ~= "table" then return true end
    local count, strings, integers = 0, 0, 0
    for key, item in pairs(value) do
        count = count + 1
        if type(key) == "string" then strings = strings + 1
        elseif math.tointeger(key) ~= nil then integers = integers + 1
        else return false end
        if not safe(item) then return false end
    end
    if integers > 0 and (strings > 0 or integers ~= #value) then return false end
    return true
end

local function define_tests()
    test.describe("aICQ network", function()
        test.it("a remote id keeps an id with @ and : whole; a local id is never taken for a remote one", function()
            test.eq(network.id("node-b", "butschster@gmail.com"), "net:node-b:butschster@gmail.com")
            local node, user = network.split("net:node-b:butschster@gmail.com")
            test.eq(tostring(node) .. "|" .. tostring(user), "node-b|butschster@gmail.com")
            node, user = network.split("net:node-b:a:b")
            test.eq(tostring(node) .. "|" .. tostring(user), "node-b|a:b", "the node ends at the first colon")
            -- The users module mints UUIDs and e-mail addresses (measured on
            -- the owner's database): neither reads as remote.
            test.is_false(network.remote("27ca8d0d-d955-4c1b-a5ec-dd5c4d204229"))
            test.is_false(network.remote("butschster@gmail.com"))
            test.is_false(network.remote("user@node-b"), "the plain user@node form is not an id here")
            test.is_false(network.remote("net:"))
            test.is_false(network.remote("net::u"))
            test.is_false(network.remote("net:node-b:"))
            test.is_true(network.remote("net:node-b:u"))
        end)

        test.it("a node whose name has a colon takes no part, and its roster is refused with the reason", function()
            test.is_false(network.node_ok("node:b"))
            test.is_false(network.node_ok(""))
            test.is_false(network.node_ok(nil))
            test.is_true(network.node_ok("node-b"))
            test.is_nil(network.id("node:b", "u"))
            local state: any = {nodes = {}}
            local ok, why = network.heard(state, "node:b", network.roster({u = "U"}), 100)
            test.is_false(ok)
            test.eq(why, "the node's name node:b cannot take part: it is empty or has a colon")
            test.is_nil(state.nodes["node:b"])
        end)

        test.it("the roster survives the hop: a gapless list with string keys, sorted, capped, names clipped", function()
            local body = network.roster({["u-b"] = "Bob", ["u-a"] = "Anna", ["u-c"] = "", [""] = "nobody"})
            test.is_true(safe(body), "no key the hop would lose")
            local ids = {}
            for _, item in ipairs(body.p) do ids[#ids + 1] = item.i .. "=" .. item.m end
            test.eq(table.concat(ids, ","), "u-a=Anna,u-b=Bob,u-c=u-c", "sorted by id; an empty name is the id")
            local long = network.roster({u = string.rep("x", 200)})
            test.eq(#long.p[1].m, network.NAME_MAX)
            local many: any = {}
            for index = 1, network.ROSTER_MAX + 5 do many["u" .. string.format("%04d", index)] = "N" end
            test.eq(#network.roster(many).p, network.ROSTER_MAX)
        end)

        test.it("judges each node: fresh, then unknown while still a member, gone only when the membership says so", function()
            local state: any = {nodes = {}}
            assert(network.heard(state, "node-b", network.roster({["u-z"] = "Zoe"}), 100))
            local both = {["node-a"] = true, ["node-b"] = true}
            test.eq(network.judge(state, "node-b", 100, both), "fresh")
            test.eq(network.judge(state, "node-b", 100 + network.FRESH_S - 1, both), "fresh")
            test.eq(network.judge(state, "node-b", 100 + network.FRESH_S, both), "unknown",
                "no news is not offline: pg skips a node silently while its breaker is open")
            test.eq(network.judge(state, "node-b", 100 + 10000, both), "unknown", "a timer never ends a member")
            test.eq(network.judge(state, "node-b", 100, {["node-a"] = true}), "gone")
            test.eq(network.judge(state, "node-b", 100 + 10000, nil), "unknown", "membership not read: nothing gone")
            test.eq(network.judge(state, "node-c", 100, both), "gone", "not a member")
            test.eq(network.judge(state, "node-c", 100, {["node-c"] = true}), "unknown", "a member not heard yet")
            network.forget(state, 200, {["node-a"] = true})
            test.is_nil(state.nodes["node-b"], "a node that left is forgotten")
        end)

        test.it("the nodes that count are in the cluster and in the group; either alone decides when the other is unread", function()
            local cluster = {{id = "node-a"}, {id = "node-b"}, {id = "node-c"}}
            local group = {"{node-a@app:processes|0x00010}", "{node-b@app:processes|0x00011}", "{node-d@app:processes|0x1}"}
            local function listed(set: any): string
                if set == nil then return "nil" end
                local out = {}
                for node in pairs(set) do out[#out + 1] = node end
                table.sort(out)
                return table.concat(out, ",")
            end
            test.eq(listed(network.members(cluster, group)), "node-a,node-b")
            test.eq(listed(network.members(nil, group)), "node-a,node-b,node-d")
            test.eq(listed(network.members(cluster, nil)), "node-a,node-b,node-c")
            test.eq(listed(network.members(nil, nil)), "nil")
            test.eq(network.node_of("{node-b@app:processes|0x00011}"), "node-b")
        end)

        test.it("tells a window everyone elsewhere: online or unknown, never this node, never a gone node", function()
            local state: any = {nodes = {}}
            assert(network.heard(state, "node-a", network.roster({["u-me"] = "Me"}), 100))
            assert(network.heard(state, "node-b", network.roster({["u-zoe"] = "Zoe", ["u-yan"] = "Yan"}), 100))
            assert(network.heard(state, "node-c", network.roster({["u-ida"] = "Ida"}), 50))
            local members = {["node-a"] = true, ["node-b"] = true, ["node-c"] = true}
            local view = network.view(state, "node-a", 100, members)
            local lines = {}
            for _, person in ipairs(view.people) do lines[#lines + 1] = person.id .. "=" .. person.state end
            test.eq(table.concat(lines, ","), "net:node-c:u-ida=unknown,net:node-b:u-yan=online,net:node-b:u-zoe=online")
            test.eq(tostring(view.nodes["node-b"]) .. "," .. tostring(view.nodes["node-c"]) .. "," .. tostring(view.nodes["node-a"]),
                "fresh,unknown,nil")

            test.eq(table.concat({network.status_in(view, "net:node-b:u-zoe")}, "|"), "online|Zoe")
            test.eq(table.concat({network.status_in(view, "net:node-b:u-gone")}, "|"), "offline",
                "a fresh roster without them: they logged off")
            test.eq(table.concat({network.status_in(view, "net:node-c:u-ida")}, "|"), "unknown|Ida")
            test.eq(table.concat({network.status_in(view, "net:node-x:u")}, "|"), "offline", "a node that is not there")
            test.eq(table.concat({network.status_in(nil, "net:node-b:u-zoe")}, "|"), "unknown", "presence not read")

            local gone = network.view(state, "node-a", 100, {["node-a"] = true, ["node-b"] = true})
            for _, person in ipairs(gone.people) do test.is_false(person.node == "node-c", "a gone node's people leave") end
            test.is_nil(gone.nodes["node-c"])
        end)

        test.it("a message goes out as the recipient's id THERE, and comes in with the sender's node from the process", function()
            local row = {id = "m1", from_id = "u-anna", to_id = "net:node-b:zoe@example.com", body = "hi"}
            local body = assert(network.delivery(row, "Anna Karenina"))
            test.is_true(safe(body))
            test.eq(table.concat({body.i, body.f, body.t, body.b, body.m}, "|"), "m1|u-anna|zoe@example.com|hi|Anna Karenina")
            test.is_nil((network.delivery({id = "m2", from_id = "u-anna", to_id = "u-bob", body = "x"})),
                "a message between two people here is not sent anywhere")
            test.is_nil((network.delivery({id = "m3", from_id = "net:node-c:u", to_id = "net:node-b:u", body = "x"})),
                "a message from another computer is not sent on")

            -- A body that names a node is not believed: the node is the sending process's.
            local forged = {i = "m1", f = "u-anna", t = "zoe@example.com", b = "hi", m = "Anna", n = "node-c"}
            local row_in = assert(network.accept("node-b", forged, "node-a"))
            test.eq(row_in.from_id, "net:node-b:u-anna")
            test.eq(row_in.to_id .. "|" .. row_in.body .. "|" .. row_in.name, "zoe@example.com|hi|Anna")
            local function why(node: any, given: any): string
                local _, reason = network.accept(node, given, "node-a")
                return tostring(reason)
            end
            test.eq(why("node-a", forged), "a computer does not deliver to itself")
            test.eq(why("node:b", forged), "the node's name node:b cannot take part")
            test.eq(why("node-b", {f = "u", t = "v", b = "x"}), "a delivery without a message id")
            test.eq(why("node-b", {i = "m", t = "v", b = "x"}), "a delivery without a sender")
            test.eq(why("node-b", {i = "m", f = "u", t = "net:node-c:v", b = "x"}), "a delivery without a recipient here")
            test.eq(why("node-b", {i = "m", f = "u", t = "v", b = ""}), "a delivery without a text")
            test.eq(why("node-b", {i = "m", f = "u", t = "v", b = string.rep("x", network.BODY_MAX * 4 + 1)}),
                "a text longer than the sender's limit")

            test.is_true(network.acked("node-b", {to_id = "net:node-b:u"}))
            test.is_false(network.acked("node-c", {to_id = "net:node-b:u"}), "only the node it was for confirms it")
            test.is_false(network.acked("node-b", {to_id = "u-bob"}))
            test.eq(network.messenger_name("node-b"), "chicago.aicq.messenger@node-b")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
