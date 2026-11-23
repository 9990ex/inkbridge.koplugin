package.path = "inkbridge.koplugin/?.lua;" .. package.path
local passed, failed = 0, 0
local function check(name, value)
    if value then passed = passed + 1 else failed = failed + 1; print("FAIL " .. name) end
end

local Library = require("inkbridge_library")
local id = "0123456789abcdef0123456789abcdef"
local same = Library.catalog({ { file = "a.epub" } }, {
    { file = "a.epub", book_id = id, records = { { text = "cached one" }, { text = "cached two" } } },
}, { { book_id = id, title = "A", record = { text = "cloud one" } } }, function() return true end,
function() return id end)
check("完整书籍身份合并本机与云端来源", #same == 1 and #same[1].local_records == 2
    and #same[1].cloud_records == 1)

local other_id = "fedcba9876543210fedcba9876543210"
local split = Library.catalog({ { file = "a.epub" } }, {
    { file = "a.epub", book_id = id, records = { { text = "old identity" } } },
}, { { book_id = other_id, title = "A", record = { text = "new identity" } } },
function() return true end, function() return id end)
check("不同完整身份不合并", #split == 2)
local catalog = Library.catalog({ { file = "/reader/Root.epub" } }, {}, {
    { book_id = id, title = "Root.epub", record = { text = "cloud" } },
}, function() return true end, function() return id end, {
    { path = "/dav/Root.epub", title = "Root.epub" },
    { path = "/dav/Other.epub", title = "Other.epub" },
})
check("真实 WebDAV 书目与同名本机书/云端历史汇总", #catalog == 2
    and catalog[2].remote.path == "/dav/Root.epub" and catalog[2].file == "/reader/Root.epub"
    and #catalog[2].cloud_records == 1)

local old_webdav, old_network = package.loaded["inkbridge_webdav"], package.loaded["ui/network/manager"]
local old_ui, old_home_sync = package.loaded["ui/uimanager"], package.loaded["inkbridge_home_sync"]
local folder_map = {
    ["/books"] = {
        { is_folder = true, text = "fiction/", url = "/books/fiction" },
        { is_folder = true, text = "Root.sdr/", url = "/books/Root.sdr" },
        { is_file = true, text = "Root.epub", url = "/books/Root.epub" },
    },
    ["/books/fiction"] = {
        { is_folder = true, text = "series/", url = "/books/fiction/series" },
    },
    ["/books/Root.sdr"] = { { is_file = true, text = "Hidden.epub", url = "/books/Root.sdr/Hidden.epub" } },
    ["/books/fiction/series"] = {
        { is_file = true, text = "Nested.pdf", url = "/books/fiction/series/Nested.pdf" },
    },
    ["/sync"] = {
        { is_file = true, text = "Root-0101-010101-KO.01234567.InkBridge.txt",
            url = "/sync/Root-0101-010101-KO.01234567.InkBridge.txt" },
    },
}
package.loaded["ui/network/manager"] = { isConnected = function() return true end }
package.loaded["ui/uimanager"] = {
    nextTick = function(_, fn) fn() end,
    scheduleIn = function() end,
    unschedule = function() end,
}
package.loaded["inkbridge_home_sync"] = { running = false }
package.preload.logger = function() return { warn = function() end } end
package.loaded["inkbridge_webdav"] = {
    _is_safe_remote_path = function() return true end,
    _is_inkbridge_record = function() return true end,
    list_folder = function(_, path, cb, include_folders)
        check("WebDAV 目录按扫描模式读取", include_folders == true or path == "/sync")
        cb(true, folder_map[path] or {})
    end,
    download = function(client, _, cb)
        check("跨目录读取继承真实下载暂存接口", client:_download_staging_path() == "library-test.tmp")
        cb(true, {
        book_id = id, book_name = "Root.epub", text_anchor = "cloud history",
        updated_at = 100, device_label = "KOReader", percent = 0.5,
    }, nil, '"record-v1"') end,
}
local scan_result
Library.scan({ server = { type = "webdav", url = "/books" },
    sync_server = { type = "webdav", url = "/sync" },
    _download_staging_path = function() return "library-test.tmp" end }, function(...)
    scan_result = { ... }
end)
check("书库扫描包含根目录与嵌套电子书", scan_result and scan_result[1]
    and #scan_result[4] == 2 and scan_result[4][1].path == "/books/Root.epub"
    and scan_result[4][2].path == "/books/fiction/series/Nested.pdf")
check("递归扫描仍提取目录内墨桥历史", scan_result and #scan_result[2] == 1
    and scan_result[2][1].book_id == id)
package.loaded["inkbridge_webdav"], package.loaded["ui/network/manager"] = old_webdav, old_network
package.loaded["ui/uimanager"], package.loaded["inkbridge_home_sync"] = old_ui, old_home_sync

old_webdav = package.loaded["inkbridge_webdav"]
package.loaded["inkbridge_webdav"] = {
    _is_safe_remote_path = function() return true end,
    _is_inkbridge_record = function() return true end,
    strong_etag = function(value) return type(value) == "string" and value:sub(1, 1) == '"' end,
}
local server = { url = "books", type = "webdav" }
local cloud_book = { id = id }
local cloud_row = { book_id = id, server = server, item = {
    text = "A.01234567.InkBridge.txt", url = "books/A.01234567.InkBridge.txt",
} }
local result
Library.delete_cloud({ server = server }, cloud_book, cloud_row, function(ok) result = ok end)
check("缺少强 ETag 时不删云端记录", result == false)
cloud_book.id = other_id
result = nil
Library.delete_cloud({ server = server }, cloud_book, cloud_row, function(ok) result = ok end)
check("完整书籍身份不匹配时拒绝删除", result == false)
package.loaded["inkbridge_webdav"] = old_webdav

local old_lfs, old_registry = package.loaded["libs/libkoreader-lfs"], package.loaded["document/documentregistry"]
old_ui = package.loaded["ui/uimanager"]
local queued, closed = {}, 0
local tree = {
    ["/books"] = { ".", "..", ".hidden.epub", "A.epub", "folder", "A.sdr", "alias", "A.01234567.InkBridge.txt", "notes.log", "unsupported.pdb" },
    ["/books/folder"] = { "B.TXT", "deeper", "unreadable" },
    ["/books/folder/deeper"] = { "C.pdf" },
}
local modes = { ["/books"] = "directory", ["/books/folder"] = "directory",
    ["/books/folder/deeper"] = "directory", ["/books/folder/unreadable"] = "directory",
    ["/books/alias"] = "link", ["/current"] = "directory" }
modes["/books/A.sdr"] = "directory"
tree["/books/A.sdr"] = { "Hidden.epub" }
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(path) return modes[path] end,
    symlinkattributes = function(path) return modes[path] or "file" end,
    dir = function(path)
        if path:find("unreadable", 1, true) then error("denied") end
        local dir = { index = 0, close = function(self) if not self.closed then closed = closed + 1; self.closed = true end end }
        return function(state)
            state.index = state.index + 1
            return (tree[path] or {})[state.index]
        end, dir
    end,
}
package.loaded["document/documentregistry"] = {
    hasProvider = function(_, path) return not path:find("unsupported", 1, true) end,
}
package.loaded["ui/uimanager"] = { nextTick = function(_, fn) queued[#queued + 1] = fn end }
local function drain() while #queued > 0 do table.remove(queued, 1)() end end
local local_result
Library.scanLocal("/books", function(...) local_result = { ... } end)
check("本地扫描先让出UI不阻塞首次显示", local_result == nil and #queued == 1)
drain()
check("本地扫描含未阅读过的根目录与子目录书籍", local_result and local_result[1]
    and #local_result[2] == 3 and local_result[2][1].file == "/books/A.epub"
    and local_result[2][3].file == "/books/folder/deeper/C.pdf")
check("本地扫描过滤隐藏项同步记录不支持文件及符号链接", #local_result[2] == 3)
check("文件夹清单隐藏KOReader书籍伴随目录", #local_result[4] == 4)
check("子目录权限失败保留其余书籍并报告", local_result[3] == 1 and closed == 3)
local_result = nil
local cancel = Library.scanLocal("/books", function(...) local_result = { ... } end)
table.remove(queued, 1)()
cancel(); drain()
check("离开书库取消扫描并关闭目录句柄", local_result == nil and closed == 4)
Library.scanLocal("/missing", function(...) local_result = { ... } end); drain()
check("本地目录失效有明确错误", local_result and local_result[1] == false)
local settings = {}
G_reader_settings = { readSetting = function(_, key) return settings[key] end,
    saveSetting = function(_, key, value) settings[key] = value end }
check("未配置时采用当前文件管理器目录", Library.localRoot({ ui = { file_chooser = { path = "/current" } } }) == "/current")
settings.home_dir = "/books"
check("本地主目录优先于临时浏览目录", Library.localRoot({ ui = { file_chooser = { path = "/current" } } }) == "/books")
settings[Library.LOCAL_KEY] = "/current"
check("独立书库目录优先且不覆盖主目录", Library.localRoot({}) == "/current" and settings.home_dir == "/books")
settings[Library.LOCAL_KEY] = "/missing"
check("已选书库目录失效时不能悄悄切到其他目录", Library.localRoot({}) == "/missing")

local identified = 0
local files = { { file = "/books/A.epub", title = "A.epub" }, { file = "/books/B.epub", title = "B.epub" } }
local cached = {
    { file = "/books/A.epub", book_id = id, records = { { text = "valid" } } },
    { file = "/outside/C.epub", book_id = other_id, records = { { text = "outside" } } },
}
local locals = Library.localCatalog(files, cached, nil, function() identified = identified + 1; return id end)
check("本地书目只取选定目录不混入历史缓存", #locals == 2 and #locals[1].local_records == 1)
check("未阅读书籍不预先计算身份", identified == 1)
locals = Library.localCatalog(files, cached, { { book_id = other_id, title = "A.epub" } }, function() return id end)
check("本地云端同名不同身份不能合并", #locals == 2 and #locals[1].cloud_records == 0)
locals = Library.localCatalog(files, cached, { { book_id = id } }, function(path) return path == files[1].file and id or other_id end)
check("本地云端记录只按完整身份归组", #locals[1].cloud_records == 1 and #locals[2].cloud_records == 0)
locals = Library.localCatalog(files, { { file = files[1].file, book_id = other_id,
    records = { { text = "old version" } } } }, nil, function() return id end)
check("本地文件换版后不显示旧身份缓存", #locals[1].local_records == 0)
local view_books = {
    { file = "/books/A.epub", title = "A.epub", modification = 1 },
    { file = "/books/B.epub", title = "B.epub", modification = 20 },
    { file = "/books/fiction/C.epub", title = "C.epub" },
    { file = "/books/fiction/deep/D.epub", title = "D.epub" },
}
local dirs = { { path = "/books/fiction" }, { path = "/books/empty" } }
local entries, current = Library.entries(view_books, dirs, "/books", nil, { mode = "folders", sort = "name" })
check("文件夹列表在书籍之前且保留空目录", #entries == 4 and entries[1].title == "empty"
    and entries[2].title == "fiction" and entries[3].book == view_books[1])
check("目录层级统一根路径斜杠", current == "books")
entries = Library.entries(view_books, dirs, "/books/", "/books/fiction/", { mode = "folders", sort = "name" })
check("进入子目录仅显示直接子项不扁平化", #entries == 2 and entries[1].title == "deep"
    and entries[2].book == view_books[3])
entries = Library.entries(view_books, dirs, "/books", "books/empty", { mode = "folders", sort = "name" })
check("空文件夹不混入其他书目", #entries == 0)
entries, current = Library.entries(view_books, dirs, "/books", "/books-other", { mode = "folders", sort = "name" })
check("无效当前路径回根目录且不混同路径前缀", current == "books" and #entries == 4)
check("目录上级不越过书库根", Library.parentFolder("books/fiction/deep", "/books") == "books/fiction"
    and Library.parentFolder("books", "/books") == "books")
entries = Library.entries(view_books, dirs, "/books", nil, { mode = "all", sort = "descending" })
check("全部书籍可跨层按名称降序排列", #entries == 4 and entries[1].title == "D.epub")
entries = Library.entries(view_books, dirs, "/books", nil, { mode = "all", sort = "modified" })
check("按真实文件修改时间排序", entries[1].title == "B.epub")
entries = Library.entries({ { file = "/local/Other.epub", title = "Remote.epub",
    remote = { path = "book/sub/Remote.epub" } } }, {}, "/book", nil, { mode = "folders", sort = "name" })
check("WebDAV目录层级使用远端路径而非本地副本", #entries == 1 and entries[1].is_folder
    and entries[1].path == "book/sub")
entries = Library.entries({ { file = "/books/one/A.epub", title = "A.epub" },
    { file = "/books/two/A.epub", title = "A.epub" } }, {}, "/books", nil, { mode = "all", sort = "name" })
check("不同文件夹的同名书籍均保留", #entries == 2 and entries[1].path ~= entries[2].path)
check("默认按文件夹和标准列表显示", Library.viewOptions().mode == "folders"
    and Library.viewOptions().density == "normal" and Library.viewOptions().sort == "name")
Library.setViewOption("density", "large")
check("列表调整独立持久化不覆盖来源目录", Library.viewOptions().density == "large"
    and settings[Library.LOCAL_KEY] == "/missing")
settings[Library.VIEW_KEY] = { mode = "broken", density = false, sort = {} }
check("损坏的列表设置安全回退", Library.viewOptions().mode == "folders"
    and Library.viewOptions().density == "normal" and Library.viewOptions().sort == "name")
package.loaded["libs/libkoreader-lfs"], package.loaded["document/documentregistry"] = old_lfs, old_registry
package.loaded["ui/uimanager"] = old_ui

print(string.format("合计：%d 通过，%d 失败", passed, failed))
os.exit(failed == 0 and 0 or 1)
