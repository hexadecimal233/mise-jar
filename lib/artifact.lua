local file = require("file")
local archiver = require("archiver")
local cmd = require("cmd")
local util = require("util")

local M = {}

function M.mkdir(path)
    if RUNTIME.osType == "windows" then
        cmd.exec('if not exist "%DIR%" mkdir "%DIR%"', { env = { DIR = path } })
    else
        cmd.exec('mkdir -p "$DIR"', { env = { DIR = path } })
    end
end

function M.remove(path)
    if RUNTIME.osType == "windows" then
        cmd.exec('if exist "%DIR%" rmdir /s /q "%DIR%"', { env = { DIR = path } })
    else
        cmd.exec('rm -rf -- "$DIR"', { env = { DIR = path } })
    end
end

function M.chmod(path)
    if RUNTIME.osType ~= "windows" then
        cmd.exec('chmod 755 "$FILE"', { env = { FILE = path } })
    end
end

function M.find_jars(root)
    local found = {}
    local function walk(dir)
        local ok, entries = pcall(file.list, dir)
        if not ok then
            return
        end
        for _, path in ipairs(entries) do
            local stat = file.stat(path)
            if stat and stat.is_dir and not stat.is_symlink then
                walk(path)
            elseif stat and stat.is_file and path:lower():sub(-4) == ".jar" then
                table.insert(found, path)
            end
        end
    end
    walk(root)
    table.sort(found)
    return found
end

local function parse_manifest(text)
    local lines = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        line = line:gsub("\r$", "")
        if line:sub(1, 1) == " " and #lines > 0 then
            lines[#lines] = lines[#lines] .. line:sub(2)
        else
            table.insert(lines, line)
        end
    end
    local attrs = {}
    for _, line in ipairs(lines) do
        local key, value = line:match("^([^:]+):%s*(.*)$")
        if key then
            attrs[util.trim(key)] = util.trim(value)
        end
    end
    return attrs
end

local function class_exists(root, class_name)
    if not class_name or class_name == "" then
        return false
    end
    local path = class_name:gsub("%.", "/") .. ".class"
    if file.exists(file.join_path(root, path)) then
        return true
    end
    local matches = file.glob(file.join_path(root, "META-INF", "versions", "*", path))
    return #matches > 0
end

function M.inspect_jar(jar, scratch, wanted_class)
    M.remove(scratch)
    local zip = jar .. ".zip"
    os.remove(zip)
    local moved = false
    local ok, err = pcall(function()
        file.move(jar, zip)
        moved = true
        archiver.decompress(zip, scratch, { strip_components = 0 })
    end)
    if moved then
        local restored, restore_err = pcall(file.move, zip, jar)
        if not restored then
            error("could not restore " .. jar .. ": " .. tostring(restore_err))
        end
    end
    if not ok then
        error("could not inspect " .. jar .. ": " .. tostring(err))
    end

    local attrs = {}
    local manifest_path = file.join_path(scratch, "META-INF", "MANIFEST.MF")
    if file.exists(manifest_path) then
        attrs = parse_manifest(file.read(manifest_path))
    end
    local main_class = attrs["Main-Class"]
    local result = {
        attrs = attrs,
        main_class = main_class,
        class_exists = class_exists(scratch, main_class),
        wanted_class = wanted_class,
        wanted_class_exists = class_exists(scratch, wanted_class),
    }
    M.remove(scratch)
    return result
end

local function relative_to(path, root)
    local prefix = root
    if prefix:sub(-1) ~= "/" and prefix:sub(-1) ~= "\\" then
        prefix = prefix .. "/"
    end
    if path:sub(1, #prefix) == prefix then
        return path:sub(#prefix + 1)
    end
    return path
end

local function select_jar_by_option(install_path, option)
    local matches = {}
    for _, jar in ipairs(M.find_jars(install_path)) do
        local rel = relative_to(jar, install_path)
        local base = jar:match("([^/\\]+)$") or jar
        if util.glob_match(rel, option) or util.glob_match(base, option) then
            table.insert(matches, jar)
        end
    end
    if #matches == 0 then
        error("jar pattern '" .. option .. "' matched no .jar under " .. install_path)
    elseif #matches > 1 then
        local lines = { "multiple JAR files matched:" }
        for _, jar in ipairs(matches) do
            table.insert(lines, "  - " .. relative_to(jar, install_path))
        end
        table.insert(lines, 'Set jar = "one exact relative path".')
        error(table.concat(lines, "\n"))
    end
    return matches[1]
end

function M.resolve_jar(ctx, install_path, spec)
    local option = util.opt(ctx, "jar") or spec.jar
    local wanted = util.opt(ctx, "main_class") or spec.main_class
    local scratch_root = file.join_path(ctx.download_path, "inspect")

    if option then
        local jar = select_jar_by_option(install_path, option)
        local info = M.inspect_jar(jar, file.join_path(scratch_root, "explicit"), wanted)
        if wanted then
            if not info.wanted_class_exists then
                error("main_class " .. wanted .. " is not present in " .. jar)
            end
            return jar, wanted, false
        end
        if not info.main_class then
            error(
                jar
                    .. " has no Main-Class in META-INF/MANIFEST.MF; "
                    .. "pass main_class=... if the entry point is elsewhere"
            )
        end
        if not info.class_exists then
            error("Main-Class " .. info.main_class .. " is not present in " .. jar)
        end
        return jar, info.main_class, true
    end

    local jars = {}
    for _, jar in ipairs(M.find_jars(install_path)) do
        if not util.is_auxiliary_jar(relative_to(jar, install_path)) then
            table.insert(jars, jar)
        end
    end
    if #jars == 0 then
        error("no .jar found under " .. install_path)
    end

    local viable = {}
    for index, jar in ipairs(jars) do
        local info = M.inspect_jar(jar, file.join_path(scratch_root, tostring(index)), wanted)
        if wanted then
            if info.wanted_class_exists then
                table.insert(viable, { path = jar, main = wanted, manifest = false })
            end
        elseif info.main_class and info.class_exists then
            table.insert(viable, { path = jar, main = info.main_class, manifest = true })
        end
    end

    if #viable == 1 then
        return viable[1].path, viable[1].main, viable[1].manifest
    elseif #viable > 1 then
        local lines = { "multiple executable JARs matched:" }
        for _, item in ipairs(viable) do
            table.insert(lines, "  - " .. relative_to(item.path, install_path) .. " -> " .. item.main)
        end
        table.insert(lines, 'Set jar = "path/inside/archive.jar" or main_class = "..." in mise.toml.')
        error(table.concat(lines, "\n"))
    end

    local names = {}
    for _, jar in ipairs(jars) do
        table.insert(names, relative_to(jar, install_path))
    end
    if wanted then
        error("none of these JARs contains main_class " .. wanted .. ":\n  " .. table.concat(names, "\n  "))
    end
    error(
        "no JAR with a valid Main-Class was found:\n  "
            .. table.concat(names, "\n  ")
            .. "\nSet jar=... and/or main_class=...."
    )
end

return M
