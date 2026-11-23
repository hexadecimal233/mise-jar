local http = require("http")
local cmd = require("cmd")
local log = require("log")
local util = require("util")

local M = {}

function M.digest(path, algo)
    algo = algo or "sha256"
    local out
    if RUNTIME.osType == "darwin" then
        local flag = algo == "sha512" and "-a 512" or algo == "sha1" and "-a 1" or "-a 256"
        out = cmd.exec("shasum " .. flag .. ' "$FILE"', { env = { FILE = path } })
    elseif RUNTIME.osType == "windows" then
        local algorithm = algo == "sha512" and "SHA512" or algo == "sha1" and "SHA1" or "SHA256"
        out = cmd.exec(
            'powershell -NoProfile -Command "(Get-FileHash -Algorithm ' .. algorithm .. ' -LiteralPath $env:FILE).Hash"',
            { env = { FILE = path } }
        )
    else
        local binary = algo == "sha512" and "sha512sum" or algo == "sha1" and "sha1sum" or "sha256sum"
        out = cmd.exec(binary .. ' "$FILE"', { env = { FILE = path } })
    end
    local hash = out:lower():match("(%x+)")
    if not hash then
        error("could not compute " .. algo .. " for " .. path)
    end
    return hash
end

local function parse_checksum_body(body, filename)
    for line in body:gmatch("[^\r\n]+") do
        line = util.trim(line)
        local hash, name = line:match("^(%x+)%s+%*?(.+)$")
        if hash and (#hash == 40 or #hash == 64 or #hash == 128) then
            if name == nil or name == filename then
                return hash
            end
        elseif line:match("^%x+$") and (#line == 40 or #line == 64 or #line == 128) then
            return line
        end
    end
    return nil
end

local function expected_checksum(ctx, release, asset)
    local explicit = util.opt(ctx, "checksum")
    if explicit then
        local algo, hash = explicit:match("^(%w+):(%x+)$")
        if algo then
            return { algo = algo:lower(), hash = hash:lower() }
        end
        return { algo = "sha256", hash = explicit:lower() }
    end

    if asset.digest and asset.digest ~= util.NULL then
        local algo, hash = tostring(asset.digest):match("^(%w+):(%x+)$")
        if algo then
            return { algo = algo:lower(), hash = hash:lower() }
        end
    end

    local wanted = {
        asset.name .. ".sha256",
        asset.name .. ".sha512",
        "SHA256SUMS",
        "SHA256SUMS.txt",
        "checksums.txt",
        "checksums-sha256.txt",
    }
    local release_assets = type(release.assets) == "table" and release.assets or {}
    for _, checksum_name in ipairs(wanted) do
        for _, candidate in ipairs(release_assets) do
            if candidate.name == checksum_name then
                local resp = http.get({ url = candidate.browser_download_url })
                if resp.status_code == 200 then
                    local hash = parse_checksum_body(resp.body, asset.name)
                    if hash then
                        return {
                            algo = #hash == 128 and "sha512" or #hash == 40 and "sha1" or "sha256",
                            hash = hash:lower(),
                        }
                    end
                end
            end
        end
    end
    return nil
end

function M.verify(ctx, release, asset, path)
    local expected = expected_checksum(ctx, release, asset)
    if not expected then
        log.debug("jar: no published checksum for " .. asset.name)
        return
    end
    local actual = M.digest(path, expected.algo)
    if actual ~= expected.hash then
        error("checksum mismatch for " .. asset.name .. ": expected " .. expected.hash .. ", got " .. actual)
    end
end

function M.verify_maven(ctx, spec, url, path)
    local explicit = util.opt(ctx, "checksum")
    local expected
    if explicit then
        local algo, hash = explicit:match("^(%w+):(%x+)$")
        expected = { algo = algo and algo:lower() or "sha256", hash = (hash or explicit):lower() }
    else
        for _, suffix in ipairs({ ".sha256", ".sha1" }) do
            local resp = http.get({ url = url .. suffix })
            if resp.status_code == 200 then
                local hash = resp.body:match("(%x+)")
                if hash then
                    expected = {
                        algo = suffix == ".sha256" and "sha256" or "sha1",
                        hash = hash:lower(),
                    }
                    break
                end
            elseif resp.status_code ~= 404 then
                error("checksum returned HTTP " .. resp.status_code .. " for " .. url .. suffix)
            end
        end
    end
    if not expected then
        log.debug("jar: no Maven checksum for " .. url)
        return
    end
    local actual = M.digest(path, expected.algo)
    if actual ~= expected.hash then
        error("checksum mismatch for " .. path .. ": expected " .. expected.hash .. ", got " .. actual)
    end
end

return M
