local http = require("http")
local json = require("json")
local util = require("util")

local M = {}

local PROVIDERS = {
    github = {
        default_api = "https://api.github.com",
        default_host = "github.com",
        enterprise = "MISE_GITHUB_ENTERPRISE_TOKEN",
        env = { "MISE_GITHUB_TOKEN", "GITHUB_API_TOKEN", "GITHUB_TOKEN" },
    },
    gitlab = {
        default_api = "https://gitlab.com/api/v4",
        default_host = "gitlab.com",
        enterprise = "MISE_GITLAB_ENTERPRISE_TOKEN",
        env = { "MISE_GITLAB_TOKEN", "GITLAB_TOKEN" },
    },
    forgejo = {
        default_api = "https://codeberg.org/api/v1",
        default_host = "codeberg.org",
        enterprise = "MISE_FORGEJO_ENTERPRISE_TOKEN",
        env = { "MISE_FORGEJO_TOKEN", "FORGEJO_TOKEN" },
    },
}

local function host_of(url)
    return (tostring(url):match("^https?://([^/]+)") or ""):lower()
end

local function origin_of(url)
    local scheme, host = tostring(url):match("^(https?)://([^/]+)")
    if scheme and host then
        return scheme .. "://" .. host
    end
    return nil
end

local function normalize_options(opts)
    local provider = (opts.provider or "github"):lower()
    if provider == "gitea" then
        provider = "forgejo"
    end
    local config = PROVIDERS[provider]
    if not config then
        error("provider must be github, gitlab, or forgejo; got: " .. provider)
    end
    local repo = opts.repo
    local api_url = (opts.api_url or config.default_api):gsub("/+$", "")
    return {
        provider = provider,
        repo = repo,
        api_url = api_url,
        token = opts.token,
        version = opts.version,
        tag_prefix = opts.tag_prefix,
        pattern = opts.pattern,
        matching = opts.matching,
        asset = opts.asset,
        path = opts.path,
    }
end

local function resolve_token(opts)
    if opts.token and opts.token ~= "" then
        return opts.token
    end
    local config = PROVIDERS[opts.provider]
    local host = host_of(opts.api_url)
    if host ~= config.default_host and host ~= host_of(config.default_api) then
        local enterprise = os.getenv(config.enterprise)
        if enterprise and enterprise ~= "" then
            return enterprise
        end
    end
    for _, name in ipairs(config.env) do
        local value = os.getenv(name)
        if value and value ~= "" then
            return value
        end
    end
    return nil
end

local function github_http_auth(url)
    local host = host_of(url)
    return host == "api.github.com" or (host:match("^api%.") ~= nil and host:match("%.ghe%.com$") ~= nil)
end

local function headers(opts)
    local result = { ["Accept"] = "application/json" }
    if opts.provider == "github" then
        result["Accept"] = "application/vnd.github+json"
        result["X-GitHub-Api-Version"] = "2022-11-28"
        if not github_http_auth(opts.api_url) then
            local token = resolve_token(opts)
            if token then
                result["Authorization"] = "Bearer " .. token
            end
        end
    else
        local token = resolve_token(opts)
        if token then
            result["Authorization"] = "Bearer " .. token
        end
    end
    return result
end

local function api_get(opts, url)
    local resp = http.get({ url = url, headers = headers(opts) })
    if resp.status_code ~= 200 then
        error("API returned HTTP " .. resp.status_code .. " for " .. url)
    end
    local data = json.decode(resp.body)
    if type(data) == "table" and data.message ~= nil and data.message ~= util.NULL then
        error("API error for " .. url .. ": " .. tostring(data.message))
    end
    return data
end

local function try_api_get(opts, url)
    local resp = http.get({ url = url, headers = headers(opts) })
    if resp.status_code == 404 then
        return nil
    elseif resp.status_code ~= 200 then
        error("API returned HTTP " .. resp.status_code .. " for " .. url)
    end
    return json.decode(resp.body)
end

local function normalize_assets(release, provider)
    local assets = {}
    for _, asset in ipairs(type(release.assets) == "table" and release.assets or {}) do
        local entry = {
            name = asset.name,
            browser_download_url = asset.browser_download_url,
            digest = asset.digest,
            size = asset.size,
        }
        if provider == "github" then
            entry.api_url = asset.url
        end
        table.insert(assets, entry)
    end
    return assets
end

local function normalize_gitlab_release(release)
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
                api_url = link.url,
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

local function normalize_release(release, provider)
    if provider == "gitlab" then
        return normalize_gitlab_release(release)
    end
    return {
        tag_name = release.tag_name,
        draft = release.draft,
        prerelease = release.prerelease,
        published_at = release.published_at,
        assets = normalize_assets(release, provider),
    }
end

function M.list(opts)
    opts = normalize_options(opts)
    if not opts.repo or opts.repo == "" then
        error("repo is required")
    end
    local releases = {}
    for page = 1, 3 do
        local url
        local limit
        if opts.provider == "gitlab" then
            url = opts.api_url .. "/projects/" .. util.urlencode(opts.repo) .. "/releases?per_page=100&page=" .. page
            limit = 100
        elseif opts.provider == "forgejo" then
            url = opts.api_url .. "/repos/" .. opts.repo .. "/releases?limit=50&page=" .. page
            limit = 50
        else
            url = opts.api_url .. "/repos/" .. opts.repo .. "/releases?per_page=100&page=" .. page
            limit = 100
        end
        local batch = api_get(opts, url)
        if #batch == 0 then
            break
        end
        for _, release in ipairs(batch) do
            table.insert(releases, normalize_release(release, opts.provider))
        end
        if #batch < limit then
            break
        end
    end
    return releases
end

function M.find(opts)
    opts = normalize_options(opts)
    if not opts.repo or opts.repo == "" then
        error("repo is required")
    end
    if not opts.version or opts.version == "" then
        error("version is required")
    end

    local prefix = opts.tag_prefix
    if opts.version == "latest" then
        if opts.provider == "gitlab" then
            local releases = M.list(opts)
            if #releases > 0 then
                return releases[1]
            end
        else
            local release = try_api_get(opts, opts.api_url .. "/repos/" .. opts.repo .. "/releases/latest")
            if release then
                return normalize_release(release, opts.provider)
            end
        end
    end

    local tags = {}
    if prefix == "" then
        table.insert(tags, opts.version)
    elseif prefix ~= nil then
        table.insert(tags, prefix .. opts.version)
    else
        table.insert(tags, "v" .. opts.version)
        table.insert(tags, opts.version)
    end
    for _, tag in ipairs(tags) do
        local url
        if opts.provider == "gitlab" then
            url = opts.api_url .. "/projects/" .. util.urlencode(opts.repo) .. "/releases/" .. util.urlencode(tag)
        else
            url = opts.api_url .. "/repos/" .. opts.repo .. "/releases/tags/" .. util.urlencode(tag)
        end
        local release = try_api_get(opts, url)
        if release then
            return normalize_release(release, opts.provider)
        end
    end

    for _, release in ipairs(M.list(opts)) do
        local tag = release.tag_name or ""
        local version
        if prefix == nil then
            version = (tag:gsub("^v", ""))
        elseif prefix == "" then
            version = tag
        elseif tag:sub(1, #prefix) == prefix then
            version = tag:sub(#prefix + 1)
        end
        if version == opts.version then
            return release
        end
    end
    error("no release for " .. opts.repo .. "@" .. opts.version .. " on " .. opts.provider)
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
    local lines = { "multiple " .. kind .. " matched:" }
    for _, name in ipairs(names) do
        table.insert(lines, "  - " .. name)
    end
    table.insert(lines, hint)
    error(table.concat(lines, "\n"))
end

function M.select_asset(opts)
    local release = opts.release
    if not release then
        error("release is required")
    end
    local assets = type(release.assets) == "table" and release.assets or {}
    local pattern = opts.pattern
    local matching = opts.matching

    if pattern then
        pattern = util.substitute_version(pattern, opts.version or "")
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
            ambiguous("release asset", asset_names(matches), "Set pattern to one exact name (or a narrower glob).")
        end
    end

    local candidates = {}
    for _, asset in ipairs(assets) do
        local selected = (is_jar(asset.name) or is_archive(asset.name)) and not is_checksum(asset.name)
        if matching and not asset.name:find(matching, 1, true) then
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
        ambiguous("JAR asset", asset_names(jars), 'Set pattern = "the-one.jar".')
    elseif #archives == 1 then
        return archives[1]
    elseif #archives > 1 then
        ambiguous("archive asset", asset_names(archives), 'Set pattern = "the-one.zip".')
    end

    error("no .jar or supported archive asset:\n  " .. table.concat(asset_names(assets), "\n  "))
end

function M.download_asset(opts)
    opts = normalize_options(opts)
    local asset = opts.asset
    if not asset then
        error("asset is required")
    end
    if not opts.path or opts.path == "" then
        error("path is required")
    end

    local browser_url = asset.browser_download_url
    local api_url = asset.api_url
    local url = browser_url
    local request_headers = {}

    if opts.provider == "github" then
        if api_url then
            url = api_url
            request_headers["Accept"] = "application/octet-stream"
            if not github_http_auth(opts.api_url) then
                local token = resolve_token(opts)
                if token then
                    request_headers["Authorization"] = "Bearer " .. token
                end
            end
        end
    else
        local token = resolve_token(opts)
        local api_origin = origin_of(opts.api_url)
        if token and api_url and origin_of(api_url) == api_origin then
            url = api_url
            request_headers["Authorization"] = "Bearer " .. token
        elseif token and origin_of(browser_url) == api_origin then
            request_headers["Authorization"] = "Bearer " .. token
        end
    end

    http.download_file({ url = url, headers = request_headers }, opts.path)
    return opts.path
end

return M
