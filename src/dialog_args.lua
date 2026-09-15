-- Legacy contact-list arguments and structured drafts from other windows.
-- Parsing never sends a message: the person reviews the draft and presses Send.
local json = require("json")
local args = {}
function args.parse(value: any): (any, any)
    local raw = type(value) == "string" and value or ""
    if raw:match("^%s*{") then
        local ok, decoded = pcall(json.decode, raw)
        if not ok or type(decoded) ~= "table" or type(decoded.agent_id) ~= "string" or decoded.agent_id == "" then
            return nil, "Invalid agent conversation arguments."
        end
        if decoded.draft ~= nil and type(decoded.draft) ~= "string" then return nil, "The draft must be text." end
        return {agent = decoded.agent_id, title = type(decoded.title) == "string" and decoded.title or decoded.agent_id,
            draft = decoded.draft or ""}, nil
    end
    local agent, title = raw:match("^(.-)\n(.*)$")
    return {agent = agent or raw, title = title or raw, draft = ""}, nil
end
return args
