local http = require("http")
local util = require("util")

local M = {}

local function parts(spec)
    local group, artifact = spec.maven:match("^([^:]+):([^:]+)$")
    if not group or not artifact then
        error("maven must be group:artifact, got: " .. spec.maven)
    end
    return group, artifact
end

local function base(ctx, spec)
    return (util.opt(ctx, "maven_repo") or spec.maven_repo):gsub("/+$", "")
end

function M.maven_versions(ctx, spec)
    local group, artifact = parts(spec)
    local url = base(ctx, spec) .. "/" .. group:gsub("%.", "/") .. "/" .. artifact .. "/maven-metadata.xml"
    local resp = http.get({ url = url })
    if resp.status_code == 404 then
        error("Maven metadata not found at " .. url)
    elseif resp.status_code ~= 200 then
        error("Maven metadata returned HTTP " .. resp.status_code .. " for " .. url)
    end
    local versions = {}
    for version in resp.body:gmatch("<version>([^<]+)</version>") do
        version = util.trim(version)
        if version ~= "" and version ~= "LATEST" and version ~= "RELEASE" then
            table.insert(versions, version)
        end
    end
    if #versions == 0 then
        error("no versions in " .. url)
    end
    return versions
end

function M.maven_jar(ctx, spec, version)
    local group, artifact = parts(spec)
    if version:find("-SNAPSHOT", 1, true) then
        error("Maven snapshots are not supported; use a release version")
    end

    local classifier = util.opt(ctx, "classifier") or spec.classifier
    local suffix = ""
    if classifier and classifier ~= "" then
        if classifier == "sources" or classifier == "javadoc" then
            error("classifier " .. classifier .. " is not executable; omit classifier or use a CLI/all classifier")
        end
        suffix = "-" .. classifier
    end

    local filename = artifact .. "-" .. version .. suffix .. ".jar"
    local url = base(ctx, spec) .. "/" .. group:gsub("%.", "/") .. "/" .. artifact .. "/" .. version .. "/" .. filename
    return url, filename
end

return M
