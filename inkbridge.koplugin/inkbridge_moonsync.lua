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
local ConfirmBox  = require("ui/widget/confirmbox")
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

-- 从已打开的归档里解析出 (spine 正文章节表, opf 所在目录)。调用方负责关闭归档。
-- 单独抽出来是因为**两个方向都要用**:读取只要一章,写回算 `:%` 要遍历全书。
local function spine_of(arc)
    local opf_key
    pcall(function()
        for entry in arc:iterate() do
            local p = entry.path or entry.key or entry.name
            if p and not opf_key and p:lower():sub(-4) == ".opf" then opf_key = p end
        end
    end)
    if not opf_key then return nil, nil, "EPUB 里没有 .opf" end

    local ok_read, opf = pcall(function() return arc:extractToMemory(opf_key) end)
    if not ok_read or type(opf) ~= "string" then return nil, nil, "读不出 .opf" end

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
    local base = opf_key:match("^(.*)/[^/]*$")
    return spine, (base and base ~= "") and base or "", nil
end

-- 打开归档读某个条目;rar/zip 内部的路径可能是 "OEBPS/Text/x.xhtml" 也可能已是完整路径。
local function extract_any(arc, key, href)
    local data
    pcall(function() data = arc:extractToMemory(key) end)
    if type(data) ~= "string" and href and href ~= key then
        pcall(function() data = arc:extractToMemory(href) end)
    end
    return data
end

-- 读第 section_index(0 基)章的**原始 HTML**。
function Moonsync.section_html(epub_path, section_index)
    local ok_req, Archiver = pcall(require, "ffi/archiver")
    if not ok_req or type(Archiver) ~= "table" or not Archiver.Reader then
        return nil, "本机没有归档模块,读不了 EPUB"
    end

    local arc = Archiver.Reader:new()
    local ok_open, opened = pcall(function() return arc:open(epub_path) end)
    if not ok_open or not opened then return nil, "打不开 EPUB 文件" end
    local function close() pcall(function() arc:close() end) end

    local spine, base, err = spine_of(arc)
    if not spine then close(); return nil, err end

    local href = spine[section_index + 1]
    if not href then
        close()
        return nil, string.format("章节序号 %d 超出本书范围（本书共 %d 章）",
                                  section_index, #spine)
    end

    local key = (base ~= "") and (base .. "/" .. href) or href
    local html = extract_any(arc, key, href)
    close()
    if type(html) ~= "string" then return nil, "读不出该章节内容" end
    return html
end

-- 读取方向:只要块级文本数组(与既有行为一致)。
function Moonsync.section_blocks(epub_path, section_index)
    local html, err = Moonsync.section_html(epub_path, section_index)
    if not html then return nil, err end
    return Moon.blocks_from_html(html)
end

-- 写回方向:要保留标签名,才能把 KOReader 的 `p[N]` 换算成章内字符偏移。
function Moonsync.section_blocks_tagged(epub_path, section_index)
    local html, err = Moonsync.section_html(epub_path, section_index)
    if not html then return nil, err end
    return Moon.blocks_tagged_from_html(html)
end

-- 全书字数与各章起始偏移 —— 写回时 `:%` 需要"整本书百分比"。
--
-- 这是一次**全量遍历**(1222 章的书约几秒),所以结果按书缓存进 G_reader_settings,
-- 之后读写都即刻命中。缓存键带上文件大小与修改时间,书换了就自动失效。
function Moonsync.book_metrics(epub_path)
    local stamp = ""
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok_lfs and lfs and type(lfs.attributes) == "function" then
        local ok_a, attr = pcall(lfs.attributes, epub_path)
        if ok_a and type(attr) == "table" then
            stamp = string.format("|%s|%s", tostring(attr.size), tostring(attr.modification))
        end
    end
    local cache_key = "inkbridge_moon_metrics:" .. tostring(epub_path) .. stamp
    if G_reader_settings then
        local cached = G_reader_settings:readSetting(cache_key)
        if type(cached) == "table" and type(cached.total) == "number"
                and type(cached.starts) == "table" and cached.total > 0 then
            return cached, true
        end
    end

    local ok_req, Archiver = pcall(require, "ffi/archiver")
    if not ok_req or type(Archiver) ~= "table" or not Archiver.Reader then return nil end
    local arc = Archiver.Reader:new()
    local ok_open, opened = pcall(function() return arc:open(epub_path) end)
    if not ok_open or not opened then return nil end
    local function close() pcall(function() arc:close() end) end

    local spine, base, err = spine_of(arc)
    if not spine then close(); return nil, err end

    local starts, total = {}, 0
    for i = 1, #spine do
        starts[i] = total
        local href = spine[i]
        local key = (base ~= "") and (base .. "/" .. href) or href
        local html = extract_any(arc, key, href)
        if type(html) == "string" then
            local blocks = Moon.blocks_from_html(html)
            for j = 1, #blocks do total = total + Moon.utf8_len(blocks[j]) end
        end
    end
    starts[#spine + 1] = total
    close()
    if total <= 0 then return nil, "全书字数为 0，读不出正文" end

    local metrics = { total = total, starts = starts }
    if G_reader_settings then G_reader_settings:saveSetting(cache_key, metrics) end
    return metrics, false
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
    local blocks, berr = Moonsync.section_blocks(doc.file, po.star)
    if not blocks then
        show("墨桥：读不出这本书的对应章节（" .. tostring(berr) .. "）。")
        return
    end

    -- 片段必须落在同一段内 —— 渲染出来的正文在段与段之间是断开的,
    -- 跨段片段全文搜索永远搜不到(这正是上一版掉进百分比兜底的原因)。
    local snippet = Moon.snippet_in_blocks(blocks, po.hash, Moonsync.SNIPPET_LEN)
    if not snippet then
        show(string.format(
            "墨桥：静读天下的位置在本机定位不到（章内偏移 %d，本章共 %d 段）。",
            po.hash, #blocks))
        return
    end

    -- 复用已有机制:文本锚点 + 内容比例消歧 + 询问用户 + 展示定位方式。
    --
    -- **不要**传 percent:静读天下的 `:%` 是"内容比例",而 percent 在跳转里被当成
    -- "页数比例"去换算页码 —— 直接传会落到完全不同的位置(实测踩过这个坑)。
    -- 内容比例只用于搜索命中时的消歧(pos_percent);搜索不命中就如实报错,
    -- 不碰任何兜底,免得"跳到一个错误的位置"比"报错"更糟。
    local ok_jump, jerr = pcall(function()
        WebDAV.confirm_jump(plugin, {
            text_anchor  = snippet,
            pos_percent  = po.pct / 100,
            device_label = "静读天下",
        })
    end)
    if not ok_jump then
        show("墨桥：跳转失败（" .. tostring(jerr) .. "）。")
    end
end

-- ── 反向写回:KOReader → 静读天下 ──────────────────────────────────────────
--
-- 与读取方向相反,这里会**覆盖**静读天下里这本书的真实进度,所以规矩更严:
--   1) 换算不出位置就报错,绝不"猜一个";
--   2) 覆盖前用 KOReader 自己报回的文字做一次自检;
--   3) 覆盖前把云端原值备份到本地插件目录;
--   4) 写完回读校验,确认云端真的是我们写下去的那一行。

-- 首个常量是**账号级**的,由静读天下自己写入,我们只能照抄。
-- 先在任意一本书上成功同步/读取一次把它记下来,之后连"静读天下从没打开过的书"也能写。
Moonsync.REF_SETTING = "inkbridge_moon_book_ref"
Moonsync.BACKUP_SUBDIR = "moon_backup"

function Moonsync.get_book_ref()
    if not G_reader_settings then return nil end
    local v = G_reader_settings:readSetting(Moonsync.REF_SETTING)
    return (type(v) == "string" and v ~= "") and v or nil
end

function Moonsync.learn_book_ref(book_ref)
    if G_reader_settings and type(book_ref) == "string" and book_ref ~= "" then
        G_reader_settings:saveSetting(Moonsync.REF_SETTING, book_ref)
    end
end

-- 发一个 WebDAV 请求(method 为 "GET" 或 "PUT")。
-- 成功 → 状态码, 状态文本, 响应体, nil
-- 传输层失败 → nil, nil, nil, 原因          (不抛异常)
function Moonsync.request(server, url, method, body)
    local ok_http, http       = pcall(require, "socket.http")
    local ok_sock, socket     = pcall(require, "socket")
    local ok_ltn12, ltn12     = pcall(require, "ltn12")
    local ok_util, socketutil = pcall(require, "socketutil")
    if not (ok_http and ok_sock and ok_ltn12) then return nil, nil, nil, "本机缺少网络模块" end

    local sink = {}
    local req = {
        url      = url,
        method   = method,
        user     = server.username,
        password = server.password,
    }
    if method == "GET" then
        req.sink = ltn12.sink.table(sink)
    else
        req.source  = ltn12.source.string(body or "")
        -- 显式给长度:luasocket 对字符串 source 不一定会自己补,
        -- 而 WebDAV 的 PUT 少了 Content-Length 会被服务器拒。
        req.headers = {
            ["Content-Type"]   = "text/plain; charset=utf-8",
            ["Content-Length"] = tostring(#(body or "")),
        }
    end

    if ok_util and socketutil then
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    end
    local ok, code, _, status = pcall(function()
        return socket.skip(1, http.request(req))
    end)
    if ok_util and socketutil then socketutil:reset_timeout() end
    if not ok then return nil, nil, nil, tostring(code) end

    return tonumber(code), tostring(status or ""),
           (method == "GET") and table.concat(sink) or "", nil
end

-- 把云端原值备份到插件目录(本地,不往云端多写文件)。
function Moonsync.backup_po(plugin, filename, old_body)
    local base = plugin and plugin.path
    if type(base) ~= "string" or base == "" then return nil, "拿不到插件目录" end
    if type(old_body) ~= "string" or old_body == "" then return nil, "没有可备份的内容" end

    local dir = base .. "/" .. Moonsync.BACKUP_SUBDIR
    local ok_util, util = pcall(require, "ffi/util")
    if ok_util and util and type(util.makePath) == "function" then
        pcall(util.makePath, dir)
    else
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        if ok_lfs and lfs then pcall(lfs.mkdir, dir) end
    end

    local path = string.format("%s/%s.%s.bak", dir, filename, os.date("%Y%m%d-%H%M%S"))
    local f = io.open(path, "wb")
    if not f then return nil, "写不进备份文件" end
    f:write(old_body)
    f:close()
    return path
end

-- 真正执行:备份 → PUT → 回读校验。
--
-- opts.silent = true 时不弹窗(供「上传进度」顺手调用,结果由调用方拼进它自己的提示里),
-- 但**失败也照样返回**给调用方,绝不静默吞掉。
-- 返回 是否校验通过, 一句话结果(给用户看)。
function Moonsync._do_push(plugin, job, opts)
    local silent = opts and opts.silent
    local server = plugin.server
    local where = string.format("第 %d 章，章内偏移 %d", job.section, job.hash)

    local backup_path = nil
    if job.old_body then
        backup_path = Moonsync.backup_po(plugin, job.filename, job.old_body)
    end
    local backup_tail = backup_path and ("\n备份：" .. backup_path) or ""

    local code, status, _, err = Moonsync.request(server, job.url, "PUT", job.body)
    if not code then
        local brief = "写入失败（静读天下：" .. tostring(err) .. "）"
        if not silent then
            show("墨桥：" .. brief .. "\n云端内容未被改动。" .. backup_tail)
        end
        return false, brief
    end
    if code < 200 or code > 299 then
        local brief = string.format("写入失败（静读天下：服务器返回 %s）", tostring(code))
        if not silent then
            show("墨桥：" .. brief .. "\n云端内容未被改动。" .. backup_tail)
        end
        return false, brief
    end

    -- 只看回读的正文(第 1、2 个返回值是状态码与状态文本,这里用不上)
    local _, _, body = Moonsync.request(server, job.url, "GET")
    if type(body) == "string" then body = body:gsub("[\r\n]+$", "") end

    local verified = (type(body) == "string" and body == job.body)
    local verdict, brief
    if verified then
        verdict = "回读校验：一致 ✓"
        brief   = "已同步给静读天下（" .. where .. "）"
    elseif type(body) == "string" then
        verdict = "回读校验：**不一致**，云端现在是 " .. body
        brief   = "静读天下已写入，但回读不一致"
    else
        verdict = "回读校验：取不回来"
        brief   = "静读天下已写入，但回读失败"
    end

    if not silent then
        show("墨桥：已写入静读天下。\n" .. where .. "\n" .. verdict
            .. "\n内容：" .. job.body .. backup_tail)
    end
    return verified, brief
end

-- ── 顺手写回:上传进度时自动执行 ──────────────────────────────────────────
--
-- 为什么默认开启:上传进度本身就是在声明"我这边是最新的",顺手把 .po 一并写了,
-- 静读天下就自然跟上,用户不必再多点一次按键。
-- 但它毕竟是**覆盖另一台设备状态**的动作,所以留了开关(菜单里可关)。

Moonsync.AUTO_SETTING = "inkbridge_moon_auto_push"

function Moonsync.auto_enabled()
    if not G_reader_settings then return true end
    local v = G_reader_settings:readSetting(Moonsync.AUTO_SETTING)
    if v == nil then return true end          -- 默认开启
    return v and true or false
end

function Moonsync.set_auto(on)
    if G_reader_settings then
        G_reader_settings:saveSetting(Moonsync.AUTO_SETTING, on and true or false)
    end
end

-- 算出要写入的内容。**不做任何界面动作**,这样上传流程也能直接调用。
--
-- 返回 job 表;或 nil + 人话原因 + 类别:
--   "skip"  = 这次本来就不适用(没开书 / 停在标题上 / 格式不支持),不必打扰用户
--   "error" = 该让用户知道的问题
function Moonsync.build_push_job(plugin)
    local doc = plugin and plugin.ui and plugin.ui.document
    if not doc or type(doc.file) ~= "string" then
        return nil, "当前没有打开的书", "skip"
    end
    local server = plugin and plugin.server
    if type(server) ~= "table" or server.type ~= "webdav" then
        return nil, "还没有设置 WebDAV 目标", "skip"
    end
    if type(doc.getXPointer) ~= "function" then
        return nil, "这本书的格式取不到阅读位置", "skip"
    end

    local xp = doc:getXPointer()
    local pos, perr = Moon.parse_xpointer(xp)
    if not pos then
        return nil, "读不出当前阅读位置（" .. tostring(perr) .. "）", "error"
    end

    local tagged, berr = Moonsync.section_blocks_tagged(doc.file, pos.section)
    if not tagged then
        return nil, "读不出本机这本书的对应章节（" .. tostring(berr) .. "）", "error"
    end

    local hash, oerr, okind = Moon.offset_from_tagged(tagged, pos.p_index, pos.text_offset)
    if not hash then
        return nil, "当前页首不在正文段落内（" .. tostring(oerr) .. "）",
                    (okind == "nop") and "skip" or "error"
    end

    -- 写入前自检:让 KOReader 自己把该位置的文字报一遍,与我们从章节 HTML 里取的对一对。
    -- 这是唯一能在覆盖之前发现"两台设备上的书版本不一致"的机会。
    local checked = "未做（本机没提供该接口）"
    if type(doc.getTextFromXPointer) == "function" then
        local ok_txt, here = pcall(doc.getTextFromXPointer, doc, xp)
        if ok_txt and type(here) == "string" and here ~= "" then
            local texts = {}
            for i, b in ipairs(tagged) do texts[i] = b.text end
            -- 探针**只向后取**:向前借字会让探针起点早于 xpointer,
            -- 而 KOReader 报回的文字是从 xpointer 处开始的,那样必然误判。
            local idx, off = Moon.locate(texts, hash)
            local probe = idx and Moon.compact(Moon.utf8_sub(texts[idx], off + 1, 8)) or ""
            if probe ~= "" and not Moon.compact(here):find(probe, 1, true) then
                return nil, "写入前自检未通过 —— 本机该位置读到的文字与章节正文对不上"
                    .. "（两台设备上的书可能不是同一个版本）", "error"
            end
            checked = "已通过"
        end
    end

    -- 云端现有内容:沿用账号级常量与 @,并作为备份来源
    local old_body = Moonsync.fetch_po(plugin)
    local old = old_body and Moon.parse(old_body) or nil
    local book_ref = (old and old.book_ref) or Moonsync.get_book_ref()
    if not book_ref then
        return nil, "云端还没有这本书的进度文件，无法得知账号级常量"
            .. "（请先在静读天下里同步一次任意一本书）", "error"
    end
    Moonsync.learn_book_ref(book_ref)
    local at = old and old.at or 0

    -- `:%` 是静读天下自己排版下的百分比,精确值算不出来。这里用"全书字符数"算一个
    -- 与排版无关的近似值(实测只改它不影响落点),算不出来就沿用云端旧值并如实标注。
    local pct, pct_note
    local metrics = Moonsync.book_metrics(doc.file)
    if metrics and type(metrics.starts) == "table" and metrics.starts[pos.section + 1] then
        pct = (metrics.starts[pos.section + 1] + hash) / metrics.total * 100
        pct_note = string.format("%.2f%%（按全书字符数算）", pct)
    else
        pct = old and old.pct or 0
        pct_note = string.format("%s%%（沿用云端旧值）", tostring(pct))
    end

    local filename = Moon.po_filename(doc.file)
    return {
        url         = Moon.build_url(server.address, server.url, Moonsync.get_dir(), filename),
        body        = Moon.format(book_ref, pos.section, hash, pct, at),
        old_body    = old_body,
        old_line    = old_body and (old_body:gsub("[\r\n]+$", "")) or nil,
        filename    = filename,
        section     = pos.section,
        hash        = hash,
        p_index     = pos.p_index,
        text_offset = pos.text_offset,
        checked     = checked,
        pct_note    = pct_note,
    }
end

-- 顺手写回:上传进度成功后调用。返回一句话给调用方拼进它自己的提示;
-- 返回 nil 表示"这次不适用",连提示都不必加。**不抛异常、不影响上传结果**。
function Moonsync.auto_push(plugin)
    if not Moonsync.auto_enabled() then return nil end

    local ok, job, err, kind = pcall(Moonsync.build_push_job, plugin)
    if not ok then
        return "静读天下未同步（内部错误：" .. tostring(job) .. "）"
    end
    if not job then
        if kind == "skip" then return nil end
        return "静读天下未同步（" .. tostring(err) .. "）"
    end

    local _, brief = Moonsync._do_push(plugin, job, { silent = true })
    return brief
end

-- 菜单动作(手动):算完先让用户看清"会覆盖什么",确认后才写。
function Moonsync.push_to_moon(plugin)
    local job, err = Moonsync.build_push_job(plugin)
    if not job then
        show("墨桥：无法写入静读天下 —— " .. tostring(err) .. "。")
        return
    end

    local lines = {
        "把本机阅读位置写给静读天下？",
        "",
        string.format("本机位置：DocFragment[%d] 第 %d 个 <p>，段内第 %d 字",
                      job.section + 1, job.p_index, job.text_offset),
        string.format("换算结果：章内偏移 %d", job.hash),
        "写入内容：" .. job.body,
        "进度百分比：" .. job.pct_note,
        "写入前自检：" .. job.checked,
    }
    if job.old_line then
        table.insert(lines, "云端原值：" .. job.old_line .. "（将被覆盖）")
    else
        table.insert(lines, "云端原本没有这本书的文件（将新建）")
    end
    table.insert(lines, "文件名：" .. tostring(job.filename))
    table.insert(lines, "")
    table.insert(lines, "这会覆盖静读天下里这本书的进度；写入前会自动备份原值。")

    UIManager:show(ConfirmBox:new{
        text = table.concat(lines, "\n"),
        ok_text = "写入",
        cancel_text = "取消",
        ok_callback = function() Moonsync._do_push(plugin, job) end,
    })
end

return Moonsync
