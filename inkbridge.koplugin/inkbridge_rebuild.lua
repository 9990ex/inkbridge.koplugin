-- EPUB 小说的纯文字副本。借鉴月读 reflow/text2epub 的分章与重打包流程（GPL-3.0）。
-- 按 spine 逐文件取字，保留段落，不按屏幕取字，也不合并原有段落。
-- 本模块仅处理文件；调用方在可取消的子进程运行，成功后由主进程发布副本。
local Rebuild = {}
local MAX_ENTRY = 16 * 1024 * 1024
local MAX_TOTAL = 256 * 1024 * 1024
local PART_BYTES = 256 * 1024

local function trim(s)
    return (tostring(s or ""):gsub("　", " "):gsub("\194\160", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

function Rebuild.normalize_text(text)
    return (trim(text):gsub("%s+", " "))
end

local function utf8(cp)
    if not cp or cp < 0 or cp > 0x10FFFF or cp >= 0xD800 and cp <= 0xDFFF
            or cp < 32 and cp ~= 9 and cp ~= 10 and cp ~= 13 then
        error("正文包含无效的字符实体")
    end
    if cp < 128 then return string.char(cp) end
    if cp < 2048 then return string.char(192 + math.floor(cp / 64), 128 + cp % 64) end
    if cp < 65536 then
        return string.char(224 + math.floor(cp / 4096), 128 + math.floor(cp / 64) % 64, 128 + cp % 64)
    end
    return string.char(240 + math.floor(cp / 262144), 128 + math.floor(cp / 4096) % 64,
        128 + math.floor(cp / 64) % 64, 128 + cp % 64)
end

local entities = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " ",
    mdash = "—", ndash = "–", hellip = "…", lsquo = "‘", rsquo = "’", ldquo = "“", rdquo = "”" }
function Rebuild.decode(s)
    -- 单次替换，避免把 &amp;lt; 二次解码成标签。
    return (s:gsub("&([#%w]+);", function(key)
        if key:match("^#[xX]%x+$") then return utf8(tonumber(key:sub(3), 16)) end
        if key:match("^#%d+$") then return utf8(tonumber(key:sub(2))) end
        return entities[key] or "&" .. key .. ";"
    end))
end

local function escape(s)
    return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
        :gsub('"', "&quot;"):gsub("'", "&apos;"))
end

local function localname(s) return (s:match("([^:]+)$") or s):lower() end

local function raw_end(xml, pos, name)
    while true do
        local start = assert(xml:find("<", pos, true), "EPUB 脚本或样式没有结束")
        if xml:sub(start, start + 8) == "<![CDATA[" then
            pos = assert(xml:find("]]>", start + 9, true), "EPUB CDATA 没有结束") + 3
        else
            local closing = xml:match("^</([%w_:.-]+)%s*>", start)
            if closing and closing:lower() == name then return start end
            pos = start + 1
        end
    end
end

-- 标题长度必须按字符算：一个汉字是 3 字节，按字节会把短标题当成正文。
local function char_count(s)
    local n = 0
    for _ in s:gmatch("[^\128-\191]") do n = n + 1 end
    return n
end

-- 引号中的 > 不能结束标签；注释、CDATA 和内部 DTD 分别处理。
-- 不加载 DTD，也不解析外部实体。
local function scan(xml, on_tag, on_text)
    if xml:find("\255\254", 1, true) or xml:find("\254\255", 1, true) or xml:find("%z") then
        error("暂不支持 UTF-16 编码的 EPUB 正文")
    end
    local encoding = xml:sub(1, 200):match("<%?xml.-encoding%s*=%s*['\"]([^'\"]+)")
    if encoding and encoding:lower() ~= "utf-8" and encoding:lower() ~= "utf8"
            and encoding:lower() ~= "us-ascii" then error("暂不支持此 EPUB 编码：" .. encoding) end
    local pos = 1
    while pos <= #xml do
        local start = xml:find("<", pos, true)
        if not start then on_text(Rebuild.decode(xml:sub(pos))); break end
        if start > pos then on_text(Rebuild.decode(xml:sub(pos, start - 1))) end
        if xml:sub(start, start + 3) == "<!--" then
            local finish = assert(xml:find("-->", start + 4, true), "EPUB 注释没有结束")
            pos = finish + 3
        elseif xml:sub(start, start + 8) == "<![CDATA[" then
            local finish = assert(xml:find("]]>", start + 9, true), "EPUB CDATA 没有结束")
            on_text(xml:sub(start + 9, finish - 1)); pos = finish + 3
        else
            local quote, brackets, finish = nil, 0, nil
            for i = start + 1, #xml do
                local c = xml:sub(i, i)
                if quote then
                    if c == quote then quote = nil end
                elseif c == '"' or c == "'" then quote = c
                elseif c == "[" then brackets = brackets + 1
                elseif c == "]" then brackets = math.max(0, brackets - 1)
                elseif c == ">" and brackets == 0 then finish = i; break end
            end
            assert(finish, "EPUB 标签没有结束")
            pos = finish + 1
            local raw = xml:sub(start + 1, finish - 1)
            local closing, name = raw:match("^%s*(/?)%s*([%w_:.-]+)")
            if name then
                local attrs = {}
                for key, q, value in raw:gmatch("([%w_:.-]+)%s*=%s*(['\"])(.-)%2") do
                    attrs[key:lower()] = Rebuild.decode(value)
                end
                local tag, self_closing = localname(name), raw:match("/%s*$") ~= nil
                on_tag(tag, closing == "/", attrs, self_closing)
                -- 脚本和样式的内容不是标记，其中的 < 不能当作标签开头。
                if (tag == "script" or tag == "style") and closing ~= "/" and not self_closing then
                    pos = raw_end(xml, pos, name:lower())
                end
            end
        end
    end
end

function Rebuild.resolve(base, href)
    if type(href) ~= "string" then return nil end
    href = href:gsub("#.*$", ""):gsub("%%(%x%x)", function(n) return string.char(tonumber(n, 16)) end)
    if href == "" or href:find(":", 1, true) or href:find("\\", 1, true)
            or href:find("[%c]") or href:sub(1, 1) == "/" then return nil end
    local parts = {}
    for part in ((base ~= "" and base .. "/" or "") .. href):gmatch("[^/]+") do
        if part == ".." then
            if #parts == 0 then return nil end
            table.remove(parts)
        elseif part ~= "." then parts[#parts + 1] = part end
    end
    return table.concat(parts, "/")
end

local blocks = { p = true, div = true, section = true, article = true, blockquote = true,
    li = true, dt = true, dd = true, tr = true, pre = true,
    h1 = true, h2 = true, h3 = true, h4 = true, h5 = true, h6 = true }
local ignored = { head = true, script = true, style = true, svg = true, nav = true }

function Rebuild.paragraphs(html)
    local result, parts, skip, heading_depth = {}, {}, {}, 0
    local function flush()
        local text = Rebuild.normalize_text(table.concat(parts))
        parts = {}
        if text ~= "" then result[#result + 1] = { text = text, heading = heading_depth > 0 } end
    end
    scan(html, function(name, closing, attrs, self_closing)
        if #skip > 0 then
            if closing and name == skip[#skip] then table.remove(skip)
            elseif not closing and ignored[name] and not self_closing then skip[#skip + 1] = name end
            return
        end
        if not closing and ignored[name] then
            flush()
            if not self_closing then skip[1] = name end
        elseif blocks[name] then
            flush()
            -- 按层数记录，标题内嵌套的 div/p 不会清掉标题标记。
            if not self_closing and name:match("^h[1-6]$") then
                heading_depth = math.max(0, heading_depth + (closing and -1 or 1))
            end
        elseif name == "br" or name == "hr" then flush()
        elseif name == "td" or name == "th" then parts[#parts + 1] = " " end
    end, function(text) if #skip == 0 then parts[#parts + 1] = text end end)
    assert(#skip == 0, "EPUB 正文结构不完整")
    flush()
    return result
end

local function is_numeral(token)
    local rest = token:gsub("%d", ""):gsub("%s", "")
    for _, digit in ipairs({ "零", "〇", "一", "二", "三", "四", "五", "六", "七", "八", "九", "十", "百", "千", "万", "两" }) do
        rest = rest:gsub(digit, "")
    end
    return trim(token) ~= "" and rest == ""
end

-- “第十章 卷入风波”不是卷：卷字前必须是纯数字。
function Rebuild.is_volume(text)
    local number = text:match("^第%s*(.-)%s*卷")
    return number ~= nil and is_numeral(number)
end

-- 原目录整行命中、HTML 标题和常见小说章名均可分章；长句不当标题。
function Rebuild.is_heading(text, known, html_heading)
    if char_count(text) > 90 then return false end
    if known and known[text] or html_heading then return true end
    if text:match("^[Cc][Hh][Aa][Pp][Tt][Ee][Rr]%s+[%w]+") then return true end
    for _, marker in ipairs({ "章", "回", "节", "卷", "部", "篇", "集", "幕" }) do
        local number, suffix = text:match("^第%s*(.-)%s*" .. marker .. "(.*)$")
        if number and is_numeral(number) then
            local first = suffix:sub(1, 1)
            local separated = suffix == "" or first == " " or first == ":" or first == "-"
                or suffix:sub(1, 3) == "　" or suffix:sub(1, 3) == "：" or suffix:sub(1, 3) == "—"
            -- 句号几乎只出现在正文；“第一回见面的时候，他很紧张。”因此不算章名。
            -- 问号不参与判断，“第三回：你是谁？”仍是正常章名。
            local sentence = suffix:find("。", 1, true) ~= nil
                or not separated and char_count(suffix) > 14
            -- 防止“第一部门”“第一部队”这样的正文误切。
            if not sentence and not (marker == "部"
                    and (suffix:sub(1, 3) == "门" or suffix:sub(1, 3) == "队")) then return true end
        end
    end
    for _, name in ipairs({ "序章", "序言", "前言", "楔子", "引子", "尾声", "后记", "番外", "终章", "完本感言" }) do
        if text == name or text:sub(1, #name + 1) == name .. " "
                or text:sub(1, #name + 3) == name .. "：" then return true end
    end
    return false
end

local function package_info(read)
    local opf
    scan(read("META-INF/container.xml"), function(name, closing, attrs)
        if name == "rootfile" and not closing and not opf then opf = Rebuild.resolve("", attrs["full-path"]) end
    end, function() end)
    assert(opf, "EPUB 没有有效的根文档")
    local base = opf:match("^(.*)/[^/]+$") or ""
    local manifest, refs, metadata = {}, {}, {}
    local capture, pieces
    scan(read(opf), function(name, closing, attrs)
        if not closing and (name == "title" or name == "creator" or name == "language") then
            capture, pieces = name, {}
        elseif closing and name == capture then
            if not metadata[name] then metadata[name] = trim(table.concat(pieces)) end
            capture = nil
        elseif not closing and name == "item" then
            assert(attrs.id and not manifest[attrs.id], "EPUB manifest 项缺少或重复 ID")
            manifest[attrs.id] = { path = Rebuild.resolve(base, attrs.href), media = attrs["media-type"],
                nav = (" " .. (attrs.properties or "") .. " "):find("%snav%s") ~= nil }
        elseif not closing and name == "itemref" then refs[#refs + 1] = attrs.idref or "" end
    end, function(text) if capture then pieces[#pieces + 1] = text end end)
    local spine, seen = {}, {}
    for _, id in ipairs(refs) do
        local item = assert(manifest[id], "EPUB spine 引用了不存在的正文")
        assert(item.path and not seen[item.path], "EPUB 正文路径无效或重复")
        seen[item.path] = true
        if item.media == "application/xhtml+xml" or item.media == "text/html" then
            if not item.nav then spine[#spine + 1] = item.path end
        elseif not (item.media or ""):match("^image/") then
            error("暂不支持此 EPUB 正文类型：" .. tostring(item.media))
        end
    end
    assert(#spine > 0, "EPUB 没有可提取的文字正文")
    return spine, metadata
end

local function wrap(title, body)
    return '<?xml version="1.0" encoding="UTF-8"?>\n'
        .. '<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="zh"><head><title>' .. escape(title)
        .. '</title><link rel="stylesheet" type="text/css" href="style.css"/></head><body>'
        .. body .. '</body></html>'
end

-- 常见 EPUB 把章号与章名放进相邻两个标题；合成一个标题，避免每章多出空章。
local function join_titles(items)
    local out, i = {}, 1
    while i <= #items do
        local item, next_item = items[i], items[i + 1]
        local number_only = item.text == "序章" or item.text == "终章"
        for _, marker in ipairs({ "章", "回", "节", "集", "幕" }) do
            if item.text:sub(-#marker) == marker and Rebuild.is_heading(item.text) then number_only = true end
        end
        if number_only and next_item and next_item.heading and char_count(next_item.text) <= 60
                and not Rebuild.is_heading(next_item.text) then
            out[#out + 1] = { text = item.text .. " " .. next_item.text, heading = true }
            i = i + 2
        else
            out[#out + 1] = item
            i = i + 1
        end
    end
    return out
end

-- dest 只能是调用方已独占的工作目录里的新文件，不覆盖已存在文件。
function Rebuild.convert(source, dest, opts, deps)
    opts, deps = opts or {}, deps or {}
    local lfs = deps.lfs or require("libs/libkoreader-lfs")
    if source == dest or lfs.attributes(dest) then return nil, "输出文件已存在，未覆盖" end
    local Archiver = deps.Archiver or require("ffi/archiver")
    local input, output = Archiver.Reader:new(), Archiver.Writer:new{}
    local opened_output = false
    local function report(stage, done, total)
        -- 进度只是提示，写入失败不能让转换本身失败。
        if opts.progress then pcall(opts.progress, stage, done, total) end
    end
    local ok, result = pcall(function()
        report("prepare", 0, 0)
        assert(input:open(source), "无法打开原 EPUB")
        local entries, count = {}, 0
        for entry in input:iterate() do
            count = count + 1
            assert(count <= 30000 and not entries[entry.path], "EPUB 条目过多或路径重复")
            entries[entry.path] = { size = tonumber(entry.size), mode = entry.mode }
        end
        assert(not input.err, input.err)
        local total = 0
        local function read(path)
            local entry = entries[path]
            assert(entry and entry.mode == "file", "EPUB 缺少正文文件：" .. path)
            assert(entry.size and entry.size >= 0 and entry.size <= MAX_ENTRY, "单个 EPUB 正文文件过大")
            total = total + entry.size
            assert(total <= MAX_TOTAL, "EPUB 正文总量超过本版处理上限")
            return assert(input:extractToMemory(path), "读取 EPUB 文件失败：" .. path)
        end
        local spine, meta = package_info(read)
        report("text", 0, #spine)
        local title = trim(opts.title or meta.title)
        if title == "" then title = source:match("([^/\\]+)%.[^%.]+$") or "未命名" end
        local author, language = trim(opts.author or meta.creator), trim(meta.language)
        if language == "" then language = "zh" end
        assert(output:open(dest, "epub"), "无法创建重构副本")
        opened_output = true
        local expected, expected_count = {}, 0
        local function add(path, data)
            assert(output:addFileFromMemory(path, data, 0), output.err or "写入重构副本失败")
            expected[path], expected_count = #data, expected_count + 1
        end
        assert(output:setZipCompression("store"), "无法设置 EPUB 压缩格式")
        add("mimetype", "application/epub+zip")
        assert(output:setZipCompression("deflate"), "无法设置 EPUB 压缩格式")
        add("META-INF/container.xml", '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
        add("OEBPS/style.css", 'body{line-height:1.5;}h1{text-align:center;margin:1.5em 0;page-break-after:avoid;}p{text-indent:2em;margin:0.4em 0;}')
        local chapters, current, body, bytes = {}, nil, {}, 0
        local hash = (deps.sha256 or require("ffi/sha2").sha256)()
        hash(title .. "\n" .. author .. "\n" .. language)
        local paragraphs, sections, volume = 0, 0, false
        local function flush()
            if not current or #body == 0 then return end
            local href = string.format("chapter_%05d.xhtml", #chapters + 1)
            local xhtml = wrap(current.title, table.concat(body, "\n"))
            hash(xhtml)
            add("OEBPS/" .. href, xhtml)
            chapters[#chapters + 1] = { title = current.title, href = href, depth = current.depth }
            body, bytes = {}, 0
        end
        local function start(title_text)
            flush()
            local is_volume = Rebuild.is_volume(title_text)
            volume = volume or is_volume
            current = { title = title_text, depth = volume and not is_volume and 2 or 1 }
            sections = sections + 1
            body[1] = "<h1>" .. escape(title_text) .. "</h1>"
            bytes = #body[1]
        end
        local recognize = opts.recognize ~= false
        for index, path in ipairs(spine) do
            local items = join_titles(Rebuild.paragraphs(read(path)))
            for pos, paragraph in ipairs(items) do
                local text = paragraph.text
                local heading = (recognize or pos == 1) and Rebuild.is_heading(text, opts.headings, paragraph.heading)
                local new_file = not current or not recognize and pos == 1
                if heading then
                    start(text)
                else
                    if new_file then start("正文 " .. index) end
                    if bytes >= PART_BYTES then
                        flush()
                        current = { title = current.title .. "（续）", depth = current.depth }
                    end
                    local line = "<p>" .. escape(text) .. "</p>"
                    body[#body + 1], bytes = line, bytes + #line
                    paragraphs = paragraphs + 1
                end
            end
            report("text", index, #spine)
        end
        flush()
        assert(paragraphs > 0, "没有提取到正文；图片书或扫描书无法重构")
        report("package", 0, 0)
        local manifest = { '<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>',
            '<item id="css" href="style.css" media-type="text/css"/>' }
        local order, nav, depth = {}, {}, 0
        for i, chapter in ipairs(chapters) do
            manifest[#manifest + 1] = '<item id="c' .. i .. '" href="' .. chapter.href .. '" media-type="application/xhtml+xml"/>'
            order[#order + 1] = '<itemref idref="c' .. i .. '"/>'
            local level = math.min(chapter.depth, depth + 1)
            while depth >= level do nav[#nav + 1] = '</navPoint>'; depth = depth - 1 end
            nav[#nav + 1] = '<navPoint id="n' .. i .. '" playOrder="' .. i .. '"><navLabel><text>'
                .. escape(chapter.title) .. '</text></navLabel><content src="' .. chapter.href .. '"/>'
            depth = level
        end
        while depth > 0 do nav[#nav + 1] = '</navPoint>'; depth = depth - 1 end
        local identifier = "inkbridge-rebuild-v1-" .. hash()
        add("OEBPS/toc.ncx", '<?xml version="1.0" encoding="UTF-8"?><ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head><meta name="dtb:uid" content="'
            .. identifier .. '"/><meta name="dtb:depth" content="2"/></head><docTitle><text>' .. escape(title)
            .. '</text></docTitle><navMap>' .. table.concat(nav) .. '</navMap></ncx>')
        add("OEBPS/content.opf", '<?xml version="1.0" encoding="UTF-8"?><package version="2.0" xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>'
            .. escape(title .. "－墨桥重构版") .. '</dc:title><dc:creator>' .. escape(author)
            .. '</dc:creator><dc:language>' .. escape(language) .. '</dc:language><dc:identifier id="bookid">'
            .. identifier .. '</dc:identifier></metadata><manifest>' .. table.concat(manifest)
            .. '</manifest><spine toc="ncx">' .. table.concat(order) .. '</spine></package>')
        assert(output:close() ~= false and not output.err, output.err or "关闭重构副本失败")
        opened_output = false
        -- 部分 KOReader 的 Writer:close 不返回磁盘错误；重新读完整归档后才能交付。
        input:close()
        input = Archiver.Reader:new()
        assert(input:open(dest), "重构副本无法重新打开")
        local verified = 0
        report("verify", 0, expected_count)
        for entry in input:iterate() do
            local size = expected[entry.path]
            assert(size and size == tonumber(entry.size), "重构副本条目不完整")
            local data = input:extractToMemory(entry.path)
            assert(type(data) == "string" and #data == size, "重构副本回读失败")
            expected[entry.path], verified = nil, verified + 1
            report("verify", verified, expected_count)
        end
        assert(not input.err and verified == expected_count, "重构副本缺少文件")
        return { title = title, chapters = #chapters, sections = sections, paragraphs = paragraphs }
    end)
    pcall(function() input:close() end)
    if opened_output then pcall(function() output:close() end) end
    if not ok then os.remove(dest); return nil, tostring(result) end
    return result
end

-- 首页只读预览复用同一套 EPUB spine 和段落解析，不创建重构副本。
Rebuild.inspect = package_info
Rebuild.join_titles = join_titles
return Rebuild
