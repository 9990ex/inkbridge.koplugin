-- 本地单本书管理；操作前重新核对文件，远端目录不进入这里。
local Files = {}
local KEEP_KEY = "inkbridge_library_keep_files"

local function dependencies(deps)
    if deps then return deps end
    return { lfs = require("libs/libkoreader-lfs"), identify = require("inkbridge_state").book_id,
        rename = os.rename, remove = os.remove, settings = G_reader_settings,
        DocSettings = require("docsettings"), history = require("readhistory"),
        collection = require("readcollection"), BookList = require("ui/widget/booklist"),
        History = require("inkbridge_home_history") }
end

function Files.kept(file, settings)
    local saved = (settings or G_reader_settings):readSetting(KEEP_KEY)
    return type(saved) == "table" and saved[file] == true or false
end

function Files.setKept(file, value, settings)
    settings = settings or G_reader_settings
    local saved, copy = settings:readSetting(KEEP_KEY), {}
    for key, v in pairs(type(saved) == "table" and saved or {}) do copy[key] = v end
    copy[file] = value and true or nil
    settings:saveSetting(KEEP_KEY, copy)
end

function Files.snapshot(file, deps)
    deps = dependencies(deps)
    if type(file) ~= "string" or file:sub(1, 1) ~= "/" or file:find("%c") then return nil, "本地文件路径无效。" end
    local attr = deps.lfs.symlinkattributes(file)
    if not attr or attr.mode ~= "file" then return nil, "文件不存在或不是普通文件。" end
    local id = deps.identify(file)
    if type(id) ~= "string" or #id ~= 32 then return nil, "无法核对书籍身份。" end
    return { file = file, id = id, size = attr.size, modification = attr.modification, change = attr.change }
end

local function verify(snapshot, current_file, deps)
    if current_file == snapshot.file then return false, "请先关闭这本书，再管理文件。" end
    local now, err = Files.snapshot(snapshot.file, deps)
    if not now then return false, err end
    for _, key in ipairs({ "id", "size", "modification", "change" }) do
        if now[key] ~= snapshot[key] then return false, "文件已变化，请重新打开书籍详情。" end
    end
    return true
end

function Files.destination(file, name)
    if type(name) ~= "string" or name == "" or name == "." or name == ".."
            or name:sub(1, 1) == "." or name:find("%c") or name:find('[/\\:*?"<>|]')
            or name:find("^%s") or name:find("[%s%.]$") then return nil, "名称不能包含路径、控制字符或首尾空白。" end
    local extension = file:match("(%.[^./]+)$")
    if not extension or name:sub(-#extension):lower() ~= extension:lower() then
        return nil, "请保留原文件扩展名 " .. (extension or "") .. "。"
    end
    return file:match("^(.*/)") .. name
end

-- 文件变动成功后逐项更新索引；局部失败明确报告，避免误称整个操作失败而重复执行。
local function updates(tasks)
    local warnings = {}
    for _, task in ipairs(tasks) do
        local ok = pcall(task[2])
        if not ok then warnings[#warnings + 1] = task[1] end
    end
    return #warnings > 0 and ("\n以下数据更新失败，请检查：" .. table.concat(warnings, "、")) or ""
end

function Files.rename(snapshot, name, current_file, deps)
    deps = dependencies(deps)
    local ok, err = verify(snapshot, current_file, deps)
    if not ok then return false, err end
    local dest; dest, err = Files.destination(snapshot.file, name)
    if not dest then return false, err end
    if dest == snapshot.file then return false, "文件名没有变化。" end
    if deps.lfs.symlinkattributes(dest) then return false, "同名文件已存在，未覆盖。" end
    -- 同名伴随目录也可能属于另一格式的书，不能覆盖它的阅读数据。
    for _, location in ipairs({ "doc", "dir" }) do
        if deps.lfs.symlinkattributes(deps.DocSettings:getSidecarDir(dest, location)) then
            return false, "目标名称已有阅读数据，请换一个名称。"
        end
    end
    deps.DocSettings:getSidecarDir(snapshot.file, "hash") -- 文件存在时预热哈希位置
    local moved = deps.rename(snapshot.file, dest)
    if not moved then return false, "文件改名失败，请检查目录权限。" end
    local warning = updates({
        { "阅读数据", function() deps.DocSettings.updateLocation(snapshot.file, dest) end },
        { "阅读历史", function() deps.history:updateItem(snapshot.file, dest) end },
        { "收藏", function() deps.collection:updateItem(snapshot.file, dest) end },
        { "书目信息", function() deps.BookList.resetBookInfoCache(snapshot.file); deps.BookList.resetBookInfoCache(dest) end },
        { "墨桥缓存", function() deps.History.relocate(snapshot.file, dest) end },
        { "保留标记", function()
            if Files.kept(snapshot.file, deps.settings) then
                Files.setKept(dest, true, deps.settings); Files.setKept(snapshot.file, false, deps.settings)
            end
        end },
    })
    return true, "文件已改名。" .. warning, dest
end

function Files.delete(snapshot, purge_data, current_file, deps)
    deps = dependencies(deps)
    local ok, err = verify(snapshot, current_file, deps)
    if not ok then return false, err end
    if Files.kept(snapshot.file, deps.settings) then return false, "这本书已标记为保留，请先取消保留。" end
    -- 提前缓存哈希位置，以便删除文件后仍能定位阅读数据。
    deps.DocSettings:getSidecarDir(snapshot.file, "hash")
    if not deps.remove(snapshot.file) then return false, "删除失败，请检查文件和目录权限。" end
    local tasks = {
        { "阅读历史", function() deps.history:fileDeleted(snapshot.file) end },
        { "收藏", function() deps.collection:removeItem(snapshot.file) end },
        { "书目信息", function() deps.BookList.resetBookInfoCache(snapshot.file) end },
    }
    if purge_data then
        tasks[#tasks + 1] = { "阅读数据", function() deps.DocSettings.updateLocation(snapshot.file) end }
        tasks[#tasks + 1] = { "墨桥缓存", function() deps.History.relocate(snapshot.file) end }
    end
    return true, (purge_data and "本地书籍文件及阅读数据已删除。" or "本地书籍文件已删除，阅读数据和墨桥缓存已保留。") .. updates(tasks)
end

return Files
