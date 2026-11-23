local http = require("http")
local file = require("file")
local archiver = require("archiver")
local jar = require("jar")
local git_releases = require("git_releases")

function PLUGIN:BackendInstall(ctx)
    local spec = jar.spec(ctx)
    local version = ctx.version
    local install_path = ctx.install_path
    file.mkdir(install_path)
    local command = jar.command(ctx, spec)

    if spec.maven then
        local url, filename = jar.maven_jar(ctx, spec, version)
        local download = file.join_path(ctx.download_path, filename)
        http.download_file({ url = url }, download)
        jar.verify_maven(ctx, spec, url, download)
        jar.install_direct_jar(ctx, spec, command, download, filename)
        return {}
    end

    local provider = jar.forge(ctx, spec)
    local api_url = jar.api_url(ctx, spec)
    local token = jar.opt(ctx, "token")
    local release = git_releases.find({
        provider = provider,
        repo = spec.repo,
        version = version,
        tag_prefix = jar.version_prefix(ctx, spec),
        api_url = api_url,
        token = token,
    })
    local asset = git_releases.select_asset({
        release = release,
        pattern = jar.opt(ctx, "asset") or jar.opt(ctx, "asset_pattern") or spec.asset,
        matching = jar.opt(ctx, "matching"),
        version = version,
    })

    if asset.name:find("[/\\]") or asset.name == "." or asset.name == ".." then
        error("refusing unsafe asset name: " .. asset.name)
    end

    local download = file.join_path(ctx.download_path, asset.name)
    git_releases.download_asset({
        provider = provider,
        api_url = api_url,
        token = token,
        asset = asset,
        path = download,
    })
    jar.verify(ctx, release, asset, download)

    if asset.name:lower():sub(-4) == ".jar" then
        jar.install_direct_jar(ctx, spec, command, download, asset.name)
        return {}
    else
        local archive = download
        local lower = asset.name:lower()
        if lower:sub(-4) == ".tgz" then
            archive = download .. ".tar.gz"
            file.move(download, archive)
        end
        local strip = tonumber(jar.opt(ctx, "strip_components") or spec.strip_components or "0")
        if strip ~= 0 and strip ~= 1 then
            error("strip_components must be 0 or 1, got: " .. tostring(strip))
        end
        archiver.decompress(archive, install_path, { strip_components = strip })
        if archive ~= download then
            os.remove(archive)
        end
    end

    local jar_path, main_class, from_manifest = jar.resolve_jar(ctx, install_path, spec)
    jar.write_wrapper(ctx, install_path, command, jar_path, main_class, from_manifest)
    return {}
end
