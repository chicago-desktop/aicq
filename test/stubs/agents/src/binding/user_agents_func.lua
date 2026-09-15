-- Harness stand-in for kickside.agents.binding:user_agents_func. No suite
-- creates an agent; a call says so rather than pretending to succeed.
local user_agents = {}

function user_agents.create(_input: any): (any, string?)
    return nil, "the harness does not create agents (kickside/agents stand-in)"
end

return user_agents
