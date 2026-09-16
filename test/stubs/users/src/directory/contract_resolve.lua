-- The contract's `resolve`, over the harness's directory adapter.
local directory = require("directory")

local function main(first: any, second: any): any
    -- The arguments may arrive alone or after the instance: take the table,
    -- whichever place it comes in.
    local args: any = type(second) == "table" and second or first
    return directory.resolve(type(args) == "table" and args or {})
end

return {main = main}
