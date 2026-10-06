-- inkbridge_moonsync.lua ——「从静读天下(Moon+ Reader)读取进度」。
--
-- 静读天下把每本书的进度写在云端 `<书名>.epub.po`(单行纯文本),
-- 目录为 `Apps/Books/.Moon+/Cache/`。格式与实测解码见 墨桥-samples/po-findings.md:
--   `*` 章节序号(0 基,= KOReader 的 DocFragment 序号 − 1)—— 决定位置
--   `#` 该章节内的字符偏移                                —— 决定位置
--   `:%`/首个常量/`@` 与定位无关,只读不改。
--
-- 本模块负责:
--   1) 定位并下载当前书的 .po(**只读**,绝不改动静读天下的文件);
--   2) 解析出 (章节序号, 章内字符偏移);
--   3) 用 ffi/archiver 打开本机 EPUB,取出该章节正文;
--   4) 从正文里截一小段文字当锚点,交给已有的跳转流程 WebDAV.confirm_jump。
--
-- 为什么用"文本锚点"而不是直接拼 xpointer:分页模式下 KOReader 的 GotoXPointer 会把
-- xpointer 换算成页码,而直接拼 DOM 路径又依赖每本书的元素嵌套;文本锚点是已验证可用、
-- 且与 DOM 结构无关的路子。直接拼 xpointer 留作后续优化(更快,但要先验证结构一致)。

local Moon       = require("inkbridge_moon")
local WebDAV     = require("inkbridge_webdav")
local InfoMessage = require("ui/widget/infomessage")
local UIManager   = require("ui/uimanager")

local Moonsync = {}

-- 静读天下的云端缓存目录(相对 WebDAV 目标根目录)。
-- 注意:要让这个路径可达,WebDAV 目标应指向网盘账号的根(或同时包含 books 与 Apps 的层级)。
Moonsync.MOON_DIR    = "Apps/Books/.Moon+/Cache"
Moonsync.SNIPPET_LEN = 20

local function show(text)
    UIManager:show(InfoMessage:new{ text = text, timeout = 4 })
end

local function basename(path)
    return (tostring(path):gsub("\\", "/"):match("([^/]+)$")) or tostring(path)
end

-- 由本机书籍路径推算云端 .po 路径:`…/死人经.epub` → `Apps/Books/.Moon+/Cache/死人经.epub.po`
function Moonsync.po_remote_path(book_file)
    if type(book_file) ~= "string" or book_file == "" then return nil end
    return Moonsync.MOON_DIR .. "/" .. basename(book_file) .. ".po"
end

-- HTML → 纯文本:去标签、解几个常见实体、去掉**所有**空白。
-- 去空白是必须的:静读天下的章内偏移是按"去空白后的字符数"计的(已实测)。
local function plain_text(html)
    local t = html:gsub("<[^>]*>", "")
    t = t:gsub("&nbsp;", "")
    t = t:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
         :gsub("&quot;", '"'):gsub("&apos;", "'")
    t = t:gsub("&#(%d+);", function(d)
        local n = tonumber(d)
        if n and n < 128 then return string.char(n) end
        return ""      -- 非 ASCII 数字实体少见,忽略以免口径错乱
    end)
    return (t:gsub("%s+", ""))
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

    -- manifest: id → href   (注意 "<item%s" 不会匹配到 <itemref)
    local manifest = {}
    for tag in opf:gmatch("<item%s[^>]*>") do
        local id   = tag:match('id="([^"]+)"')
        local href = tag:match('href="([^"]+)"')
        if id and href then manifest[id] = href end
    end

    -- spine 顺序,只保留 html 类条目 —— 与 Python 侧验证过的索引口径保持一致
    local spine = {}
    for idref in opf:gmatch('<itemref[^>]*idref="([^"]+)"') do
        local href = manifest[idref]
        if href and href:lower():match("%.html?$") then
            spine[#spine + 1] = href
        end
    end

    local href = spine[section_index + 1]
    if not href then close(); return nil, "章节序号超出本书范围" end

    local base = opf_key:match("^(.*)/[^/]*$")
    local key  = (base and base ~= "") and (base .. "/" .. href) or href
    local html
    pcall(function() html = arc:extractToMemory(key) end)
    if type(html) ~= "string" then
        pcall(function() html = arc:extractToMemory(href) end)     -- 有的书 href 已是完整路径
    end
    close()
    if type(html) ~= "string" then return nil, "读不出该章节内容" end
    return plain_text(html)
end

-- 主流程:读云端 .po → 解析 → 取章节正文 → 截锚点 → 复用已有跳转确认流程
function Moonsync.import_from_moon(plugin)
    local ui  = plugin and plugin.ui
    local doc = ui and ui.document
    if not doc or type(doc.file) ~= "string" then
        show("墨桥：当前没有打开的书。")
        return
    end

    local remote_path = Moonsync.po_remote_path(doc.file)
    if not remote_path then
        show("墨桥：无法确定这本书的文件名。")
        return
    end

    WebDAV.download(plugin, remote_path, function(ok, local_path, err)
        if not ok then
            show("墨桥：云端没有找到静读天下的进度文件。\n" .. tostring(WebDAV.describe_error(err)))
            return
        end

        local f = io.open(local_path, "r")
        if not f then
            show("墨桥：读不到下载下来的进度文件。")
            return
        end
        local line = f:read("*l") or ""
        f:close()

        local po, perr = Moon.parse(line)
        if not po then
            show("墨桥：静读天下的进度文件格式不认识（" .. tostring(perr) .. "）。")
            return
        end

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
                updated_at   = nil,
            })
        end)
        if not ok_jump then
            show("墨桥：跳转失败（" .. tostring(jerr) .. "）。")
        end
    end)
end

return Moonsync
