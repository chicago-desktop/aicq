-- Reads a sender's name the way the messenger does, under whatever actor and
-- scope the spawner gave this process (notify_test's caller in the shell is
-- the same idea): the point is the rights, not the road.
--
-- The answer is this process's result — {name = …} or {why = …} — so the
-- case that spawned it can say exactly what the policy refused.
local json = require("json")
local people = require("people")

local function main(args: any): any
    local spec: any = json.decode(tostring(args or "")) or {}
    local ok, name, why = pcall(people.name_of, spec.user_id)
    if not ok then return {why = "raised: " .. tostring(name)} end
    if type(name) == "string" and name ~= "" then return {name = name} end
    return {why = tostring(why or "no reason given")}
end

return {main = main}
