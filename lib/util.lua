local json = require("json")

local M = {
    NULL = json.decode("null"),
}

function M.trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.opt(ctx, key)
    local value = ctx.options and ctx.options[key]
    if value == nil or value == M.NULL then
        return nil
    end
    return tostring(value)
end

function M.truthy(value, default)
    if value == nil then
        return default
    end
    value = tostring(value):lower()
    return value == "true" or value == "1" or value == "yes" or value == "on"
end

function M.urlencode(value)
    return (
        tostring(value):gsub("([^%w%-%._~])", function(c)
            return string.format("%%%02X", string.byte(c))
        end)
    )
end

local function glob_to_lua(glob)
    local out = { "^" }
    for i = 1, #glob do
        local c = glob:sub(i, i)
        if c == "*" then
            table.insert(out, ".*")
        elseif c == "?" then
            table.insert(out, ".")
        elseif c:match("[%^%$%(%)%%%.%[%]%+%-]") then
            table.insert(out, "%" .. c)
        else
            table.insert(out, c)
        end
    end
    table.insert(out, "$")
    return table.concat(out)
end

function M.glob_match(name, pattern)
    return name:match(glob_to_lua(pattern)) ~= nil
end

function M.substitute_version(pattern, version)
    pattern = pattern:gsub("{{version}}", function()
        return version
    end)
    pattern = pattern:gsub("{version}", function()
        return version
    end)
    return pattern
end

function M.is_auxiliary_jar(name)
    local lower = name:lower()
    return lower:find("sources", 1, true) ~= nil
        or lower:find("javadoc", 1, true) ~= nil
        or lower:find("-tests", 1, true) ~= nil
        or lower:find("-test.", 1, true) ~= nil
end

return M
