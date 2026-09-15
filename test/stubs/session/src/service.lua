-- Harness stand-in for wippy.session:service. No suite raises a session; a
-- call says so rather than pretending to succeed.
local service = {}

function service.ensure(_input: any): (any, string?)
    return nil, "the harness raises no sessions (wippy/session stand-in)"
end

return service
