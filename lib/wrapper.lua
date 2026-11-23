local file = require("file")
local log = require("log")
local util = require("util")
local artifact = require("artifact")

local M = {}

local function write_file(path, content)
    local handle, err = io.open(path, "wb")
    if not handle then
        error("could not write " .. path .. ": " .. tostring(err))
    end
    handle:write(content)
    handle:close()
end

local function sh_quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function cmd_quote(value)
    return '"' .. tostring(value):gsub('"', '\\"') .. '"'
end

local function option_list(value)
    local result = {}
    if type(value) == "table" then
        for _, item in ipairs(value) do
            table.insert(result, tostring(item))
        end
    elseif value ~= nil and value ~= util.NULL then
        local text = tostring(value)
        if text ~= "" then
            table.insert(result, text)
        end
    end
    return result
end

function M.write_wrapper(ctx, install_path, command, jar_path, main_class, from_manifest)
    local bin_dir = file.join_path(install_path, "bin")
    file.mkdir(bin_dir)
    local jar_rel = jar_path:sub(#install_path + 2)
    local jar_unix = jar_rel:gsub("\\", "/")
    local jar_win = jar_rel:gsub("/", "\\")

    local invoke
    local invoke_win
    if main_class and not from_manifest then
        invoke = '-cp "$JAR" "' .. main_class .. '"'
        invoke_win = '-cp "%~dp0..\\' .. jar_win .. '" "' .. main_class .. '"'
    else
        invoke = '-jar "$JAR"'
        invoke_win = '-jar "%~dp0..\\' .. jar_win .. '"'
    end

    local java = util.opt(ctx, "java")
    local java_home = util.opt(ctx, "java_home")
    local java_opts = util.opt(ctx, "java_opts")
    local args = option_list(ctx.options and ctx.options.args)
    local args_shell = ""
    local args_win = ""
    for _, arg in ipairs(args) do
        args_shell = args_shell .. " " .. sh_quote(arg)
        args_win = args_win .. " " .. cmd_quote(arg)
    end

    local lines = {
        "#!/bin/sh",
        "set -u",
        'SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)',
        'JAR="$SELF_DIR/../' .. jar_unix .. '"',
    }
    if java then
        table.insert(
            lines,
            'if [ -n "${JAR_JAVA:-}" ]; then JAVA_BIN=$JAR_JAVA; else JAVA_BIN=' .. sh_quote(java) .. "; fi"
        )
    else
        table.insert(lines, "JAVA_BIN=${JAR_JAVA:-}")
        table.insert(lines, 'if [ -z "$JAVA_BIN" ]; then')
        table.insert(lines, "  JAVA_HOME=${JAR_JAVA_HOME:-${JAVA_HOME:-}}")
        if java_home then
            table.insert(lines, '  if [ -z "$JAVA_HOME" ]; then JAVA_HOME=' .. sh_quote(java_home) .. "; fi")
        end
        table.insert(lines, '  if [ -n "$JAVA_HOME" ] && [ -x "$JAVA_HOME/bin/java" ]; then')
        table.insert(lines, '    JAVA_BIN="$JAVA_HOME/bin/java"')
        table.insert(lines, "  else")
        table.insert(lines, "    JAVA_BIN=java")
        table.insert(lines, "  fi")
        table.insert(lines, "fi")
    end
    local opts_default = java_opts and sh_quote(java_opts) or "''"
    table.insert(lines, "JAVA_OPTS=${JAR_JAVA_OPTS:-" .. opts_default .. "}")
    table.insert(lines, 'exec "$JAVA_BIN" $JAVA_OPTS ' .. invoke .. args_shell .. ' "$@"')
    table.insert(lines, "")
    local script = table.concat(lines, "\n")
    local script_path = file.join_path(bin_dir, command)
    write_file(script_path, script)
    artifact.chmod(script_path)

    local cmd_lines = {
        "@echo off",
        "setlocal",
    }
    if java then
        table.insert(cmd_lines, 'if defined JAR_JAVA (set "JAVA_BIN=%JAR_JAVA%") else (set "JAVA_BIN=' .. java .. '")')
    else
        if java_home then
            table.insert(cmd_lines, 'if not defined JAVA_HOME set "JAVA_HOME=' .. java_home .. '"')
        end
        table.insert(
            cmd_lines,
            'if defined JAR_JAVA (set "JAVA_BIN=%JAR_JAVA%") else if defined JAVA_HOME (set "JAVA_BIN=%JAVA_HOME%\\bin\\java.exe") else (set "JAVA_BIN=java")'
        )
    end
    if java_opts then
        table.insert(cmd_lines, 'if not defined JAR_JAVA_OPTS set "JAR_JAVA_OPTS=' .. java_opts .. '"')
    end
    table.insert(cmd_lines, '"%JAVA_BIN%" %JAR_JAVA_OPTS% ' .. invoke_win .. args_win .. " %*")
    table.insert(cmd_lines, "")
    local cmd_script = table.concat(cmd_lines, "\r\n")
    write_file(file.join_path(bin_dir, command .. ".cmd"), cmd_script)

    log.info("jar: " .. command .. " -> " .. jar_unix .. (main_class and (" [" .. main_class .. "]") or ""))
    log.debug("jar: installed wrapper " .. script_path)
end

function M.install_direct_jar(ctx, spec, command, download, filename)
    local lib_dir = file.join_path(ctx.install_path, "lib")
    file.mkdir(lib_dir)
    file.move(download, file.join_path(lib_dir, filename))
    local jar_path, main_class, from_manifest = artifact.resolve_jar(ctx, ctx.install_path, spec)
    M.write_wrapper(ctx, ctx.install_path, command, jar_path, main_class, from_manifest)
end

return M
