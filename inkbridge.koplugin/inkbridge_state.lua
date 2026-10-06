-- inkbridge_state.lua 只处理“阅读位置数据”，不负责界面和网络。
--
-- 内存里的 entry（生成云端文件名时要用的字段都在这里）：
-- {
--   schema_version = 1,       -- 数据格式版本
--   book_id = "...",          -- 同一本书的内容哈希
--   device_id = "...",        -- 产生记录的设备
--   book_file = "...",        -- 本机绝对路径（仅本机使用，不写进载荷）
--   book_name = "...",        -- 书名（云端文件名已含，不写进载荷）
--   percent = 0.47,           -- 页序比例（KOReader 状态栏的值）
--   page = 581,               -- 当时的页码
--   total_pages = 8922,
--   xpointer = "...",         -- 精确内容锚点
--   pos_percent = 0.51,       -- 内容在文档总高度中的位置比例（跨排版稳定）
--   text_anchor = "...",      -- 该位置正文的一小段（可用全文搜索找回）
--   updated_at = 1234567890
-- }
--
-- 落盘/上云的**紧凑载荷**（短字段名，约 260 字节）：
-- {"sv":1,"id":"d31f852b…","di":"1791209408-8147","dl":"c7t","pg":1000,"tp":8922,
--  "p":0.11208,"pp":0.11179,"xp":"/body/DocFragment[138]/body/div/p[41]/text().0",
--  "ta":"楼里终于清静了，铁寒锋肚子里…","t":1791262716}
--
-- 关于 percent：它来自 ReaderFooter:getBookProgress()，本质是 pageno/pages，
-- 即「页序占本机总页数的比例」，依赖设备排版（两台设备可能是 8922 页 vs 8689 页），
-- 只能当最后的兜底。pos_percent 与 text_anchor 与排版无关，用于 xpointer
-- 在本机解析失败时仍能较精确地还原位置。三个字段都是可选的：
-- 旧记录缺少它们时自动降级，不会报错。schema_version 保持为 1。

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
-- 若按字节限制，6 字节只等于 2 个汉字，锚点会短到满书误命中。
-- LuaJIT 不带 utf8 库，这里手写首字节计数。
local MIN_ANCHOR_LEN = 6    -- 字符数
local MAX_ANCHOR_LEN = 20   -- 字符数（锚点只用全文搜索定位，20 字已足够唯一；
                            -- 多个命中还会用 pos_percent 消歧，不必更长）

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

-- 从第 start 个字符（1 基）起最多取 count 个字符。
-- _utf8_sub 只能从头部截，取“段落中间的一段”需要这个。
function State._utf8_sub_range(s, start, count)
    if type(s) ~= "string" then return "" end
    start = tonumber(start) or 1
    count = tonumber(count) or 0
    if start < 1 or count <= 0 then return "" end
    local index, char_index = 1, 0
    local first, last
    while index <= #s do
        local byte = s:byte(index)
        local size = 1
        if byte >= 240 then size = 4
        elseif byte >= 224 then size = 3
        elseif byte >= 192 then size = 2 end
        char_index = char_index + 1
        if char_index == start then first = index end
        if first and char_index == start + count - 1 then
            last = index + size - 1
            break
        end
        index = index + size
    end
    if not first then return "" end
    return s:sub(first, last or #s)
end

-- 从 xpointer 结尾的 /text().N 取出字符偏移 N。
-- N 是 crengine 的**字符**偏移（不是字节），与上面几个按字符计算的函数同一口径。
-- xpointer 指向元素而非文本节点时取不到，返回 0。
function State._xpointer_text_offset(xp)
    if type(xp) ~= "string" then return 0 end
    return tonumber(xp:match("/text%(%)%.(%d+)$")) or 0
end

local function compact_text(s)
    return (s:gsub("%s+", ""):gsub("\227\128\128", ""))
end

-- 生成文本锚点。offset 是 xpointer 里的字符偏移（可选）：
--   * 有偏移   -> 从该偏移处开始取 MAX_ANCHOR_LEN 个字符，锚点落在实际阅读位置；
--   * 段落将尽 -> 取不够长度就回退到段落开头（仍比没有锚点好）。
--
-- 重要：偏移必须先在**原始文本**上应用，再压缩空白 —— 反过来会改变字符序号，偏移就错位。
--
-- 为什么要带偏移：getTextFromXPointer 返回的是整个**段落**的文本
-- （cre.cpp 里是 node->getText8()）。只取段落开头的话，降级到文本锚点时会落到段落起点，
-- 误差为“小半个段落”；带上偏移后误差降到几个字。
function State._make_anchor(text, offset)
    if type(text) ~= "string" then return nil end
    local start = (tonumber(offset) or 0) + 1
    local compact = compact_text(State._utf8_sub_range(text, start, MAX_ANCHOR_LEN * 4))
    if State._utf8_len(compact) < MIN_ANCHOR_LEN then
        compact = compact_text(text)
    end
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
        -- 该接口返回 xpointer 所在节点（通常是整个段落）的文本，
        -- 所以要配合 xpointer 里的字符偏移，取到实际阅读位置那一段。
        local ok, text = pcall(doc.getTextFromXPointer, doc, xpath)
        if ok then
            text_anchor = State._make_anchor(text, State._xpointer_text_offset(xpath))
        end
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

-- ── 落盘/上云用的紧凑载荷 ────────────────────────────────────────────────
--
-- 为什么要做这一层：记录会一直躺在云上、并被反复下载，体积越小越好。
-- 原来的记录约 540 字节，其中一大半是可省的：
--   * book_file —— 上传方的**本机绝对路径**（如 /storage/emulated/0/Books/…）。
--                  接收方只靠 book_id 识别书籍，从不读它。约 85 字节纯浪费。
--   * book_name —— 云端文件名本身就带书名（<书名>-<时间>-<设备>.<短哈希>…），
--                  载荷里再存一遍是重复。约 52 字节。
--   * 17 位有效数字的百分比 —— 内容比例保留 5 位小数，在八千页的书里远小于一页。
--   * 长字段名 —— 换成两字母短名。
-- 这些字段仍然保留在**内存**里的 entry 上（生成文件名要用 book_name），
-- 只是不写进载荷。
local PAYLOAD_KEYS = {
    schema_version = "sv",
    book_id        = "id",
    device_id      = "di",
    device_label   = "dl",
    page           = "pg",
    total_pages    = "tp",
    percent        = "p",
    pos_percent    = "pp",
    xpointer       = "xp",
    text_anchor    = "ta",
    updated_at     = "t",
}

local function round5(value)
    local n = tonumber(value)
    if not n then return nil end
    return math.floor(n * 100000 + 0.5) / 100000
end

function State.to_payload(entry)
    if type(entry) ~= "table" then return {} end
    local payload = {}
    for full, short in pairs(PAYLOAD_KEYS) do
        local value = entry[full]
        if value ~= nil then
            if full == "percent" or full == "pos_percent" then
                value = round5(value)
            end
            payload[short] = value
        end
    end
    return payload
end

-- 把载荷还原成内部字段名。**同时接受旧版长字段名**，
-- 这样云上已有的历史记录（0.2.15 及更早写的）仍能正常下载使用。
function State.from_payload(obj)
    if type(obj) ~= "table" then return nil end
    local entry = {}
    for full, short in pairs(PAYLOAD_KEYS) do
        if obj[short] ~= nil then
            entry[full] = obj[short]
        elseif obj[full] ~= nil then
            entry[full] = obj[full]
        end
    end
    -- 旧记录里可能带着这两个字段，原样透传给调用方
    if obj.book_file ~= nil then entry.book_file = obj.book_file end
    if obj.book_name ~= nil then entry.book_name = obj.book_name end
    return entry
end

-- 把 Lua table 编码为紧凑 JSON 文本，准备写入本地或上传到 WebDAV。
function State.encode(entry)
    return rapidjson.encode(State.to_payload(entry))
end

-- 从 JSON 文本恢复 Lua table，并检查最基本的数据格式。
-- 任何不认识或损坏的记录都会返回 nil 和错误原因。
function State.decode(text)
    if type(text) ~= "string" or text == "" then return nil, "empty" end
    local ok, value = pcall(rapidjson.decode, text)
    if not ok or type(value) ~= "table" then return nil, "invalid_json" end
    local entry = State.from_payload(value)
    if tonumber(entry.schema_version) ~= State.SCHEMA_VERSION then
        return nil, "unsupported_schema"
    end
    if type(entry.book_id) ~= "string" or entry.book_id == "" then
        return nil, "missing_book_id"
    end
    if entry.book_name ~= nil and type(entry.book_name) ~= "string" then
        return nil, "invalid_book_name"
    end
    if type(entry.percent) ~= "number" or entry.percent < 0 or entry.percent > 1 then
        return nil, "invalid_percent"
    end
    if entry.xpointer ~= nil and type(entry.xpointer) ~= "string" then
        return nil, "invalid_xpointer"
    end
    return entry
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
