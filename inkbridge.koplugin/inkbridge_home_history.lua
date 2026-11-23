-- 首页只保留实际遇到的同步正文，不扫描书库、不联网、不伪造阅读历史。
local History = { KEY = "inkbridge_home_history", MAX_BOOKS = 24, MAX_RECORDS = 3 }

local function short(text, count)
    if type(text) ~= "string" then return "" end
    local n, last = 0, 0
    for i = 1, #text do
        local b = text:byte(i)
        if b < 128 or b >= 192 then
            n = n + 1
            if n > count then return text:sub(1, last) end
        end
        last = i
    end
    return text
end

local function valid_time(value)
    local timestamp = tonumber(value)
    if not timestamp or timestamp ~= timestamp or timestamp == math.huge or timestamp == -math.huge then
        return nil
    end
    local ok, formatted = pcall(os.date, "%m-%d %H:%M", timestamp)
    return ok and formatted and timestamp or nil
end

-- 老缓存或云端载荷可能包含超出平台日期范围的数值；显示时安全退回读取时间。
function History.format_time(record)
    record = type(record) == "table" and record or {}
    local original = valid_time(record.time)
    local timestamp = original or valid_time(record.observed_at) or os.time()
    return os.date("%m-%d %H:%M", timestamp), original ~= nil
end

function History.load()
    local settings = G_reader_settings
    local data = settings and settings:readSetting(History.KEY)
    return type(data) == "table" and data.version == 1 and type(data.books) == "table"
        and data or { version = 1, books = {} }
end

local function cached_records(book)
    return book and type(book.records) == "table" and book.records or {}
end

-- 不原地改设置表，避免缓存中的表被别处持有；相同来源的相同位置不会占满三条。
function History.add(file, entry, source, observed_at, book_id, note, chapter)
    if type(file) ~= "string" or file == "" or type(entry) ~= "table" then return false end
    local text = short(entry.text_anchor, 160)
    if text == "" or not text:find("%S") then return false end
    local data, books = History.load(), {}
    local records, existing_preview = {}, nil
    source = short(source or "墨桥", 64)
    for _, book in ipairs(data.books) do
        if type(book) == "table" and book.file == file then
            if not book_id or not book.book_id or book.book_id == book_id then
                for _, r in ipairs(cached_records(book)) do
                    if type(r) == "table" then
                        if r.text == text and r.source == source then existing_preview = r
                        else records[#records + 1] = r end
                    end
                end
            end
        elseif type(book) == "table" and type(book.file) == "string" then
            books[#books + 1] = book
        end
    end
    table.insert(records, 1, {
        text = text, source = source,
        time = valid_time(entry.updated_at), -- 无效/缺失时间不冒充对端阅读时间。
        observed_at = valid_time(observed_at) or os.time(),
        percent = tonumber(entry.character_percent or entry.pos_percent or entry.percent),
        note = short(note, 120),
        chapter = short(chapter or entry.home_chapter or (existing_preview and existing_preview.chapter), 120),
        excerpt = existing_preview and existing_preview.excerpt,
        preview_version = existing_preview and existing_preview.preview_version,
        preview_stamp = existing_preview and existing_preview.preview_stamp,
        preview_status = existing_preview and existing_preview.preview_status,
    })
    table.sort(records, function(a, b)
        local at = tonumber(a.time or a.observed_at) or 0
        local bt = tonumber(b.time or b.observed_at) or 0
        if at == bt then return (a.observed_at or 0) > (b.observed_at or 0) end
        return at > bt
    end)
    while #records > History.MAX_RECORDS do table.remove(records) end
    table.insert(books, 1, { file = file, book_id = book_id, records = records })
    while #books > History.MAX_BOOKS do table.remove(books) end
    if not G_reader_settings then return false end
    G_reader_settings:saveSetting(History.KEY, { version = 1, books = books })
    return true
end

function History.remove_record(file, book_id, selected)
    if type(file) ~= "string" or type(selected) ~= "table" or not G_reader_settings then return false end
    local data, books, removed = History.load(), {}, false
    for _, book in ipairs(data.books) do
        if type(book) == "table" and book.file == file and book.book_id == book_id and not removed then
            local records = {}
            for _, record in ipairs(cached_records(book)) do
                if record == selected and not removed then removed = true
                else records[#records + 1] = record end
            end
            books[#books + 1] = { file = file, book_id = book_id, records = records }
        elseif type(book) == "table" and type(book.file) == "string" then
            books[#books + 1] = book
        end
    end
    if not removed then return false end
    G_reader_settings:saveSetting(History.KEY, { version = 1, books = books })
    return true
end

-- 原记录在读取期间被删除或替换，就不补回；只更新仍然存在的同一条缓存。
function History.storePreviews(file, book_id, originals, previews, stamp)
    local pending, books, changed = {}, {}, 0
    for i, original in ipairs(originals) do pending[original] = previews[i] end
    for _, book in ipairs(History.load().books) do
        if type(book) == "table" and book.file == file and book.book_id == book_id then
            local updated, records = {}, {}
            for key, value in pairs(book) do updated[key] = value end
            for _, record in ipairs(cached_records(book)) do
                local preview = pending[record]
                if preview then
                    local copy = {}
                    for key, value in pairs(record) do copy[key] = value end
                    copy.chapter = short(preview.chapter or record.chapter, 120)
                    copy.excerpt = short(preview.excerpt, 220)
                    copy.preview_stamp, copy.preview_version, copy.preview_status = stamp, 1, preview.status
                    records[#records + 1], changed = copy, changed + 1
                else records[#records + 1] = record end
            end
            updated.records = records
            books[#books + 1] = updated
        else books[#books + 1] = book end
    end
    if changed == 0 then return false end
    G_reader_settings:saveSetting(History.KEY, { version = 1, books = books })
    return true
end

-- 预览写盘失败不得影响已有同步流程。
function History.relocate(file, destination)
    local books = {}
    for _, book in ipairs(History.load().books) do
        if book.file ~= file then books[#books + 1] = book
        elseif destination then
            local copy = {}
            for key, value in pairs(book) do copy[key] = value end
            copy.file, copy.title = destination, destination:match("([^/]+)$")
            books[#books + 1] = copy
        end
    end
    G_reader_settings:saveSetting(History.KEY, { version = 1, books = books })
end

function History.captureChapter(ui, entry)
    if type(entry) ~= "table" then return end
    if type(entry.home_chapter) == "string" and entry.home_chapter ~= "" then return entry.home_chapter end
    local document, toc = ui and ui.document, ui and ui.toc
    if not document or not toc or type(toc.getTocTitleByPage) ~= "function" then return end
    if entry.book_file and entry.book_file ~= document.file then return end
    local target = entry.xpointer
    if type(target) ~= "string" or type(document.isXPointerInDocument) ~= "function" then return end
    local ok, chapter = pcall(function()
        if not document:isXPointerInDocument(target) then return end
        return toc:getTocTitleByPage(target)
    end)
    return ok and type(chapter) == "string" and chapter ~= "" and short(chapter, 120) or nil
end

function History.observe(plugin, entry, source, snapshot_file, snapshot_book_id)
    local ok, saved = pcall(function()
        local ui = plugin and plugin.ui
        local file = snapshot_file or (ui and ui.document and ui.document.file)
        if not file then return false end
        local id = snapshot_book_id or require("inkbridge_state").book_id(file, ui)
        local chapter = entry.home_chapter
        if ui and ui.document and ui.document.file == file then chapter = History.captureChapter(ui, entry) end
        return History.add(file, entry, source, os.time(), id, entry.home_note, chapter)
    end)
    return ok and saved or false
end

-- 默认最近三本，历史页可取全部；始终按 KOReader 阅读历史排序，不按同步时间排序。
function History.recent(hist, exists, limit)
    local result, seen, by_file = {}, {}, {}
    for _, book in ipairs(History.load().books) do
        if type(book) == "table" and type(book.file) == "string" then by_file[book.file] = book end
    end
    for _, item in ipairs(hist or {}) do
        if type(item) == "table" and type(item.file) == "string" and not seen[item.file] and not item.dim
                and (not exists or exists(item.file)) then
            seen[item.file] = true
            local cached = by_file[item.file]
            result[#result + 1] = {
                file = item.file, title = item.file:match("([^/\\]+)$") or item.file,
                book_id = cached and cached.book_id,
                records = cached_records(cached),
            }
            if #result == (limit or 3) then break end
        end
    end
    return result
end

return History
