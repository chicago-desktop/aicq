-- Harness stand-in for kickside.agents.traits:roster_list: two reachable
-- agents, whoever asks.
local roster = {}

roster.USER_AGENT_PREFIX = "user_agent:"

function roster.reachable(_actor: any, _query: any): any
    return {{agent_id = "app.agents:writer", title = "Writer"}, {agent_id = "app.agents:scout", title = "Scout"}}
end

return roster
