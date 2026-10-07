-- inkbridge_moonsync.lua ——「从静读天下(Moon+ Reader)读取进度」。
--
-- 静读天下把每本书的进度写在云端 `<书名>.epub.po`(单行纯文本)。
-- 格式与实测解码见 墨桥-samples/po-findings.md:
--   `*` 章节序号(0 基,= KOReader 的 DocFragment 序号 − 1)—— 决定位置
--   `#` 该章节内的字符偏移                                —— 决定位置
--   `:%`/首个常量/`@` 与定位无关,只读不改。
--
-- 本模块负责:
--   1) 按**用户指定**的目录取回当前书的 .po(**只读**,绝不改动静读天下的文件);
--   2) 解析出 (章节序号, 章内字符偏移);
--   3) 用 ffi/archiver 打开本机 EPUB,取出该章节正文;
--   4) 从正文里截一小段文字当锚点,交给已有的跳转流程 WebDAV.confirm_jump。
--
-- 为什么自己发 GET 而不用云端 provider:
--   provider 的 downloadFile 本身也是直连 GET(providers/webdav.lua:142),
--   但它把地址拆成 base.address + server.url 两段,无法指向目标目录之外。
--   自己发请求后,目录既可以是"相对当前 WebDAV 目标",也可以是"从服务器根算起的绝对路径",
--   而且完全不依赖 provider 的内部实现。
--
-- 为什么用"文本锚点"而不是直接拼 xpointer:分页模式下 KOReader 的 GotoXPointer 会把
-- xpointer 换算成页码,而直接拼 DOM 路径又依赖每本书的元素嵌套;文本锚点是已验证可用、
-- 且与 DOM 结构无关的路子。直接拼 xpointer 留作后续优化(更快,但要先验证结构一致)。

local Moon        = require("inkbridge_moon")
local WebDAV      = require("inkbridge_webdav")
local InfoMessage = require("ui/widget/infomessage")
local UIManager   = require("ui/uimanager")

local Moonsync = {}

-- 默认目录仅作占位提示;实际以用户设置为准(见 设置 → 静读天下同步目录)。
Moonsync.DEFAULT_DIR = "Apps/Books/.Moon+/Cache"
Moonsync.SNIPPET_LEN = 20
Moonsync.DIR_SETTING = "inkbridge_moon_dir"

local function show(text)
    UIManager:show(InfoMessage:new{ text = text, timeout = 4 })
end

-- 当前目录设置。**刻意不做自动探测**:目录猜错会读到别的书的进度,
-- 而这类错误用户很难察觉,所以宁可让他填一次。
function Moonsync.get_dir()
    local raw = G_reader_settings and G_reader_settings:readSetting(Moonsync.DIR_SETTING)
    return Moon.normalize_dir(raw, Moonsync.DEFAULT_DIR)
end

function Moonsync.set_dir(dir)
    if G_reader_settings then
        G_reader_settings:saveSetting(Moonsync.DIR_SETTING, Moon.normalize_dir(dir, Moonsync.DEFAULT_DIR))
    end
end

-- 直接取回 .po 的文本内容;返回 内容 或 nil + 原因(不抛异常)。
function Moonsync.fetch_po(plugin)
    local doc = plugin and plugin.ui and plugin.ui.document
    if not doc or type(doc.file) ~= "string" then return nil, "当前没有打开的书" end

    local server = plugin and plugin.server
    if type(server) ~= "table" or server.type ~= "webdav" then
        return nil, "还没有设置 WebDAV 目标"
    end

    local filename = Moon.po_filename(doc.file)
    if not filename then return nil, "无法确定这本书的文件名" end

    local url = Moon.build_url(server.address, server.url, Moonsync.get_dir(), filename)

    local ok_http, http = pcall(require, "socket.http")
    local ok_sock, socket = pcall(require, "socket")
    local ok_ltn12, ltn12 = pcall(require, "ltn12")
    local ok_util, socketutil = pcall(require, "socketutil")
    if not (ok_http and ok_sock and ok_ltn12) then
        return nil, "本机缺少网络模块"
    end

    local sink = {}
    if ok_util and socketutil then
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    end
    local code, _, status = socket.skip(1, http.request{
        url      = url,
        method   = "GET",
        sink     = ltn12.sink.table(sink),
        user     = server.username,
        password = server.password,
    })
    if ok_util and socketutil then socketutil:reset_timeout() end

    if tonumber(code) ~= 200 then
        return nil, string.format("服务器返回 %s（%s）", tostring(code), tostring(status or ""))
    end
    local body = table.concat(sink)
    if body == "" then return nil, "拿到的是空文件" end
    if body:sub(1, 1) == "<" then
        return nil, "拿到的是网页而不是进度文件（地址或权限可能不对）"
    end
    return body
end

-- 打开 EPUB 取第 section_index(0 基)个正文章节的纯文本。
-- 失败返回 nil + 原因;调用方据此提示用户,绝不乱跳。
function Moonsync.section_text(epub_path, section_index)
    local ok_req, Archiver = pcall(require, "ffi/archiver")
    if not ok_req or type(Archiver) ~= "table" or not Archiver.Reader then
        return nil, "本机没有归档模块,读不了 EPUB"
    end

    local arc = Archiver.Reader:new()
    local ok_open, opened = pcall(function() return arc:open(epub_path) end)
    if not ok_open or not opened then return nil, "打不开 EPUB 文件" end

    local function close() pcall(function() arc:close() end) end

    local opf_key
    pcall(function()
        for entry in arc:iterate() do
            local p = entry.path or entry.key or entry.name
            if p and not opf_key and p:lower():sub(-4) == ".opf" then opf_key = p end
        end
    end)
    if not opf_key then close(); return nil, "EPUB 里没有 .opf" end

    local ok_read, opf = pcall(function() return arc:extractToMemory(opf_key) end)
    if not ok_read or type(opf) ~= "string" then close(); return nil, "读不出 .opf" end

    -- manifest: id → href   注意两点:
    --   * "<item%s" 不会匹配到 <itemref(要求 "item" 后面跟空白);
    --   * 属性引号两种都要认 —— 有的书用单引号。
    --     (不要用 [[...]] 长字符串写这两个模式:内容里的 "]" 会与结束符的 "]" 相邻,
    --      长字符串会提前闭合,导致语法错误。)
    local manifest = {}
    for tag in opf:gmatch("<item%s[^>]*>") do
        local id   = tag:match("id=[\"']([^\"']+)[\"']")
        local href = tag:match("href=[\"']([^\"']+)[\"']")
        if id and href then manifest[id] = href end
    end

    -- spine 顺序,只保留正文类条目 —— 与 Python 侧验证过的索引口径保持一致。
    -- 但若按扩展名筛完一个都不剩(说明本书命名超出预期),退回未筛选的完整 spine:
    -- 宁可索引可能错位,也不要整本书都读不了。
    local spine_all, spine_html = {}, {}
    for idref in opf:gmatch("<itemref[^>]*idref=[\"']([^\"']+)[\"']") do
        local href = manifest[idref]
        if href then
            spine_all[#spine_all + 1] = href
            if Moon.is_html_href(href) then spine_html[#spine_html + 1] = href end
        end
    end
    local spine = #spine_html > 0 and spine_html or spine_all

    local href = spine[section_index + 1]
    if not href then
        close()
        return nil, string.format("章节序号 %d 超出本书范围（本书共 %d 章）",
                                  section_index, #spine)
    end

    local base = opf_key:match("^(.*)/[^/]*$")
    local key  = (base and base ~= "") and (base .. "/" .. href) or href
    local html
    pcall(function() html = arc:extractToMemory(key) end)
    if type(html) ~= "string" then
        pcall(function() html = arc:extractToMemory(href) end)     -- 有的书 href 已是完整路径
    end
    close()
    if type(html) ~= "string" then return nil, "读不出该章节内容" end
    return Moon.plain_text(html)
end

-- 主流程:取回 .po → 解析 → 取章节正文 → 截锚点 → 复用已有跳转确认流程
function Moonsync.import_from_moon(plugin)
    local body, ferr = Moonsync.fetch_po(plugin)
    if not body then
        show("墨桥：没能取到静读天下的进度文件。\n" .. tostring(ferr)
            .. "\n目录：" .. Moonsync.get_dir())
        return
    end

    local po, perr = Moon.parse(body)
    if not po then
        show("墨桥：静读天下的进度文件格式不认识（" .. tostring(perr) .. "）。")
        return
    end

    local doc = plugin.ui.document
    local section, serr = Moonsync.section_text(doc.file, po.star)
    if not section then
        show("墨桥：读不出这本书的对应章节（" .. tostring(serr) .. "）。")
        return
    end

    local snippet = Moon.snippet(section, po.hash, Moonsync.SNIPPET_LEN)
    if not snippet or Moon.utf8_len(snippet) < 6 then
        show("墨桥：静读天下的位置在本机定位不到（两边的章节结构可能不同）。")
        return
    end

    -- 复用已有机制:文本锚点 + 内容比例消歧 + 询问用户 + 展示定位方式
    local ok_jump, jerr = pcall(function()
        WebDAV.confirm_jump(plugin, {
            text_anchor  = snippet,
            pos_percent  = po.pct / 100,
            percent      = po.pct / 100,
            device_label = "静读天下",
        })
    end)
    if not ok_jump then
        show("墨桥：跳转失败（" .. tostring(jerr) .. "）。")
    end
end

return Moonsync
