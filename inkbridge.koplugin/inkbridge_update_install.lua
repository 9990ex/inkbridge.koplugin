-- 自动更新安装器。网络由调用方负责；本模块只校验并替换插件目录。
local Installer = {}

local function file_sha256(path)
    local sha = require("ffi/sha2")
    local hash = sha.sha256()
    local file, err = io.open(path, "rb")
    if not file then return nil, err end
    while true do
        local chunk = file:read(65536)
        if not chunk then break end
        hash(chunk)
    end
    file:close()
    return hash()
end

local function read_file(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local text = file:read("*a")
    file:close()
    return text
end

function Installer.install(archive_path, plugin_dir, expected_digest, expected_version, deps)
    deps = deps or {}
    local lfs = deps.lfs or require("libs/libkoreader-lfs")
    local util = deps.util or require("util")
    local ffiUtil = deps.ffiUtil or require("ffi/util")
    local Archiver = deps.Archiver or require("ffi/archiver")
    local hash_file = deps.hash_file or file_sha256
    local read = deps.read_file or read_file
    local digest_matches = deps.digest_matches or require("inkbridge_update").digest_matches
    local attributes = deps.attributes or function(path) return lfs.attributes(path, "mode") end
    local rename = deps.rename or os.rename
    local remove = deps.remove or os.remove
    local purge = deps.purge or ffiUtil.purgeDir

    if type(expected_digest) ~= "string" or expected_digest == "" then
        return false, "GitHub 未提供 SHA-256，已拒绝安装未校验的更新包"
    end
    local actual, hash_err = hash_file(archive_path)
    if not actual then return false, "无法校验安装包：" .. tostring(hash_err) end
    if not digest_matches(actual, expected_digest) then
        return false, "安装包 SHA-256 不匹配，已拒绝安装"
    end

    local stage, backup = plugin_dir .. ".update-new", plugin_dir .. ".update-backup"
    if attributes(stage) or attributes(backup) then
        return false, "发现未完成的更新临时目录，请先检查后手动处理：" .. stage
    end
    local ok, err = util.makePath(ffiUtil.dirname(stage))
    if not ok then return false, "无法创建更新目录：" .. tostring(err) end
    ok, err = util.makePath(stage)
    if not ok then return false, "无法创建暂存目录：" .. tostring(err) end

    local arc = Archiver.Reader:new()
    local opened, open_err = arc:open(archive_path)
    if not opened then
        purge(stage)
        return false, "无法读取更新 ZIP：" .. tostring(arc.err or open_err)
    end

    local seen, total_size, plugin_root = {}, 0, false
    local entries, invalid = {}, nil
    for entry in arc:iterate() do
        local path = entry.path
        local is_license = path == "LICENSE" or path == "LICENSE/"
        if not is_license and not require("inkbridge_update").is_safe_archive_path(path) then
            invalid = "ZIP 含有不安全路径：" .. tostring(path)
            break
        end
        if entry.mode ~= "file" and entry.mode ~= "directory" then
            invalid = "ZIP 含有不支持的文件类型：" .. tostring(path)
            break
        end
        if seen[path] then
            invalid = "ZIP 含有重复路径：" .. path
            break
        end
        seen[path] = true
        if path == "inkbridge.koplugin" or path == "inkbridge.koplugin/" then
            plugin_root = true
        elseif path:sub(1, #"inkbridge.koplugin/") == "inkbridge.koplugin/" then
            plugin_root = true
            if entry.mode == "file" then
                total_size = total_size + (tonumber(entry.size) or 0)
                if total_size > 20 * 1024 * 1024 or #entries >= 100 then
                    invalid = "更新包体积或文件数超出限制"
                    break
                end
            end
            entries[#entries + 1] = entry
        elseif path ~= "LICENSE" and path ~= "LICENSE/" then
            invalid = "ZIP 含有插件目录以外的内容：" .. path
            break
        end
    end
    if not invalid and arc.err then invalid = "读取 ZIP 目录失败：" .. tostring(arc.err) end
    if not invalid and not plugin_root then invalid = "ZIP 中缺少 inkbridge.koplugin 目录" end
    if not invalid and (not seen["inkbridge.koplugin/main.lua"]
            or not seen["inkbridge.koplugin/_meta.lua"]) then
        invalid = "ZIP 中缺少插件入口或版本文件"
    end
    arc:close()
    if invalid then
        purge(stage)
        return false, invalid
    end

    arc = Archiver.Reader:new()
    opened, open_err = arc:open(archive_path)
    if not opened then
        purge(stage)
        return false, "无法重新打开更新 ZIP：" .. tostring(arc.err or open_err)
    end
    for entry in arc:iterate() do
        if entry.path:sub(1, #"inkbridge.koplugin/") == "inkbridge.koplugin/" then
            local suffix = entry.path:sub(#"inkbridge.koplugin/" + 1)
            local destination = stage .. "/inkbridge.koplugin/" .. suffix
            local parent = entry.mode == "directory" and destination or ffiUtil.dirname(destination)
            ok, err = util.makePath(parent)
            if not ok then break end
            if entry.mode == "file" then
                ok, err = arc:extractToPath(entry.path, destination)
                if not ok then break end
            end
        end
    end
    if not ok then err = err or arc.err or "解压失败" end
    arc:close()
    if not ok then
        purge(stage)
        return false, "解压更新包失败：" .. tostring(err)
    end

    local staged_plugin = stage .. "/inkbridge.koplugin"
    local meta = read(staged_plugin .. "/_meta.lua")
    local version = meta and meta:match('version%s*=%s*"([^\"]+)"')
    local wanted = tostring(expected_version or ""):gsub("^v", "")
    if version ~= wanted or attributes(staged_plugin .. "/main.lua") ~= "file" then
        purge(stage)
        return false, "更新包内插件版本与 GitHub 发布版本不一致"
    end

    ok, err = rename(plugin_dir, backup)
    if not ok then
        purge(stage)
        return false, "无法备份现有插件：" .. tostring(err)
    end
    ok, err = rename(staged_plugin, plugin_dir)
    if not ok then
        local restored, restore_err = rename(backup, plugin_dir)
        purge(stage)
        if not restored then
            return false, "安装失败且自动恢复失败；原插件备份保留在 "
                .. backup .. "（" .. tostring(restore_err) .. "）"
        end
        return false, "替换插件失败，已恢复旧版本：" .. tostring(err)
    end

    purge(backup)
    purge(stage)
    remove(archive_path)
    return true
end

return Installer
