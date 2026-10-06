-- inkbridge_state.lua 只处理“阅读位置数据”，不负责界面和网络。
--
-- 一个同步记录大致是：
-- {
--   schema_version = 1,       -- 数据格式版本
--   book_id = "...",          -- 同一本书的内容哈希
--   device_id = "...",        -- 产生记录的设备
--   percent = 0.47,            -- 0 到 1 的完成比例
--   page = 581,                -- 当时的页码（可选）
--   xpointer = "...",         -- EPUB 精确位置（可选）
--   updated_at = 1234567890   -- Unix 时间戳
-- }

local rapidjson = require("rapidjson")
local util = require("util")

local State = {}
State.SCHEMA_VERSION = 1

local function copy_entry(entry)
    local out = {}
    for k, v in pairs(entry or {}) do out[k] = v end
    return out
end

-- 获取书籍身份。
-- 优先读取 KOReader 已经缓存的 partial_md5_checksum，避免重复计算；
-- 没有缓存时才调用 util.partialMD5。相同书籍内容应得到相同 ID，
-- 即使两台设备上的文件路径不同，也能找到同一条云端记录。
function State.book_id(book_path, ui)
    if ui and ui.doc_settings then
        local cached = ui.doc_settings:readSetting("partial_md5_checksum")
        if type(cached) == "string" and cached ~= "" then return cached end
    end
    if type(util.partialMD5) == "function" then
        local ok, value = pcall(util.partialMD5, book_path)
        if ok and type(value) == "string" and value ~= "" then return value end
    end
    return nil, "KOReader could not calculate the book content hash"
end

-- 从 KOReader 当前 ReaderUI 读取阅读位置。
-- rolling 文档通常可以提供 xpointer；页码和百分比用于回退。
function State.read_position(ui)
    local doc = ui and ui.document
    if not doc or not doc.file then return nil, "No open book" end

    local page, total, xpath
    if ui.rolling then
        page = tonumber(ui.rolling.current_page)
        xpath = ui.rolling.xpointer
        if type(xpath) ~= "string" or xpath == "" then xpath = nil end
    end
    if type(doc.getCurrentPage) == "function" then
        local ok, value = pcall(doc.getCurrentPage, doc)
        if ok and tonumber(value) then page = tonumber(value) end
    end
    if type(doc.getPageCount) == "function" then
        local ok, value = pcall(doc.getPageCount, doc)
        if ok and tonumber(value) then total = tonumber(value) end
    end
    if not xpath and type(doc.getXPointer) == "function" then
        local ok, value = pcall(doc.getXPointer, doc)
        if ok and type(value) == "string" and value ~= "" then xpath = value end
    end

    local footer = ui.footer or (ui.view and ui.view.footer)
    local percent = footer and tonumber(footer.percent_finished) or nil
    if not percent and page and total and total > 0 then percent = (page - 1) / total end
    if not percent then percent = 0 end
    if percent > 1 then percent = percent / 100 end

    local book_name = doc.file:match("([^/\\]+)$") or doc.file
    book_name = book_name:gsub("%.[Ee][Pp][Uu][Bb]$", "")

    return {
        schema_version = State.SCHEMA_VERSION,
        book_file = doc.file,
        book_name = book_name,
        percent = math.max(0, math.min(1, percent)),
        page = page,
        total_pages = total,
        xpointer = xpath,
        updated_at = os.time(),
    }
end

-- 把 Lua table 编码为 JSON 文本，准备写入本地或上传到 WebDAV。
function State.encode(entry)
    return rapidjson.encode(entry)
end

-- 从 JSON 文本恢复 Lua table，并检查最基本的数据格式。
-- 任何不认识或损坏的记录都会返回 nil 和错误原因。
function State.decode(text)
    if type(text) ~= "string" or text == "" then return nil, "empty" end
    local ok, value = pcall(rapidjson.decode, text)
    if not ok or type(value) ~= "table" then return nil, "invalid_json" end
    if tonumber(value.schema_version) ~= State.SCHEMA_VERSION then return nil, "unsupported_schema" end
    if type(value.book_id) ~= "string" or value.book_id == "" then return nil, "missing_book_id" end
    if value.book_name ~= nil and type(value.book_name) ~= "string" then return nil, "invalid_book_name" end
    if type(value.percent) ~= "number" or value.percent < 0 or value.percent > 1 then return nil, "invalid_percent" end
    if value.xpointer ~= nil and type(value.xpointer) ~= "string" then return nil, "invalid_xpointer" end
    return value
end

-- 读取一个本地 JSON 文件。
-- 第二个返回值用于区分 missing、invalid_json 等情况。
function State.read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil, "missing" end
    local text = f:read("*a")
    f:close()
    return State.decode(text)
end

-- 原子写入 JSON：先写入 .tmp，再用 rename 替换目标文件。
-- 这样 KOReader 在断电或程序中断时，不容易留下半截 JSON。
function State.write_file(path, entry)
    local parent = path:match("^(.*)[/\\][^/\\]+$")
    if parent then util.makePath(parent) end
    local tmp = path .. ".tmp"
    local f, err = io.open(tmp, "wb")
    if not f then return false, err end
    f:write(State.encode(entry))
    f:close()
    local ok, rename_err = os.rename(tmp, path)
    if not ok then os.remove(tmp); return false, rename_err end
    return true
end

-- 给位置记录补上书籍和设备身份。
-- 复制 table 而不是直接修改原 table，避免产生隐藏的共享引用。
function State.with_identity(entry, book_id, device_id, device_label)
    local out = copy_entry(entry)
    out.book_id = book_id
    out.device_id = device_id
    out.device_label = device_label
    return out
end

return State
