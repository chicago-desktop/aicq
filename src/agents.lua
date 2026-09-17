-- aICQ's "Add Agent" data layer: create an agent and read the models with
-- THE SAME libraries the handlers of the web page "Agents" call, under the
-- logged-on person's actor. The window writes no rows of its own, to the
-- registry or to the database.
--
-- - Creation — `kickside.agents.binding:user_agents_func.create`, as in
--   `POST /api/v1/user-agents` (`kickside.agents.api:create_user_agent`).
--   `title` and `model` are required; the checks and their wording are the
--   library's, and the window shows its answer as it is.
-- - Models — `kickside.models:model_catalog.get_all`, as in
--   `GET /api/v1/models/list?capability=generate`. The "can generate" filter
--   lives in the handler itself (`list_models.lua`), not in the library, so
--   it is repeated here — `agents.generates`.
-- - Gates. The handlers have no `security.can`: access is checked by the
--   router's firewall (`access` on the handler's id). The window goes past
--   the router, and the group app.security:user has db.get on app:db —
--   without a check of its own the window would bypass the handlers'
--   authorization (the same rule as the "Users" window's).
local security = require("security")
local process = require("process")
local user_agents = require("user_agents")
local catalog = require("catalog")
local agent_ref = require("agent_ref")

local agents = {}

-- The topic on which the dialog tells the contact list about a new agent:
-- `{agent_id = "user_agent:<id>", title}` to the pid it got as its argument.
agents.ADDED = "aicq.agent_added"

agents.GATES = {
    create = "kickside.agents.api:create_user_agent.endpoint",
    models = "kickside.models.api:list_models.endpoint",
}

agents.OP_LABEL = {create = "Add Agent", models = "Models"}

-- Dependencies in a table: a test replaces them without starting the platform's modules.
agents.deps = {security = security, process = process, user_agents = user_agents,
    catalog = catalog, agent_ref = agent_ref}

-- granted(op) -> whether the router's firewall would let this user through to the handler.
function agents.granted(op: string): boolean
    local guard: any = agents.deps.security
    if not guard.actor() then return false end
    return guard.can("access", agents.GATES[op]) == true
end

function agents.not_granted(op: string): string
    return tostring(agents.OP_LABEL[op]) .. ": not granted to your account (" .. tostring(agents.GATES[op]) .. ")"
end

local function has_capability(model: any, cap: string): boolean
    if type(model.capabilities) ~= "table" then return false end
    for _, known in ipairs(model.capabilities) do
        if known == cap then return true end
    end
    return false
end

-- generates(model) -> whether the model goes into the form's list. The rule of
-- `list_models.lua` with capability=generate: it can generate or tool_use (or
-- carries a generate handler) and is not an embedding.
function agents.generates(model: any): boolean
    if type(model) ~= "table" then return false end
    local embedding = model.type == "llm.embedding" or has_capability(model, "embed")
    local can = has_capability(model, "generate") or has_capability(model, "tool_use")
        or (type(model.handlers) == "table" and model.handlers.generate ~= nil)
    return can and not embedding
end

-- models() -> {{value = name, label = title}, …} for the form's `select`, in the
-- catalog's order, or nil and the reason.
function agents.models(): (any, any)
    if not agents.granted("models") then return nil, agents.not_granted("models") end
    local ok, all = pcall(agents.deps.catalog.get_all)
    if not ok then return nil, "models not read: " .. tostring(all) end
    local options: any = {}
    for _, model in ipairs(type(all) == "table" and all or {}) do
        if agents.generates(model) and type(model.name) == "string" and model.name ~= "" then
            options[#options + 1] = {value = model.name, label = tostring(model.title or model.name)}
        end
    end
    return options, nil
end

-- create(form) -> {agent_id, component_id, title} or nil and the refusal —
-- the text the library would give the handler ("title is required", "An agent
-- named '…' already exists. Pick a different name."). `form` holds the web
-- form's fields: `title`, `description`, `model`, `prompt`; the rest (traits,
-- tools) the library takes by default.
function agents.create(form: any): (any, any)
    if not agents.granted("create") then return nil, agents.not_granted("create") end
    local body: any = {title = form.title, description = form.description, model = form.model, prompt = form.prompt}
    local ok, result = pcall(agents.deps.user_agents.create, body)
    if not ok then return nil, tostring(result) end
    if type(result) ~= "table" then return nil, "creation failed" end
    if result.success ~= true then return nil, tostring(result.error or "creation failed") end
    return {agent_id = agents.deps.agent_ref.user(result.component_id), component_id = result.component_id,
        title = form.title}, nil
end

-- announce(pid, agent) -> whether the message about the new agent reached the contact list.
function agents.announce(pid: any, agent: any): boolean
    if type(pid) ~= "string" or pid == "" then return false end
    local sent = agents.deps.process.send(pid, agents.ADDED, {agent_id = agent.agent_id, title = agent.title})
    return sent == true
end

return agents
