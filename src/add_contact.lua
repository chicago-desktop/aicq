-- aICQ's "Add Contact…" — ICQ's "Add/Invite Users": find a person by an
-- e-mail, a name or a UIN, and add them to your contact list.
--
-- All the logic is in `chicago.aicq:aicq` (`find_*`); here are only the window's
-- reads: the people library under the logged-on person's actor, and the news
-- to the contact list whose pid is the window's argument.

local app = require("app")
local process = require("process")
local people = require("people")
local aicq = require("aicq")

local sys = {}

function sys.find(query: any): (any, any)
    local found, err = people.find(query)
    return found, err
end

function sys.add(user_id: any): (any, any)
    local done, err = people.add(user_id)
    return done, err
end

function sys.added(opener: any, user_id: any): (any, any)
    local sent, err = process.send(tostring(opener), aicq.CONTACT_ADDED, {user_id = user_id})
    return sent, err
end

local definition = {}

definition.close_on_escape = true

function definition.init(args: any, context: any): any
    local model = aicq.find_init(sys, args, context)
    return model
end

function definition.view(model: any, context: any): any
    local tree = aicq.find_view(model)
    return tree
end

function definition.update(model: any, action: any, context: any): any
    local changed = aicq.find_update(model, action, context)
    return changed
end

local function main(first: any, id: any, args: any, viewport: any)
    app.run(definition, first, id, args, viewport)
end

return {main = main, definition = definition}
