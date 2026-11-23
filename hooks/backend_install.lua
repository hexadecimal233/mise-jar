local http = require("http")
local file = require("file")
local archiver = require("archiver")
local jar = require("jar")

function PLUGIN:BackendInstall(ctx)
    local spec = jar.spec(ctx)
    local version = ctx.version
    local install_path = ctx.install_path
    jar.mkdir(install_path)
    local command = jar.command(ctx, spec)

    if spec.maven then
        local url, filename = jar.maven_jar(ctx, spec, version)
        local download = file.join_path(ctx.download_path, filename)
        http.download_file({ url = url }, download)
        jar.verify_maven(ctx, spec, url, download)
        jar.install_direct_jar(ctx, spec, command, download, filename)
        return {}
    end

    local release = jar.find_release(ctx, spec, version)
    local asset = jar.select_asset(ctx, spec, release, version)

    if asset.name:find("[/\\]") or asset.name == "." or asset.name == ".." then
        error("refusing unsafe asset name: " .. asset.name)
    end

    local download = file.join_path(ctx.download_path, asset.name)
    http.download_file({ url = asset.browser_download_url }, download)
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
