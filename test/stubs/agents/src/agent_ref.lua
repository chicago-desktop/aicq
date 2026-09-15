-- Harness stand-in for kickside.agents:agent_ref: the one reference form of a
-- person's agent, `user_agent:<component_id>`.
local agent_ref = {}

agent_ref.USER_AGENT_PREFIX = "user_agent:"

function agent_ref.user(component_id: any): string
    return agent_ref.USER_AGENT_PREFIX .. tostring(component_id)
end

return agent_ref
