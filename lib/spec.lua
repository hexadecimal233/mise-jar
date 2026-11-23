local util = require("util")

local M = {}

function M.spec(ctx)
    local spec = {}
    local overrides = {
        "repo",
        "asset",
        "asset_pattern",
        "jar",
        "command",
        "main_class",
        "strip_components",
        "checksum",
        "version_prefix",
        "prerelease",
        "api_url",
        "maven",
        "maven_repo",
        "classifier",
        "forge",
        "java",
        "java_home",
        "java_opts",
    }
    for _, key in ipairs(overrides) do
        local value = util.opt(ctx, key)
        if value ~= nil then
            spec[key] = value
        end
    end
    local maven = util.opt(ctx, "maven")
    if maven then
        if util.opt(ctx, "repo") then
            error("set either maven or repo, not both")
        end
        if not maven:match("^[%w_.-]+:[%w_.-]+$") then
            error("maven must be group:artifact, got: " .. maven)
        end
        spec.maven = maven
        spec.repo = nil
        spec.maven_repo = util.opt(ctx, "maven_repo") or spec.maven_repo or "https://repo1.maven.org/maven2"
        if not spec.maven_repo:match("^https?://") then
            error("maven_repo must be an http(s) URL, got: " .. spec.maven_repo)
        end
        spec.classifier = util.opt(ctx, "classifier") or spec.classifier
        return spec
    end

    if spec.repo == nil and ctx.tool:find("/", 1, true) then
        spec.repo = ctx.tool
    end
    if spec.repo == nil then
        error("jar:" .. ctx.tool .. ' needs repo="owner/repo" or maven="group:artifact"')
    end
    local forge = M.forge(ctx, spec)
    local repo_pattern = forge == "gitlab" and "^[%w_.-]+/[%w_./-]+$" or "^[%w_.-]+/[%w_.-]+$"
    if not spec.repo:match(repo_pattern) then
        error("repo must look like owner/repo, got: " .. spec.repo)
    end
    return spec
end

function M.command(ctx, spec)
    local command = util.opt(ctx, "command") or spec.command
    if command == nil then
        local base = ctx.tool:match("([^/]+)$") or ctx.tool
        command = base:lower()
    end
    if command == "" or command == "." or command == ".." or not command:match("^[%w_.+-]+$") then
        error("invalid command name: " .. command)
    end
    return command
end

function M.version_prefix(ctx, spec)
    local prefix = util.opt(ctx, "version_prefix")
    if prefix == nil then
        prefix = spec.version_prefix
    end
    return prefix
end

function M.normalize_tag(tag, prefix)
    if prefix == nil then
        return (tag:gsub("^v", ""))
    elseif prefix == "" then
        return tag
    end
    if tag:sub(1, #prefix) ~= prefix then
        return nil
    end
    return tag:sub(#prefix + 1)
end

function M.forge(ctx, spec)
    local forge = util.opt(ctx, "forge") or spec.forge or "github"
    forge = forge:lower()
    if forge == "gitea" then
        forge = "forgejo"
    end
    if forge ~= "github" and forge ~= "gitlab" and forge ~= "forgejo" then
        error("forge must be github, gitlab, or forgejo; got: " .. forge)
    end
    return forge
end

function M.api_url(ctx, spec)
    local forge = M.forge(ctx, spec)
    local default = forge == "github" and "https://api.github.com"
        or forge == "gitlab" and "https://gitlab.com/api/v4"
        or "https://codeberg.org/api/v1"
    local base = util.opt(ctx, "api_url") or spec.api_url or default
    return (base:gsub("/+$", ""))
end

return M
