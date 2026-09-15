-- Harness stand-in for kickside.component:component: the access levels the
-- contact list names, and no components.
local component = {}

component.ACCESS = {READ = 1, WRITE = 2, ADMIN = 3}

function component.get_context(component_id: any, _access: any): (any, string?)
    return nil, "no component " .. tostring(component_id) .. " in the harness (kickside/component stand-in)"
end

return component
