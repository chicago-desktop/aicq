-- Harness stand-in for kickside.models:model_catalog: no models.
local catalog = {}

function catalog.get_all(_options: any): (any, string?)
    return {}, nil
end

return catalog
