-- aICQ's "Add Agent" — in place of ICQ's "Add Users": create a new agent
-- without leaving for the browser. A dialog on the shell's SDK; creating and
-- the list of models are the data layer `chicago.aicq:agents`, that is, the same
-- libraries and gates as the web page "Agents".
--
-- The window's argument is the contact list's pid: after a success
-- `agents.ADDED` goes there, and the list reads the agents again. Without an
-- argument the dialog just closes. A refusal is a line above the buttons, in
-- the library's words; the window stays open.
local app = require("app")
local editor = require("editor")
local agents = require("agents")

local definition = {}

-- The data layer through a table: a test replaces it.
definition.deps = {agents = agents}

local LABEL = 14

local IDS = {title = "f_title", description = "f_description", model = "f_model", prompt = "f_prompt",
    ok = "ok", cancel = "cancel"}
definition.IDS = IDS

local function field(caption: string, control: any): any
    return {kind = "row", size = 2, gap = 1, children = {
        {kind = "label", size = LABEL, text = caption},
        control,
    }}
end

function definition.init(args: any, context: any): any
    local data: any = definition.deps.agents
    local opener = tostring(args or ""):match("^%s*(.-)%s*$") or ""
    local model: any = {title = "", description = "", model = nil, options = {},
        opener = opener ~= "" and opener or nil, status = nil, failure = false,
        granted = data.granted("create")}
    local options, err = data.models()
    if options then
        model.options = options
        model.model = options[1] and options[1].value or nil
        if #options == 0 then model.status, model.failure = "no models to choose from", true end
    else
        model.status, model.failure = tostring(err), true
    end
    if not model.granted then model.status, model.failure = data.not_granted("create"), true end
    return model
end

function definition.view(model: any, context: any): any
    local ready = model.granted and model.model ~= nil
    return {kind = "column", padding = 1, padding_bottom = 0, gap = 0, children = {
        field("Name *:", {kind = "input", id = IDS.title, text = model.title}),
        field("Description:", {kind = "input", id = IDS.description, text = model.description}),
        field("Model *:", {kind = "select", id = IDS.model, value = model.model, options = model.options,
            disabled = #model.options == 0}),
        {kind = "label", size = 1, text = "System prompt:"},
        {kind = "editor", id = IDS.prompt, text = "", font = "mono", wrap = true},
        -- The library's refusal can be long ("An agent named '…' already exists.
        -- Pick a different name."): two lines, wrapped.
        {kind = "label", size = 2, wrap = true, text = model.status or "", alert = model.failure == true},
        {kind = "row", size = 2, gap = 1, align = "right", children = {
            {kind = "button", id = IDS.ok, size = 10, text = "OK", default = true, disabled = not ready},
            {kind = "button", id = IDS.cancel, size = 10, text = "Cancel"},
        }},
    }}
end

local function submit(model: any, context: any)
    local data: any = definition.deps.agents
    if not model.granted then
        model.status, model.failure = data.not_granted("create"), true
        return
    end
    local agent, err = data.create({title = model.title, description = model.description, model = model.model,
        prompt = editor.text(context.editor(IDS.prompt))})
    if not agent then
        model.status, model.failure = tostring(err), true
        return
    end
    if model.opener then data.announce(model.opener, agent) end
    context.close()
end

function definition.update(model: any, action: any, context: any): any
    if action.type == "change" then
        -- The input field takes its text from the tree: a skipped frame would lose
        -- letters, so the answer here is "redraw" (nil), not false.
        if action.id == IDS.title then model.title = tostring(action.value or "")
        elseif action.id == IDS.description then model.description = tostring(action.value or "")
        elseif action.id == IDS.model then model.model = action.value end
        return nil
    end
    if action.type == "activate" and (action.id == IDS.ok or action.id == IDS.title) then
        submit(model, context)
        return nil
    end
    if action.type == "activate" and action.id == IDS.cancel then
        context.close()
        return nil
    end
    return false
end

definition.close_on_escape = true

local function main(first: any, id: any, args: any, viewport: any)
    app.run(definition, first, id, args, viewport)
end

return {main = main, definition = definition}
