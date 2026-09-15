-- aICQ's Add Contact: the search field, the results table (Name, UIN), Add by
-- the button, by Enter on a row and by a second click, the news to the list,
-- the people library's refusals in its own words, and the layout — through
-- the model `windows.aicq:aicq` (`find_*`) with a stand-in `sys`.
local test = require("test")
local ui = require("ui")
local app = require("app")
local aicq = require("aicq")

local F = aicq.FIND
local LIST = "<pid.list>"
local ANNA = {id = "u-anna", name = "Anna", uin = "123456789"}
local ANDREW = {id = "u-andrew", name = "Andrew", uin = "987654321"}

local function stand_in(over: any?): any
    local given: any = over or {}
    local sys: any = {given = given, calls = {find = {}, add = {}, added = {}}}
    function sys.find(query: any): (any, any)
        sys.calls.find[#sys.calls.find + 1] = query
        if given.find_error then return nil, given.find_error end
        if query == "anna@example.com" then return {ANNA}, nil end
        if query == "and" then return {ANDREW, ANNA}, nil end
        return {}, nil
    end
    function sys.add(user_id: any): (any, any)
        sys.calls.add[#sys.calls.add + 1] = user_id
        if given.add_error then return nil, given.add_error end
        return true, nil
    end
    function sys.added(opener: any, user_id: any): (any, any)
        sys.calls.added[#sys.calls.added + 1] = tostring(opener) .. "|" .. tostring(user_id)
        return true, nil
    end
    return sys
end

local function node(tree: any, id: string): any
    local function walk(item: any): any
        if item.id == id then return item end
        for _, inner in ipairs(item.children or {}) do
            local found = walk(inner)
            if found then return found end
        end
        return nil
    end
    return walk(tree)
end

local function search(model: any, ctx: any, query: string)
    aicq.find_update(model, {type = "change", id = F.query, value = query}, ctx)
    aicq.find_update(model, {type = "activate", id = F.query, value = query}, ctx)
end

local LEAVES: any = {button = true, label = true, input = true, table = true}

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
    test.describe("aICQ Add Contact", function()
        test.it("starts with the hint and the field focused; an empty query asks nothing", function()
            local sys = stand_in()
            local ctx = app.context({width = 48, height = 17})
            local model = aicq.find_init(sys, LIST, ctx)
            test.eq(ctx.interaction.focus, F.query)
            test.eq(model.status, aicq.FIND_HINT)
            local tree = aicq.find_view(model)
            test.is_nil(ui.problem(tree))
            test.is_true(node(tree, F.add).disabled and node(tree, F.add).default, "Add is the default, off until someone is chosen")
            aicq.find_update(model, {type = "activate", id = F.find}, ctx)
            search(model, ctx, "   ")
            test.eq(#sys.calls.find, 0, "a blank query is not sent")
            test.eq(model.status, aicq.FIND_HINT)
        end)

        test.it("a search fills Name and UIN and selects the first; nobody found says so; a refusal is the library's words", function()
            local sys = stand_in()
            local ctx = app.context({width = 48, height = 17})
            local model = aicq.find_init(sys, LIST, ctx)
            search(model, ctx, "  anna@example.com ")
            test.eq(sys.calls.find[1], "anna@example.com", "the query goes trimmed")
            local results = node(aicq.find_view(model), F.results)
            test.eq(results.columns[1].title .. "|" .. results.columns[2].title, "Name|UIN")
            test.eq(results.rows[1].id .. "|" .. results.rows[1].cells[1] .. "|" .. results.rows[1].cells[2], "u-anna|Anna|123456789")
            test.eq(model.selected, "u-anna", "the only one is chosen")
            test.is_false(node(aicq.find_view(model), F.add).disabled)
            test.eq(model.status, "1 person found; Add puts the selected one in your list.")
            aicq.find_update(model, {type = "change", id = F.query, value = "and"}, ctx)
            aicq.find_update(model, {type = "activate", id = F.find}, ctx)
            test.eq(#node(aicq.find_view(model), F.results).rows, 2, "Find searches as Enter does")
            test.eq(model.status, "2 people found; Add puts the selected one in your list.")
            search(model, ctx, "zz9")
            test.eq(model.status, "Nobody found for \"zz9\".")
            test.is_nil(model.selected)
            test.is_false(model.alert)
            local strict = aicq.find_init(stand_in({find_error = "a name needs three letters or more"}), LIST, ctx)
            search(strict, ctx, "an")
            test.eq(strict.status, "a name needs three letters or more")
            test.is_true(strict.alert and node(aicq.find_view(strict), "results") ~= nil)
            test.eq(#strict.results, 0)
        end)

        test.it("adds by Add, by Enter on a row and by a second click on the chosen row; the list hears of it", function()
            local sys = stand_in()
            local ctx = app.context({width = 48, height = 17})
            local model = aicq.find_init(sys, LIST, ctx)
            search(model, ctx, "and")
            aicq.find_update(model, {type = "activate", id = F.add}, ctx)
            test.eq(table.concat(sys.calls.add, ","), "u-andrew", "Add adds the chosen one")
            test.eq(table.concat(sys.calls.added, ","), LIST .. "|u-andrew", "and tells the list that opened the dialog")
            test.eq(model.status, "Andrew is in your contact list now.")
            local anna = node(aicq.find_view(model), F.results).rows[2]
            aicq.find_update(model, {type = "select", id = F.results, index = 2, value = anna, pointer = true}, ctx)
            test.eq(#sys.calls.add, 1, "the first click chooses")
            test.eq(model.selected, "u-anna")
            aicq.find_update(model, {type = "select", id = F.results, index = 2, value = anna, pointer = true}, ctx)
            test.eq(sys.calls.add[2], "u-anna", "the second adds")
            aicq.find_update(model, {type = "select", id = F.results, index = 2, value = anna}, ctx)
            test.eq(#sys.calls.add, 2, "a key choosing it again does not")
            aicq.find_update(model, {type = "activate", id = F.results, index = 2, value = anna}, ctx)
            test.eq(sys.calls.add[3], "u-anna", "Enter on the row adds")
            test.is_false(ctx.closing, "the dialog stays for the next one")
            aicq.find_update(model, {type = "activate", id = F.close}, ctx)
            test.is_true(ctx.closing, "Close closes it")

            local refusing = stand_in({add_error = "already in your list"})
            local stubborn = aicq.find_init(refusing, LIST, ctx)
            search(stubborn, ctx, "anna@example.com")
            aicq.find_update(stubborn, {type = "activate", id = F.add}, ctx)
            test.eq(stubborn.status, "Anna was not added: already in your list")
            test.is_true(stubborn.alert)
            test.eq(#refusing.calls.added, 0, "nothing to tell the list")
            local lone = stand_in()
            local alone = aicq.find_init(lone, "", ctx)
            search(alone, ctx, "anna@example.com")
            aicq.find_update(alone, {type = "activate", id = F.add}, ctx)
            test.eq(#lone.calls.add .. "/" .. #lone.calls.added, "1/0", "no list opened it: added, nobody told")
        end)

        test.it("lays the dialog out without overlaps: the field and Find, the table, the status, Add and Close at the right", function()
            local ctx = app.context({width = 48, height = 17})
            local model = aicq.find_init(stand_in(), LIST, ctx)
            search(model, ctx, "and")
            local plan = ui.plan(aicq.find_view(model), 48, 17, ctx.interaction)
            test.eq(clash(plan, 48, 17), "none")
            local query, find = plan.by_id[F.query].rect, plan.by_id[F.find].rect
            local results, add, close = plan.by_id[F.results].rect, plan.by_id[F.add].rect, plan.by_id[F.close].rect
            test.is_true(query.y == find.y and query.x + query.w <= find.x, "Find right of the field")
            test.is_true(results.y > query.y and add.y > results.y, "the table between them and the buttons")
            test.is_true(results.h >= 6, "the table has room for results")
            test.is_true(add.x + add.w <= close.x and close.x + close.w == 48, "Add, then Close at the right edge")
        end)
    end)
end

local run_cases = test.run_cases(define_tests)
return {run = function(options) return run_cases(options) end}
