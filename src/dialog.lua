-- The dialog with an agent: the log of turns above, the input line below.
--
-- The conversation is run by the stock session process
-- `wippy.session.process:session` — the same one the web chat and the
-- channel bridge use. The window raises it under its own frame (the logged-on
-- user's actor), sends the turns and listens to events on its own inbox:
-- chunks arrive as a stream, `content` carries the full text, and `update`
-- with the status idle means the turn is over. The window invents none of
-- this: the shape of the events is `wippy.session:consts`.
--
-- The window's argument is "<agent_id>\n<title>": the contact list opens the
-- dialog with the agent's name, and the window has no reason to look it up
-- in the registry again.

local app = require("app")
local dialog_args = require("dialog_args")
local editor = require("editor")
local channel = require("channel")
local json = require("json")
local process = require("process")
local security = require("security")
local uuid = require("uuid")
local text = require("text")
local session_service = require("session_service")
local session_consts = require("session_consts")

local definition = {}

local function trim(value: any): string
    if type(value) ~= "string" then return "" end
    return (value:gsub("^%s*(.-)%s*$", "%1"))
end

-- The session's configuration, as the channel bridge's: the base fields from
-- the sessions module's environment plus the agent. agent_id goes in config,
-- not in the process's arguments: that is how the session process is built.
local function session_config(agent_id: string): any
    local base: any = session_consts.get_config()
    return {
        token_checkpoint_threshold = base.token_checkpoint_threshold,
        max_message_limit = base.max_message_limit,
        checkpoint_function_id = base.checkpoint_function_id,
        title_function_id = base.title_function_id,
        delegation_func_id = base.delegation_func_id,
        enable_agent_cache = base.enable_agent_cache,
        delegation_description_suffix = base.delegation_description_suffix,
        agent_id = agent_id,
    }
end

-- Raise the session. A refusal of any kind becomes the status line, not an
-- empty window: under the service actor (a shell without logon) there are no
-- rights to a session, and the person has to read about it, not guess.
local function connect(model: any, context: any): (boolean, string?)
    local actor = security.actor()
    if not actor then return false, "window without an actor: log on to Windows" end
    local user_id = tostring(actor:id())
    local session_id, id_err = uuid.v7()
    if not session_id then return false, "session id: " .. tostring(id_err) end

    -- The host is the session module's (its own requirement default_host); a
    -- guess here would raise the session on a host the application never named.
    local base: any = session_consts.get_config()
    local host: string = type(base.default_host) == "string" and tostring(base.default_host) or ""
    if host == "" then return false, "the session configuration names no process host (wippy.session:default_host)" end

    -- pcall: (ok, result, reason). The service's refusal comes as the second
    -- value, not as an exception, so both are checked.
    local ok, result, ensure_err = pcall(session_service.ensure, {
        session_id = session_id,
        user_id = user_id,
        kind = "CHAT",
        meta = {provider = "tui_desktop"},
        config = session_config(model.agent),
        primary_context_data = {},
    })
    if not ok then return false, "session not created: " .. tostring(result) end
    if type(result) ~= "table" then
        return false, "session not created: " .. tostring(ensure_err or "the session service stayed silent")
    end

    local pid, spawn_err = process.with_context({session_id = session_id, user_id = user_id})
        :spawn_linked_monitored(session_consts.PROCESS.SESSION_ID, host, {
            session_id = session_id,
            user_id = user_id,
            parent_pid = process.pid(),
            create = true,
        })
    if not pid then return false, "session did not start: " .. tostring(spawn_err) end

    model.session_id, model.pid, model.user_id = session_id, pid, user_id
    context.watch(process.inbox())
    context.watch(process.events())
    return true, nil
end

local function push(model: any, role: string, body: string)
    model.messages[#model.messages + 1] = {role = role, text = body}
    model.revision = model.revision + 1
end

-- The log's lines at the list's width. A turn is a heading, "You:" or the
-- agent's name, and the text indented; an empty line between turns. Computed
-- on every frame: the log is short, and a cache by width would drift from the
-- window on resize.
local function lines_for(model: any, width: any): any
    local room = math.max(8, (tonumber(width) or 40) - 3)
    local out = {}
    for _, message in ipairs(model.messages) do
        out[#out + 1] = message.role == "user" and "You:" or (tostring(model.title) .. ":")
        local body = tostring(message.text or "")
        if body == "" and message.role == "agent" then body = "…" end
        for paragraph in (body .. "\n"):gmatch("(.-)\n") do
            local runes: any = text.runes(paragraph)
            if #runes == 0 then out[#out + 1] = "" end
            local at = 1
            while at <= #runes do
                local stop = math.min(#runes, at + room - 3)
                -- Wrap at a space if there is one in the tail of the line.
                if stop < #runes then
                    local cut = stop
                    while cut > at and runes[cut] ~= " " do cut = cut - 1 end
                    if cut > at then stop = cut end
                end
                out[#out + 1] = "  " .. table.concat(runes, "", at, stop)
                at = stop + 1
                while runes[at] == " " do at = at + 1 end
            end
        end
        out[#out + 1] = ""
    end
    return out
end

function definition.init(args: any, context: any): any
    local parsed, parse_error = dialog_args.parse(args)
    local agent, title = parsed and parsed.agent or "", parsed and parsed.title or ""
    local model: any = {
        agent = trim(agent), title = trim(title) ~= "" and trim(title) or trim(agent),
        messages = {}, revision = 0, draft = parsed and parsed.draft or "", busy = false,
        long_draft = parsed and parsed.draft ~= "",
        status = "connecting…", session_id = nil, pid = nil, user_id = nil,
        streaming = nil, -- the index of the agent's turn being written now
    }
    if model.agent == "" then
        model.status = parse_error or "no agent named: open the chat from the contact list"
        return model
    end
    local ok, why = connect(model, context)
    model.status = ok and "ready" or tostring(why)
    return model
end

function definition.view(model: any, context: any): any
    local lines = lines_for(model, context.width)
    local can_send = model.pid ~= nil and not model.busy and trim(model.draft) ~= ""
    return {kind = "column", children = {
        {kind = "list", id = "log", items = lines, reveal = #lines},
        {kind = "row", size = model.long_draft and 7 or 2, gap = 1, children = {
            model.long_draft and {kind = "editor", id = "draft", text = model.draft, wrap = true, read_only = model.pid == nil}
                or {kind = "input", id = "draft", text = model.draft, disabled = model.pid == nil},
            {kind = "button", id = "send", size = 12, text = "Send", default = true, disabled = not can_send},
        }},
        {kind = "label", size = 1, text = model.status},
    }}
end

local function send(model: any)
    local body = trim(model.draft)
    if body == "" or model.busy or not model.pid then return end
    push(model, "user", body)
    push(model, "agent", "")
    model.streaming = #model.messages
    model.draft, model.busy, model.status = "", true, tostring(model.title) .. " is typing…"
    -- conn_pid, so that the chunks come straight here; without it only the
    -- whole `content` arrives at the end of the turn.
    local ok, err = process.send(tostring(model.pid), session_consts.TOPICS.MESSAGE, {
        data = {text = body}, conn_pid = process.pid(),
    })
    if not ok then
        model.busy, model.status = false, "not sent: " .. tostring(err)
    end
end

local function current(model: any): any
    return model.streaming and model.messages[model.streaming] or nil
end

local function on_session_event(model: any, topic: string, payload: any)
    local kind = type(payload) == "table" and payload.type or nil
    local reply = current(model)
    if kind == "chunk" then
        if reply and type(payload.content) == "string" then
            reply.text = reply.text .. payload.content
            model.revision = model.revision + 1
        end
    elseif kind == session_consts.UPSTREAM_TYPES.CONTENT then
        if reply and type(payload.content) == "string" and payload.content ~= "" then
            reply.text = payload.content
            model.revision = model.revision + 1
        end
    elseif kind == session_consts.UPSTREAM_TYPES.UPDATE then
        if payload.status == session_consts.STATUS.IDLE then
            model.busy, model.streaming, model.status = false, nil, "ready"
        elseif type(payload.status) == "string" then
            model.status = tostring(model.title) .. ": " .. payload.status
        end
    elseif kind == session_consts.UPSTREAM_TYPES.ERROR then
        model.busy, model.streaming = false, nil
        model.status = "error: " .. tostring(payload.message or payload.code or "?")
        if reply and reply.text == "" then reply.text = "(no answer)" end
    elseif kind == session_consts.UPSTREAM_TYPES.FUNCTION_CALL then
        model.status = tostring(model.title) .. " is calling " .. tostring(payload.name or payload.function_name or "a tool") .. "…"
    elseif kind == "thinking" then
        model.status = tostring(model.title) .. " is thinking…"
    end
end

function definition.update(model: any, action: any, context: any)
    if action.id == "draft" and action.type == "change" then
        model.draft = model.long_draft and editor.text(context.editor("draft")) or tostring(action.value or "")
    elseif (action.id == "draft" or action.id == "send") and action.type == "activate" then
        if model.long_draft then model.draft = editor.text(context.editor("draft")) end
        send(model)
        if model.long_draft and model.busy then editor.set(context.editor("draft"), "") end
    elseif action.type == "key" and action.key_type == "esc" then
        context.close()
    elseif action.type == "channel" then
        if not action.ok then
            model.status = "the channel closed"
            return
        end
        local value: any = action.value
        if type(value) == "table" then
            -- A process event: the session ended or crashed.
            if (value.kind == process.event.EXIT or value.kind == process.event.LINK_DOWN)
                and model.pid ~= nil and tostring(value.from) == tostring(model.pid) then
                model.pid, model.busy, model.streaming = nil, false, nil
                model.status = "the session ended"
            end
            return
        end
        local ok, topic = pcall(function() return value:topic() end)
        if not ok then return end
        local prefix = session_consts.TOPIC_PREFIXES.SESSION .. tostring(model.session_id)
        if string.sub(tostring(topic), 1, #prefix) ~= prefix then return end
        local decoded, payload = pcall(function() return value:payload():data() end)
        if decoded then on_session_event(model, tostring(topic), payload) end
    end
    -- Everything else (resize, tick): redraw. `false` here would mean a frame of
    -- the old size after the window's size changed.
end

function definition.dispose(model: any, context: any)
    if model.pid then
        pcall(process.send, tostring(model.pid), session_consts.TOPICS.FINISH_AND_EXIT, {})
    end
end

local function main(first: any, id: any, args: any, viewport: any)
    app.run(definition, first, id, args, viewport)
end

return {main = main, definition = definition}
