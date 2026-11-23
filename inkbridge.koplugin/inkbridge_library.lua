local History = require("inkbridge_home_history")
local Library = {}
Library.SERVER_KEY = "inkbridge_library_webdav_server"
Library.LOCAL_KEY = "inkbridge_library_local_folder"
Library.VIEW_KEY = "inkbridge_library_view"

function Library.viewOptions()
    local saved = G_reader_settings:readSetting(Library.VIEW_KEY)
    saved = type(saved) == "table" and saved or {}
    return {
        mode = saved.mode == "all" and "all" or "folders",
        density = saved.density == "compact" and "compact" or saved.density == "large" and "large" or "normal",
        sort = saved.sort == "descending" and "descending" or saved.sort == "modified" and "modified" or "name",
    }
end

function Library.setViewOption(key, value)
    local options = Library.viewOptions()
    options[key] = value
    G_reader_settings:saveSetting(Library.VIEW_KEY, options)
end

-- 切换目录时保留插件的下载暂存等接口，不改动原插件的服务器配置。
function Library.client(plugin, server)
    return setmetatable({ server = server }, { __index = plugin })
end

-- 默认使用用户已设置的书库目录或当前文件管理器目录，不猜测设备路径。
function Library.localRoot(plugin)
    local settings = G_reader_settings
    local configured = settings:readSetting(Library.LOCAL_KEY)
    if type(configured) == "string" and configured ~= "" then return configured end
    local chooser = plugin.ui and plugin.ui.file_chooser
    local candidates = {
        settings:readSetting("home_dir") or false,
        chooser and chooser.path or false,
        settings:readSetting("lastdir") or false,
    }
    local lfs = require("libs/libkoreader-lfs")
    for _, path in ipairs(candidates) do
        if type(path) == "string" and lfs.attributes(path, "mode") == "directory" then return path end
    end
end

function Library.pickLocalFolder(plugin, done)
    local root = Library.localRoot(plugin)
    if not root or require("libs/libkoreader-lfs").attributes(root, "mode") ~= "directory" then
        root = require("apps/filemanager/filemanagerutil").getDefaultDir()
    end
    require("ui/uimanager"):show(require("ui/widget/pathchooser"):new{
        title = "长按选择本地书库目录",
        path = root,
        select_directory = true, select_file = false, show_files = false,
        onConfirm = function(path)
            if require("libs/libkoreader-lfs").attributes(path, "mode") ~= "directory" then
                done(false, "本地目录已移动或无法访问。")
                return
            end
            G_reader_settings:saveSetting(Library.LOCAL_KEY, path)
            done(true, path)
        end,
    })
end

function Library.target(plugin)
    local server = G_reader_settings and G_reader_settings:readSetting(Library.SERVER_KEY)
    if type(server) == "table" and server.type == "webdav" then return server end
    return nil
end

function Library.pickFolder(plugin, done)
    local WebDAV = require("inkbridge_webdav")
    return WebDAV.pick_folder(plugin, function(server)
        if type(server) ~= "table" or server.type ~= "webdav" then
            done(false, "书库目录必须是 WebDAV 目录。")
            return
        end
        G_reader_settings:saveSetting(Library.SERVER_KEY, server)
        done(true, server)
    end)
end

local function full_id(id)
    return type(id) == "string" and #id == 32 and not id:find("[^%x]")
end

local function basename(path)
    return path:match("([^/\\]+)$") or path
end

local BOOK_EXT = {
    epub = true, pdf = true, djvu = true, mobi = true, azw = true, azw3 = true,
    cbz = true, cbt = true, docx = true, rtf = true, html = true, htm = true,
    txt = true, xps = true, fb2 = true, pdb = true, chm = true, md = true,
    prc = true, odt = true,
}

local function book_file(name)
    if type(name) ~= "string" or name:find(".InkBridge.", 1, true)
            or name:sub(1, 10) == "InkBridge-" then return false end
    local ext = type(name) == "string" and name:lower():match("%.([%w]+)$")
    return ext and BOOK_EXT[ext] == true or false
end

local function visible_folder(name)
    return type(name) == "string" and name:sub(1, 1) ~= "."
        and name:gsub("/+$", ""):lower():sub(-4) ~= ".sdr"
end

-- 每批最多读 100 个条目，向 UI 让出执行权；不跟随符号链接，不读取正文或联网。
function Library.scanLocal(root, done)
    local lfs = require("libs/libkoreader-lfs")
    local UI = require("ui/uimanager")
    local active, iterator, directory = true
    local folders, index, books, skipped, entries = { { path = root, depth = 0 } }, 1, {}, 0, 0
    local function close_dir()
        if directory then pcall(function() directory:close() end) end
        iterator, directory = nil, nil
    end
    local function finish(ok, message)
        close_dir()
        active = false
        table.sort(books, function(a, b) return a.file:lower() < b.file:lower() end)
        done(ok, ok and books or message, skipped, folders)
    end
    local step
    step = function()
        if not active then return end
        if not iterator then
            local folder = folders[index]
            if not folder then finish(true); return end
            if lfs.attributes(folder.path, "mode") ~= "directory" then
                if index == 1 then finish(false, "本地书库目录已移动或无法访问。"); return end
                skipped, index = skipped + 1, index + 1
                UI:nextTick(step)
                return
            end
            local ok, iter, dir = pcall(lfs.dir, folder.path)
            if not ok then
                if index == 1 then finish(false, "无法读取本地书库目录。"); return end
                skipped, index = skipped + 1, index + 1
                UI:nextTick(step)
                return
            end
            iterator, directory = iter, dir
        end
        local folder = folders[index]
        for _ = 1, 100 do
            local ok, name = pcall(iterator, directory)
            if not ok then
                if index == 1 then finish(false, "无法完整读取本地书库目录。"); return end
                skipped = skipped + 1
            end
            if not ok or not name then close_dir(); index = index + 1; break end
            entries = entries + 1
            if entries > 50000 then finish(false, "目录条目过多，请选择范围更小的书籍文件夹。"); return end
            if name:sub(1, 1) ~= "." then
                local path = folder.path:gsub("/+$", "") .. "/" .. name
                local mode = lfs.symlinkattributes(path, "mode")
                if mode == "directory" and visible_folder(name) then
                    if folder.depth < 5 then
                        folders[#folders + 1] = { path = path, depth = folder.depth + 1 }
                    else skipped = skipped + 1 end
                elseif mode == "file" and book_file(name)
                        and require("document/documentregistry"):hasProvider(path) then
                    books[#books + 1] = { file = path, title = name,
                        modification = lfs.attributes(path, "modification") }
                end
            end
        end
        UI:nextTick(step)
    end
    UI:nextTick(step)
    return function() active = false; close_dir() end
end

-- 本地书目只来自选定目录；缓存、阅读历史和云端同名文件不能凭空增加书目。
function Library.localCatalog(files, cached, remote, identify)
    local books, by_file, by_id = {}, {}, {}
    for _, file in ipairs(files) do
        local book = { file = file.file, title = file.title, modification = file.modification,
            local_records = {}, cloud_records = {} }
        books[#books + 1], by_file[file.file] = book, book
    end
    for _, row in ipairs(cached or {}) do
        local book = type(row) == "table" and by_file[row.file]
        if book and type(row.records) == "table" then
            if not book.checked_id then
                local ok, id = pcall(identify, book.file)
                book.id, book.checked_id = ok and id or nil, true
                if full_id(book.id) then
                    by_id[book.id] = by_id[book.id] or {}
                    table.insert(by_id[book.id], book)
                end
            end
            if full_id(book.id) and book.id == row.book_id then
                for _, record in ipairs(row.records) do
                    if type(record) == "table" and type(record.text) == "string" then
                        book.local_records[#book.local_records + 1] = {
                            file = row.file, book_id = row.book_id, record = record,
                        }
                    end
                end
            end
        end
    end
    if remote and #remote > 0 then
        -- 只有手动读取云端记录时才为其余书籍计算身份，绝不按同名挂载记录。
        for _, book in ipairs(books) do
            if not book.checked_id then
                local ok, id = pcall(identify, book.file)
                book.id, book.checked_id = ok and id or nil, true
                if full_id(book.id) then
                    by_id[book.id] = by_id[book.id] or {}
                    table.insert(by_id[book.id], book)
                end
            end
        end
        for _, row in ipairs(remote) do
            for _, book in ipairs(by_id[row.book_id] or {}) do
                book.cloud_records[#book.cloud_records + 1] = row
            end
        end
    end
    return books
end

local function normalize_path(path)
    return (path or ""):gsub("^/+", ""):gsub("/+$", "")
end

local function inside(path, root)
    return root == "" or path == root or path:sub(1, #root + 1) == root .. "/"
end

function Library.parentFolder(path, root)
    path, root = normalize_path(path), normalize_path(root)
    local parent = path:match("^(.*)/[^/]+$") or ""
    return inside(parent, root) and parent or root
end

-- 从真实目录清单生成当前层级；同名的不同路径各自保留，空文件夹也可进入。
function Library.entries(books, folders, root, current, options)
    root, current = normalize_path(root), normalize_path(current or root)
    if not inside(current, root) then current = root end
    local entries, seen = {}, {}
    local function childPath(path)
        path = normalize_path(path)
        if not inside(path, current) or path == current then return end
        local relative = current == "" and path or path:sub(#current + 2)
        local first, rest = relative:match("^([^/]+)/(.*)$")
        return first and (current == "" and first or current .. "/" .. first) or path, rest ~= nil
    end
    local function folderEntry(path)
        local child = childPath(path)
        if not child or seen[child] then return end
        seen[child] = true
        entries[#entries + 1] = { is_folder = true, path = child, title = basename(child) }
    end
    if options.mode == "folders" then
        for _, folder in ipairs(folders or {}) do folderEntry(folder.path or folder.url) end
    end
    for _, book in ipairs(books or {}) do
        local path = book.file or book.path or (book.remote and book.remote.path)
        -- WebDAV 书目可能关联本地副本，目录层级必须始终使用当前来源的路径。
        if book.remote then path = book.remote.path end
        if options.mode == "all" then
            entries[#entries + 1] = { book = book, title = book.title, path = path }
        else
            local child, nested = childPath(path)
            if nested then folderEntry(child)
            elseif child then entries[#entries + 1] = { book = book, title = book.title, path = path } end
        end
    end
    local function modified(entry)
        local book = entry.book
        return tonumber(book and (book.modification or (book.remote and book.remote.item
            and book.remote.item.modification))) or 0
    end
    table.sort(entries, function(a, b)
        if a.is_folder ~= b.is_folder then return a.is_folder == true end
        if options.sort == "modified" and not a.is_folder and modified(a) ~= modified(b) then
            return modified(a) > modified(b)
        end
        local at, bt = a.title:lower(), b.title:lower()
        if at == bt then return (a.path or "") < (b.path or "") end
        if options.sort == "descending" then return at > bt end
        return at < bt
    end)
    return entries, current
end

local function title_key(value)
    value = basename(value or ""):gsub("%.[^%.]+$", ""):lower()
    return value:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

-- 缓存使用原路径和原记录对象作为删除凭据；书目按完整书籍 ID 合并。
function Library.catalog(hist, cached, remote, exists, identify, remote_books)
    local books, by_id, visited = {}, {}, {}
    local function book_for(id, title, key)
        key = full_id(id) and id or key
        local book = by_id[key]
        if not book then
            book = { id = id, title = title, local_records = {}, cloud_records = {} }
            books[#books + 1], by_id[key] = book, book
        end
        return book
    end
    local local_by_file = {}
    local function add_file(file)
        if visited[file] then return end
        visited[file] = true
        if not exists(file) then return end
        local id = identify(file)
        local book = book_for(id, basename(file), file)
        book.file = book.file or file
        local_by_file[file] = book
    end
    for _, row in ipairs(hist) do
        if type(row.file) == "string" and not row.dim then add_file(row.file) end
    end
    for _, remote_book in ipairs(remote_books or {}) do
        local key = "remote:" .. remote_book.path
        local book
        for _, existing in ipairs(books) do
            if title_key(existing.title) == title_key(remote_book.title) then book = existing; break end
        end
        book = book or book_for(nil, remote_book.title, key)
        book.remote = remote_book
        book.path = remote_book.path
        book.title = remote_book.title
    end
    for _, row in ipairs(cached) do
        if type(row.file) == "string" and exists(row.file) then
            add_file(row.file)
            local local_book = local_by_file[row.file]
            local book = local_book and local_book.id == row.book_id and local_book
                or book_for(row.book_id, basename(row.file), row.file .. "\0cache")
            for _, record in ipairs(row.records or {}) do
                if type(record) == "table" and type(record.text) == "string" then
                    book.local_records[#book.local_records + 1] = {
                        record = record, file = row.file, book_id = row.book_id,
                    }
                end
            end
        end
    end
    for _, row in ipairs(remote) do
        local key = title_key(row.title)
        local matched
        for _, book in ipairs(books) do
            if title_key(book.title) == key and book.remote then matched = book; break end
        end
        local book = matched or book_for(row.book_id, row.title)
        book.cloud_id = book.cloud_id or row.book_id
        book.cloud_records[#book.cloud_records + 1] = row
    end
    table.sort(books, function(a, b) return title_key(a.title) < title_key(b.title) end)
    return books
end

local function candidate(server, item)
    if type(item) ~= "table" or type(item.text) ~= "string" then return end
    local name = item.text
    if name:find("/", 1, true) then return end
    local folder = (server.url or ""):gsub("^/+", ""):gsub("/+$", "")
    local path = folder .. "/" .. name
    if item.url ~= path and item.url ~= "/" .. path then return end
    local WebDAV = require("inkbridge_webdav")
    if not WebDAV._is_safe_remote_path(item.url) then return end
    local title, prefix = name:match("^(.*)%.(%x%x%x%x%x%x%x%x)%.InkBridge%.")
    prefix = prefix or name:match("^InkBridge%-(%x%x%x%x%x%x%x%x)%-")
    if not prefix or not WebDAV._is_inkbridge_record(name, prefix) then return end
    return prefix, title and (title:match("^(.*)%-%d%d%d%d%-%d%d%d%d%d%d%-") or title)
end

local function start(plugin, done, work)
    local Network = require("ui/network/manager")
    local UI = require("ui/uimanager")
    local source = plugin.server
    if not source or source.type ~= "webdav" then done(false, "尚未配置 WebDAV 书库目录。") return end
    if Library.busy or require("inkbridge_home_sync").running then done(false, "墨桥正在读取同步记录。") return end
    if not Network:isConnected() then done(false, "当前离线。") return end
    local client = Library.client(plugin, source)
    local active, timeout = true
    local function finish(...)
        if not active then return end
        active, Library.busy = false, nil
        UI:unschedule(timeout)
        done(...)
    end
    local function defer(fn)
        UI:nextTick(function()
            if not active then return end
            if plugin.server ~= source or not Network:isConnected() then
                finish(false, "网络或同步目录已变化，请重试。")
            else
                local ok = xpcall(fn, function(message)
                    -- 只记录源码位置和调用栈，避免 provider 异常带出服务器凭据。
                    require("logger").warn("InkBridge library failure",
                        tostring(message):match("^[^\n]*:%d+:") or "unknown source", debug.traceback())
                    return message
                end)
                if not ok then finish(false, "WebDAV 操作失败，请重试。") end
            end
        end)
    end
    timeout = function() finish(false, "WebDAV 操作超时，请刷新核对。") end
    Library.busy = true
    UI:scheduleIn(90, timeout)
    defer(function() work(client, finish, defer, function() return active and plugin.server == source end) end)
end

function Library.scan(plugin, done)
    start(plugin, done, function(client, finish, defer, current)
        local WebDAV = require("inkbridge_webdav")
        WebDAV.list_folder(client, client.server.url or "", function(ok, items)
            if not current() then return end
            if not ok or type(items) ~= "table" then finish(false, "无法读取 WebDAV 书库目录。") return end
            local rows, seen, skipped, index = {}, {}, 0, 0
            local root_items = items
            local remote_books, folders, walked = {}, {}, {}
            for _, item in ipairs(root_items) do
                if item.text:sub(1, 1) ~= "." and item.is_file and book_file(item.text) then
                    local rel = item.url
                    if WebDAV._is_safe_remote_path(rel) then
                        remote_books[#remote_books + 1] = { path = rel, title = item.text, item = item }
                    end
                elseif visible_folder(item.text) and item.is_folder and type(item.url) == "string"
                        and WebDAV._is_safe_remote_path(item.url) then
                    folders[#folders + 1] = { url = item.url, depth = 1 }
                end
            end
            local folder_index = 1
            local next_item
            local function walk_next()
                if not current() then return end
                local folder = folders[folder_index]
                if not folder then
                    local sync_server = client.sync_server
                    if type(sync_server) ~= "table" or sync_server.type ~= "webdav"
                            or sync_server.url == client.server.url then
                        table.sort(items, function(a, b) return (tonumber(a.modification) or 0) > (tonumber(b.modification) or 0) end)
                        defer(next_item)
                    else
                        local sync_client = Library.client(client, sync_server)
                        WebDAV.list_folder(sync_client, sync_server.url or "", function(listed, history_items)
                            if not current() then return end
                            if not listed or type(history_items) ~= "table" then
                                skipped = skipped + 1
                                history_items = {}
                            end
                            items = history_items
                            client = sync_client
                            table.sort(items, function(a, b) return (tonumber(a.modification) or 0) > (tonumber(b.modification) or 0) end)
                            defer(next_item)
                        end)
                    end
                    return
                end
                folder_index = folder_index + 1
                if walked[folder.url] or folder.depth > 5 then return walk_next() end
                walked[folder.url] = true
                WebDAV.list_folder(client, folder.url, function(listed, children)
                    if not current() then return end
                    if not listed or type(children) ~= "table" then
                        skipped = skipped + 1
                        defer(walk_next)
                        return
                    end
                    for _, child in ipairs(children) do
                        if child.text:sub(1, 1) ~= "." and child.is_file and book_file(child.text) then
                            if WebDAV._is_safe_remote_path(child.url) then
                                remote_books[#remote_books + 1] = {
                                    path = child.url, title = child.text, item = child,
                                }
                            end
                        elseif visible_folder(child.text) and child.is_folder and type(child.url) == "string"
                                and WebDAV._is_safe_remote_path(child.url) then
                            folders[#folders + 1] = { url = child.url, depth = folder.depth + 1 }
                        end
                    end
                    defer(walk_next)
                end, true)
            end
            next_item = function()
                local item, prefix, title
                repeat
                    index = index + 1
                    item = items[index]
                    if not item then finish(true, rows, skipped, remote_books, folders) return end
                    if item.is_file then prefix, title = candidate(client.server, item) end
                until prefix and not seen[item.url]
                seen[item.url] = true
                WebDAV.download(client, item.url, function(read, entry, _, etag)
                    if not current() then return end
                    if read and entry and full_id(entry.book_id) and entry.book_id:sub(1, 8) == prefix then
                        local book_title = entry.book_name or title or ("书籍 · " .. prefix)
                        local ext = book_title:match("%.([^%.]+)$")
                        ext = ext and ext:lower()
                        if ext ~= "log" and ext ~= "json" and ext ~= "lua" and ext ~= "cfg" then
                            rows[#rows + 1] = {
                                item = item, server = client.server, book_id = entry.book_id, etag = etag,
                                title = book_title,
                                record = {
                                    source = type(entry.device_label) == "string" and entry.device_label or "墨桥",
                                    time = entry.updated_at, observed_at = item.modification,
                                    percent = entry.character_percent or entry.pos_percent or entry.percent,
                                    text = type(entry.text_anchor) == "string" and entry.text_anchor or "",
                                },
                            }
                        else skipped = skipped + 1 end
                    else skipped = skipped + 1 end
                    defer(next_item)
                end)
            end
            walk_next()
        end, true)
    end)
end

function Library.delete_cloud(plugin, book, row, done)
    local WebDAV = require("inkbridge_webdav")
    if not row or not full_id(row.book_id) or (book.id and book.id ~= row.book_id)
            or row.server ~= plugin.server or candidate(plugin.server, row.item) ~= row.book_id:sub(1, 8) then
        done(false, "书籍或记录身份无法核对，未删除。") return
    end
    if not WebDAV.strong_etag(row.etag) then
        done(false, "服务器未提供可验证的记录版本，未删除。") return
    end
    start(plugin, done, function(client, finish, _, current)
        if book.file and require("inkbridge_state").book_id(book.file) ~= row.book_id then
            finish(false, "本机书籍身份已变化，未删除。") return
        end
        WebDAV.download(client, row.item.url, function(ok, entry, _, etag)
            if not current() then return end
            if not ok or not entry or entry.book_id ~= row.book_id or etag ~= row.etag then
                finish(false, "云端记录已变化或无法核对，未删除。") return
            end
            WebDAV.delete_file(client, row.item.url, function(deleted)
                finish(deleted, deleted and "已删除这条云端记录。" or "服务器未确认删除，请刷新核对。")
            end, etag)
        end)
    end)
end

function Library.delete_local(row)
    return History.remove_record(row.file, row.book_id, row.record)
end

return Library
