local M = {}

for _, name in ipairs({ "util", "spec", "maven", "checksum", "releases", "artifact", "wrapper" }) do
    local module = require(name)
    for key, value in pairs(module) do
        M[key] = value
    end
end

return M
