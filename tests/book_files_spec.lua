package.path = "inkbridge.koplugin/?.lua;" .. package.path
local Files = require("inkbridge_book_files")
local passed, failed = 0, 0
local function check(name, value)
    if value then passed = passed + 1 else failed = failed + 1; print("FAIL " .. name) end
end
local id = string.rep("a", 32)
local source = "/books/原名.epub"
local tree, events, values = {}, {}, {}
local function event(value) events[#events + 1] = value end
local deps = {
    lfs = { symlinkattributes = function(file) return tree[file] end },
    identify = function() return id end,
    settings = { readSetting = function(_, key) return values[key] end,
        saveSetting = function(_, key, value) values[key] = value end },
    DocSettings = {
        getSidecarDir = function(_, file, location) return "/" .. location .. file .. ".sdr" end,
        updateLocation = function(a, b) event("metadata:" .. a .. ":" .. tostring(b)) end,
    },
    history = { updateItem = function(_, a, b) event("history:" .. a .. ":" .. b) end,
        fileDeleted = function(_, file) event("deleted:" .. file) end },
    collection = { updateItem = function(_, a, b) event("collection:" .. a .. ":" .. b) end,
        removeItem = function(_, file) event("uncollect:" .. file) end },
    BookList = { resetBookInfoCache = function(file) event("cache:" .. file) end },
    History = { relocate = function(a, b) event("preview:" .. a .. ":" .. tostring(b)) end },
}
deps.rename = function(a, b) tree[b], tree[a] = tree[a], nil; event("rename"); return true end
deps.remove = function(file) tree[file] = nil; event("remove"); return true end
local function reset()
    tree = { [source] = { mode = "file", size = 123, modification = 1, change = 1 } }
    events, values = {}, {}
    return assert(Files.snapshot(source, deps))
end
local function includes(prefix)
    for _, value in ipairs(events) do if value:sub(1, #prefix) == prefix then return true end end
    return false
end
local snapshot = reset()
check("中文文件名保留扩展名", Files.destination(source, "新书名.epub") == "/books/新书名.epub")
for _, name in ipairs({ "../else.epub", "a/b.epub", "a\\b.epub", "a\0.epub", "a\n.epub", ".hidden.epub", "x.txt", " x.epub", "x.epub ", "x:1.epub" }) do
    check("拒绝不安全名称 " .. name, Files.destination(source, name) == nil)
end
check("拒绝相对路径", Files.snapshot("a.epub", deps) == nil)
tree[source].mode = "link"
check("拒绝符号链接", Files.snapshot(source, deps) == nil)
snapshot = reset()
check("正在打开的书不能改名", not Files.rename(snapshot, "新名.epub", source, deps) and #events == 0)
tree[source].modification = 2
check("确认后文件变化拒绝改名", not Files.rename(snapshot, "新名.epub", nil, deps) and #events == 0)
snapshot = reset(); tree["/books/新名.epub"] = { mode = "file" }
check("已有同名文件拒绝覆盖", not Files.rename(snapshot, "新名.epub", nil, deps) and #events == 0)
snapshot = reset(); tree["/doc/books/新名.epub.sdr"] = { mode = "directory" }
check("已有目标阅读数据拒绝覆盖", not Files.rename(snapshot, "新名.epub", nil, deps) and #events == 0)
snapshot = reset(); Files.setKept(source, true, deps.settings)
local ok, message, dest = Files.rename(snapshot, "新名.epub", nil, deps)
check("改名仅移动指定文件", ok and dest == "/books/新名.epub" and tree[dest] and not tree[source])
check("改名更新阅读数据历史收藏及预览", includes("metadata:") and includes("history:") and includes("collection:") and includes("preview:"))
check("保留标记随文件改名", Files.kept(dest, deps.settings) and not Files.kept(source, deps.settings))
snapshot = reset(); local originalRename = deps.rename; deps.rename = function() return false end
check("改名失败不能更新任何数据", not Files.rename(snapshot, "新名.epub", nil, deps) and #events == 0)
deps.rename = originalRename
snapshot = reset(); local updateHistory = deps.history.updateItem
deps.history.updateItem = function() error("read only history") end
ok, message = Files.rename(snapshot, "新名.epub", nil, deps)
check("部分索引失败明确报告文件已改名", ok and message:find("阅读历史", 1, true) and includes("preview:"))
deps.history.updateItem = updateHistory
snapshot = reset(); Files.setKept(source, true, deps.settings)
check("标记保留的书阻止删除", not Files.delete(snapshot, false, nil, deps) and #events == 0 and tree[source])
Files.setKept(source, false, deps.settings)
check("正在打开的书不能删除", not Files.delete(snapshot, true, source, deps) and #events == 0)
ok = Files.delete(snapshot, false, nil, deps)
check("仅删除文件保留伴随数据和墨桥缓存", ok and not tree[source] and includes("remove")
    and not includes("metadata:") and not includes("preview:"))
snapshot = reset(); ok = Files.delete(snapshot, true, nil, deps)
check("删除文件及数据更新指定书籍", ok and includes("metadata:" .. source .. ":nil") and includes("preview:" .. source .. ":nil"))
snapshot = reset(); local originalRemove = deps.remove; deps.remove = function() return false end
check("文件删除失败不能清理阅读数据", not Files.delete(snapshot, true, nil, deps) and #events == 0)
deps.remove = originalRemove
snapshot = reset(); tree[source] = nil
check("文件消失拒绝重复删除", not Files.delete(snapshot, true, nil, deps) and #events == 0)
snapshot = reset(); deps.identify = function() return string.rep("b", 32) end
check("同路径异书拒绝删除", not Files.delete(snapshot, true, nil, deps) and #events == 0)

local History = require("inkbridge_home_history")
G_reader_settings = deps.settings
local cached = { file = source, title = "原名", book_id = id, records = { { text = "原始锚点", excerpt = "选段" } } }
values[History.KEY] = { version = 1, books = { cached, { file = "/books/other.epub", records = {} } } }
History.relocate(source, "/books/新名.epub")
check("迁移缓存保留原记录且不原地修改", History.load().books[1].file == "/books/新名.epub"
    and History.load().books[1].records == cached.records and cached.file == source)
History.relocate("/books/新名.epub")
check("清理缓存只删除指定路径", #History.load().books == 1 and History.load().books[1].file == "/books/other.epub")
print(string.format("合计：%d 通过，%d 失败", passed, failed))
os.exit(failed == 0 and 0 or 1)
