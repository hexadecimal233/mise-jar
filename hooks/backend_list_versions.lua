local jar = require("jar")
local git_releases = require("git_releases")

function PLUGIN:BackendListVersions(ctx)
    local spec = jar.spec(ctx)
    if spec.maven then
        return { versions = jar.maven_versions(ctx, spec) }
    end

    local prefix = jar.version_prefix(ctx, spec)
    local include_prerelease = jar.truthy(jar.opt(ctx, "prerelease"), false)
    local versions = {}
    local releases = git_releases.list({
        provider = jar.forge(ctx, spec),
        repo = spec.repo,
        api_url = jar.api_url(ctx, spec),
        token = jar.opt(ctx, "token"),
    })

    for _, release in ipairs(releases) do
        local assets = release.assets
        local has_assets = type(assets) == "table" and #assets > 0
        if not release.draft and has_assets and (include_prerelease or not release.prerelease) then
            local version = jar.normalize_tag(release.tag_name or "", prefix)
            if version then
                local entry = { version = version }
                if type(release.published_at) == "string" then
                    entry.created_at = release.published_at
                end
                table.insert(versions, entry)
            end
        end
    end

    if #versions == 0 then
        error("no releases with assets for " .. spec.repo .. " (tag prefix: " .. tostring(prefix) .. ")")
    end

    local oldest_first = {}
    for index = #versions, 1, -1 do
        table.insert(oldest_first, versions[index])
    end
    return { versions = oldest_first }
end
