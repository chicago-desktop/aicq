-- The contract's `search`, over the harness's directory adapter.
local directory = require("directory")

local function main(first: any, second: any): any
    local args: any = type(second) == "table" and second or first
    return directory.search(type(args) == "table" and args or {})
end

return {main = main}
