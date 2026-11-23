local http = require("http")
local json = require("json")
local util = require("util")
local spec_mod = require("spec")

local M = {}

local function api_headers(ctx, forge)
    local headers = { ["Accept"] = "application/json" }
    local token = util.opt(ctx, "token")
    if forge == "github" then
        headers["Accept"] = "application/vnd.github+json"
        headers["X-GitHub-Api-Version"] = "2022-11-28"
        if token then
            headers["Authorization"] = "Bearer " .. token
        end
    elseif forge == "gitlab" then
        if token then
            headers["PRIVATE-TOKEN"] = token
        end
    elseif forge == "forgejo" then
        if token then
            headers["Authorization"] = "token " .. token
        end
    end
    return headers
end

local function api_get(ctx, url)
    local forge = spec_mod.forge(ctx, {})
    local resp = http.get({ url = url, headers = api_headers(ctx, forge) })
    if resp.status_code ~= 200 then
        error("API returned HTTP " .. resp.status_code .. " for " .. url)
    end
    local data = json.decode(resp.body)
    if type(data) == "table" and data.message ~= nil and data.message ~= util.NULL then
        error("API error for " .. url .. ": " .. tostring(data.message))
    end
    return data
end

local function try_api_get(ctx, url)
    local forge = spec_mod.forge(ctx, {})
    local resp = http.get({ url = url, headers = api_headers(ctx, forge) })
    if resp.status_code == 404 then
        return nil
    elseif resp.status_code ~= 200 then
        error("API returned HTTP " .. resp.status_code .. " for " .. url)
    end
    return json.decode(resp.body)
end

local function normalize_release(release, forge)
    if forge ~= "gitlab" then
        return release
    end
    local assets = {}
    local links = {}
    if release.assets and type(release.assets.links) == "table" then
        links = release.assets.links
    end
    for _, link in ipairs(links) do
        local url = link.direct_asset_url
        if type(url) ~= "string" then
            url = link.url
        end
        local name = link.name
        if type(name) ~= "string" or name == "" then
            name = type(url) == "string" and url:match("([^/]+)$") or nil
        end
        if name and name ~= "" then
            table.insert(assets, {
                name = name,
                browser_download_url = url,
                size = link.size,
            })
        end
    end
    return {
        tag_name = release.tag_name,
        draft = false,
        prerelease = release.upcoming_release and true or false,
        published_at = release.released_at,
        assets = assets,
    }
end

function M.list_releases(ctx, spec)
    local forge = spec_mod.forge(ctx, spec)
    local api = spec_mod.api_url(ctx, spec)
    local releases = {}
    for page = 1, 3 do
        local url
        local limit
        if forge == "gitlab" then
            url = api .. "/projects/" .. util.urlencode(spec.repo) .. "/releases?per_page=100&page=" .. page
            limit = 100
        elseif forge == "forgejo" then
            url = api .. "/repos/" .. spec.repo .. "/releases?limit=50&page=" .. page
            limit = 50
        else
            url = api .. "/repos/" .. spec.repo .. "/releases?per_page=100&page=" .. page
            limit = 100
        end
        local batch = api_get(ctx, url)
        if #batch == 0 then
            break
        end
        for _, release in ipairs(batch) do
            table.insert(releases, normalize_release(release, forge))
        end
        if #batch < limit then
            break
        end
    end
    return releases
end

function M.find_release(ctx, spec, version)
    local forge = spec_mod.forge(ctx, spec)
    local api = spec_mod.api_url(ctx, spec)
    if version == "latest" then
        if forge == "gitlab" then
            local releases = M.list_releases(ctx, spec)
            if #releases > 0 then
                return releases[1]
            end
        else
            local release = try_api_get(ctx, api .. "/repos/" .. spec.repo .. "/releases/latest")
            if release then
                return normalize_release(release, forge)
            end
        end
    end

    local prefix = spec_mod.version_prefix(ctx, spec)
    local tags = {}
    if prefix == "" then
        table.insert(tags, version)
    elseif prefix ~= nil then
        table.insert(tags, prefix .. version)
    else
        table.insert(tags, "v" .. version)
        table.insert(tags, version)
    end
    for _, tag in ipairs(tags) do
        local url
        if forge == "gitlab" then
            url = api .. "/projects/" .. util.urlencode(spec.repo) .. "/releases/" .. util.urlencode(tag)
        else
            url = api .. "/repos/" .. spec.repo .. "/releases/tags/" .. util.urlencode(tag)
        end
        local release = try_api_get(ctx, url)
        if release then
            return normalize_release(release, forge)
        end
    end

    for _, release in ipairs(M.list_releases(ctx, spec)) do
        if spec_mod.normalize_tag(release.tag_name or "", prefix) == version then
            return release
        end
    end
    error(
        "no release for "
            .. spec.repo
            .. "@"
            .. version
            .. " on "
            .. forge
            .. " (tag prefix: "
            .. tostring(prefix)
            .. ")"
    )
end

local function is_jar(name)
    return name:lower():sub(-4) == ".jar"
end

local function is_archive(name)
    local lower = name:lower()
    return lower:sub(-4) == ".zip"
        or lower:sub(-7) == ".tar.gz"
        or lower:sub(-4) == ".tgz"
        or lower:sub(-7) == ".tar.xz"
        or lower:sub(-8) == ".tar.bz2"
end

local function is_checksum(name)
    local lower = name:lower()
    return lower:match("%.sha%d+$") ~= nil
        or lower:match("%.sha%d+%.%w+$") ~= nil
        or lower:match("%.md5$") ~= nil
        or lower:match("%.asc$") ~= nil
        or lower:match("%.sig$") ~= nil
        or lower:match("%.pem$") ~= nil
        or lower:match("%.minisig$") ~= nil
        or lower:find("checksums", 1, true) ~= nil
        or lower:find("sha256sums", 1, true) ~= nil
        or lower:find("sha512sums", 1, true) ~= nil
end

local function asset_names(assets)
    local names = {}
    for _, asset in ipairs(type(assets) == "table" and assets or {}) do
        table.insert(names, asset.name)
    end
    return names
end

local function ambiguous(kind, names, hint)
    local lines = {
        "multiple " .. kind .. " matched:",
    }
    for _, name in ipairs(names) do
        table.insert(lines, "  - " .. name)
    end
    table.insert(lines, hint)
    error(table.concat(lines, "\n"))
end

function M.select_asset(ctx, spec, release, version)
    local assets = type(release.assets) == "table" and release.assets or {}
    local pattern = util.opt(ctx, "asset") or util.opt(ctx, "asset_pattern") or spec.asset
    local matching = util.opt(ctx, "matching")

    if pattern then
        pattern = util.substitute_version(pattern, version)
        local matches = {}
        local exact = nil
        for _, asset in ipairs(assets) do
            if asset.name == pattern then
                exact = asset
            end
            if util.glob_match(asset.name, pattern) then
                table.insert(matches, asset)
            end
        end
        if exact then
            return exact
        elseif #matches == 1 then
            return matches[1]
        elseif #matches == 0 then
            error("asset pattern '" .. pattern .. "' matched none of:\n  " .. table.concat(asset_names(assets), "\n  "))
        else
            ambiguous(
                "release asset for " .. spec.repo .. "@" .. version,
                asset_names(matches),
                "Set asset to one exact name (or a narrower glob) in mise.toml."
            )
        end
    end

    local candidates = {}
    for _, asset in ipairs(assets) do
        local name = asset.name
        local selected = (is_jar(name) or is_archive(name)) and not is_checksum(name)
        if matching and not name:find(matching, 1, true) then
            selected = false
        end
        if selected then
            table.insert(candidates, asset)
        end
    end

    local jars = {}
    local archives = {}
    for _, asset in ipairs(candidates) do
        if is_jar(asset.name) and not util.is_auxiliary_jar(asset.name) then
            table.insert(jars, asset)
        elseif is_archive(asset.name) then
            table.insert(archives, asset)
        end
    end

    if #jars == 1 then
        return jars[1]
    elseif #jars > 1 then
        ambiguous(
            "JAR asset for " .. spec.repo .. "@" .. version,
            asset_names(jars),
            'Set asset = "the-one.jar" (or a glob matching only it).'
        )
    elseif #archives == 1 then
        return archives[1]
    elseif #archives > 1 then
        ambiguous(
            "archive asset for " .. spec.repo .. "@" .. version,
            asset_names(archives),
            'Set asset = "the-one.zip" (or a glob matching only it).'
        )
    end

    error(
        "no .jar or supported archive asset for "
            .. spec.repo
            .. "@"
            .. version
            .. ":\n  "
            .. table.concat(asset_names(assets), "\n  ")
    )
end

return M
