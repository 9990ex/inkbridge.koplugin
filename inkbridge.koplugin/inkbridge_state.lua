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
--   pos_percent = 0.51,       -- 内容在文档总高度中的位置比例（可选，跨排版稳定）
--   text_anchor = "...",      -- 该位置正文的一小段（可选，可用文本搜索找回）
--   updated_at = 1234567890   -- Unix 时间戳
-- }
--
-- 关于后两个字段：percent 来自 ReaderFooter:getBookProgress()，本质是
-- pageno/pages —— 即“页序占本机总页数的比例”，依赖设备排版（两台设备可能是
-- 8922 页 vs 8689 页）。所以它只能当最后的兜底。pos_percent 和 text_anchor
-- 与排版无关，用于 xpointer 在本机解析失败时仍能较精确地还原位置。
-- 三个新字段都是可选的，旧记录缺少它们时自动降级，不会报错。

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
--
-- 取 xpointer 的方式与 KOReader 自带的进度同步一致（KOSync:getLastProgress）：
--   可重排文档 -> ui.rolling:getLastProgress() 即当前 xpointer
--   固定版式   -> ui.paging:getLastProgress()  即当前页首页码
-- 这样跟随上游的接口，避免直接读 ui.rolling.xpointer 这类内部字段。
--
-- 文本锚点要求：空白（%s）与全角空格（U+3000 = E3 80 80）都去掉，
-- 太短的片段（如整页只有两三个字）无法唯一定位，直接放弃。
--
-- 长度必须按“字符”而不是字节来算：UTF-8 下一个汉字占 3 字节，
-- 若按字节限制，6 字节只等于 2 个汉字、32 字节只等于 10 个汉字，
-- 锚点会短到满书误命中。LuaJIT 不带 utf8 库，这里手写首字节计数。
local MIN_ANCHOR_LEN = 6    -- 字符数
local MAX_ANCHOR_LEN = 32   -- 字符数

function State._utf8_len(s)
    if type(s) ~= "string" then return 0 end
    -- 续字节范围 0x80–0xBF；总字节数减去续字节数，即首字节数（= 字符数）。
    -- 注意不能用 [\0-\127\192-\255] 这种写法统计首字节：字符类里放 NUL 会让
    -- Lua 认为模式提前结束并抛 "malformed pattern"（本项目已经踩过这个坑）。
    local _, continuation_bytes = s:gsub("[\128-\191]", "")
    return #s - continuation_bytes
end

function State._utf8_sub(s, n)
    if type(s) ~= "string" or n <= 0 then return "" end
    local count, i = 0, 1
    while i <= #s do
        local byte = s:byte(i)
        local size = 1
        if byte >= 240 then size = 4
        elseif byte >= 224 then size = 3
        elseif byte >= 192 then size = 2 end
        count = count + 1
        if count > n then return s:sub(1, i - 1) end
        i = i + size
    end
    return s
end

function State._make_anchor(text)
    if type(text) ~= "string" then return nil end
    local compact = text:gsub("%s+", ""):gsub("\227\128\128", "")
    if State._utf8_len(compact) < MIN_ANCHOR_LEN then return nil end
    return State._utf8_sub(compact, MAX_ANCHOR_LEN)
end

function State.read_position(ui)
    local doc = ui and ui.document
    if not doc or not doc.file then return nil, "No open book" end

    local page, total, xpath
    -- 首选与上游同款的公开访问器
    local view = ui.rolling or ui.paging
    if view and type(view.getLastProgress) == "function" then
        local ok, progress = pcall(view.getLastProgress, view)
        if ok then
            if type(progress) == "string" and progress ~= "" then
                xpath = progress
            elseif tonumber(progress) then
                page = tonumber(progress)
            end
        end
    end
    if not page and type(doc.getCurrentPage) == "function" then
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

    -- 两个与排版无关的备用锚点，专供“xpointer 在本机解析失败”时使用。
    local pos_percent, text_anchor
    local doc_height = doc.info and tonumber(doc.info.doc_height) or nil
    if xpath and doc_height and doc_height > 0
            and type(doc.getPosFromXPointer) == "function" then
        local ok, pos = pcall(doc.getPosFromXPointer, doc, xpath)
        if ok and tonumber(pos) then
            pos_percent = math.max(0, math.min(1, tonumber(pos) / doc_height))
        end
    end
    if xpath and type(doc.getTextFromXPointer) == "function" then
        -- 该接口返回 xpointer 所在节点（通常是整个段落）的文本
        local ok, text = pcall(doc.getTextFromXPointer, doc, xpath)
        if ok then text_anchor = State._make_anchor(text) end
    end

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
        pos_percent = pos_percent,
        text_anchor = text_anchor,
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
