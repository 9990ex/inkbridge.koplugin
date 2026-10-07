-- inkbridge_moon.lua —— 与静读天下(Moon+ Reader)进度文件互转的**纯数据层**。
--
-- 格式(由两批真机样本 + 一次"预测成功"的写回实验实测得出,见 墨桥-samples/po-findings.md):
--
--     1785683827794*600@0#811:49.1%
--     └──────┬─────┘ └┬┘ └┬┘ └┬┘  └─┬─┘
--      账号级常量    章节  未  章内   显示用
--      (照抄透传)    序号  知  偏移   百分比
--
--   *  章节序号(0 基) —— 等于 KOReader 的 DocFragment 序号 − 1。**决定位置**。
--   #  该章节内的**字符**偏移(章节全部正文、去掉空白后按字符计数)。**决定位置**。
--   :% 界面显示的整本书百分比。实测:只改它**不会**改变落点,不参与定位。
--   @  恒为 0,含义未知;写回时必须原样保留。
--   首个常量是**账号级**的(两本不同的书完全相同),写回时原样保留即可。
--
-- 本模块只做纯计算(解析、生成、字符偏移换算),不碰网络与界面,便于单元测试。
-- 云端文件名规则:`<静读天下书库里的文件名>.po`,目录 `Apps/Books/.Moon+/Cache/`。

local Moon = {}

-- ── UTF-8 按字符处理 ───────────────────────────────────────────────────────
-- 静读天下的偏移是**字符**数,而 Lua 的 # 和 sub 按字节。含中文时两者差别巨大
-- (1 个汉字 = 3 字节),所以这里必须自己按字符数。

function Moon.utf8_len(s)
    local n, i = 0, 1
    local len = #s
    while i <= len do
        local b = s:byte(i)
        if b < 0x80 then i = i + 1
        elseif b < 0xE0 then i = i + 2
        elseif b < 0xF0 then i = i + 3
        else i = i + 4 end
        n = n + 1
    end
    return n
end

-- 取从第 start 个字符开始的 count 个字符(start 从 1 计,可为负表示越界容错)
function Moon.utf8_sub(s, start, count)
    local i, pos = 1, 1
    local len = #s
    local from, to
    while i <= len + 1 do
        if pos == start then from = i end
        if pos == start + count then to = i - 1; break end
        if i > len then break end
        local b = s:byte(i)
        if b < 0x80 then i = i + 1
        elseif b < 0xE0 then i = i + 2
        elseif b < 0xF0 then i = i + 3
        else i = i + 4 end
        pos = pos + 1
    end
    if not from then return "" end
    if not to then to = len end
    return s:sub(from, to)
end

-- ── 解析与生成 ─────────────────────────────────────────────────────────────

-- 解析一行 .po;失败返回 nil, 原因
-- 返回 { book_ref = 字符串, star = 章节序号(0基), at = @ 字段,
--        hash = 章内字符偏移, pct = 百分比(数字) }
function Moon.parse(line)
    if type(line) ~= "string" then return nil, "不是字符串" end
    line = line:gsub("[\r\n]+$", "")
    if line == "" then return nil, "空内容" end

    local book_ref, rest = line:match("^(%d+)%*(.+)$")
    if not book_ref then return nil, "缺少首个常量或 * 分隔符" end
    local star_s, after_star = rest:match("^(%d+)@(.*)$")
    if not star_s then return nil, "缺少 @ 分隔符" end
    local at_s, after_at = after_star:match("^(%d+)#(.*)$")
    if not at_s then return nil, "缺少 # 分隔符" end
    local hash_s, pct_s = after_at:match("^(%d+):(.*)$")
    if not hash_s then return nil, "缺少 : 分隔符" end
    local pct = tonumber((pct_s:gsub("%%$", "")))
    if not pct then return nil, "百分比无法解析" end

    return {
        book_ref = book_ref,
        star     = tonumber(star_s),
        at       = tonumber(at_s),
        hash     = tonumber(hash_s),
        pct      = pct,
    }
end

-- 按原格式拼回一行;book_ref 与 at 必须沿用云端原值
function Moon.format(book_ref, star, hash, pct, at)
    at = at or 0
    local pct_s
    if math.abs(pct - math.floor(pct + 0.5)) < 0.05 then
        pct_s = string.format("%d", math.floor(pct + 0.5))
    else
        pct_s = string.format("%.1f", pct)
    end
    return string.format("%s*%d@%d#%d:%s%%", book_ref, star, at, hash, pct_s)
end

-- ── 偏移换算 ───────────────────────────────────────────────────────────────

-- 由「该章各行文本(已去空白)」算出某段的起始字符偏移。
-- paragraphs 为数组,index 是**块**下标(1 基);char_offset 是段内字符偏移。
-- 这与静读天下的口径一致:章节内全部正文按顺序累加。
function Moon.offset_of(paragraphs, index, char_offset)
    local off = char_offset or 0
    for i = 1, index - 1 do
        off = off + Moon.utf8_len(paragraphs[i] or "")
    end
    return off
end

-- 反查:给定章内字符偏移,落在第几块、块内第几字
function Moon.locate(paragraphs, offset)
    local acc = 0
    for i = 1, #paragraphs do
        local n = Moon.utf8_len(paragraphs[i])
        if offset < acc + n then
            return i, offset - acc
        end
        acc = acc + n
    end
    local last = #paragraphs
    if last == 0 then return nil end
    return last, Moon.utf8_len(paragraphs[last])
end

-- 取该偏移处的一小段文字(用于在 KOReader 里全文搜索定位)。
-- 返回 nil 表示偏移超出本章(说明两端章节结构不一致,应放弃而不是乱跳)。
function Moon.snippet(section_text, offset, len)
    len = len or 20
    local total = Moon.utf8_len(section_text)
    if offset >= total then return nil end
    if offset + len > total then len = total - offset end
    if len <= 0 then return nil end
    return Moon.utf8_sub(section_text, offset + 1, len)
end

-- ── 与静读天下对接的路径与文本工具(纯函数,便于单元测试)───────────────────

-- HTML → 纯文本:去标签、解常见实体、去掉**所有**空白。
-- 去空白是必须的:静读天下的章内偏移是按"去空白后的字符数"计的(已实测)。
function Moon.plain_text(html)
    local t = tostring(html):gsub("<[^>]*>", "")
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

-- 判断是不是正文类条目(`.xhtml` / `.html` / `.htm`,大小写不限)。
--
-- 这里曾经写成 `%.html?$` —— 那个模式**匹配不了 `.xhtml`**(它要求结尾正好是 ".htm"
-- 或 ".html",而 ".xhtml" 结尾是 "xhtml"),于是章节表被过滤成空,任何一本用 .xhtml
-- 的书都会报「章节序号超出本书范围」。教训:Lua 模式里表示扩展名要写成 `%.x?html?$`。
function Moon.is_html_href(href)
    if type(href) ~= "string" then return false end
    return href:lower():match("%.x?html?$") ~= nil
end

-- 规范化用户填写的目录:去首尾空白、统一斜杠、去掉尾部斜杠。
-- 允许以 "/" 开头,表示"从 WebDAV 服务器根算起"的绝对路径(见 build_url)。
function Moon.normalize_dir(value, default)
    local dir = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if dir == "" then
        dir = tostring(default or ""):gsub("^%s+", ""):gsub("%s+$", "")
    end
    return (dir:gsub("\\", "/"):gsub("/+$", ""))
end

-- 本机书籍路径 → 静读天下的进度文件名(`…/死人经.epub` → `死人经.epub.po`)
function Moon.po_filename(book_file)
    if type(book_file) ~= "string" or book_file == "" then return nil end
    local name = book_file:gsub("\\", "/"):match("([^/]+)$")
    if not name or name == "" then return nil end
    return name .. ".po"
end

-- 逐段转义:只保留 URL 路径里安全的字符,其余按 UTF-8 字节转义。
-- 特意**不转义 "+"**:它在路径中合法,而静读天下的目录名正是 ".Moon+",
-- 且部分服务器对 %2B 的处理并不可靠。
function Moon.uri_escape(seg)
    return (tostring(seg):gsub("[^%w%-%._~+!$&'()*,;=:@/]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

-- 拼出该文件的完整 WebDAV URL。
--   address  服务器地址(如 https://dav.jianguoyun.com/dav)
--   root     当前 WebDAV 目标所在目录(server.url)
--   dir      静读天下目录:相对 root;以 "/" 开头则从服务器根算起
--   filename 文件名
function Moon.build_url(address, root, dir, filename)
    local addr = tostring(address or ""):gsub("/+$", "")
    local folder = Moon.normalize_dir(dir, "")
    if folder:sub(1, 1) ~= "/" then
        local base = tostring(root or ""):gsub("^/+", ""):gsub("/+$", "")
        folder = "/" .. (base == "" and folder or (base .. "/" .. folder))
    end
    folder = folder:gsub("//+", "/")
    return addr .. folder .. "/" .. Moon.uri_escape(filename)
end

-- ── 章节拆块与"可搜索片段" ────────────────────────────────────────────────

local BLOCK_TAGS = {
    p = true, div = true, li = true, blockquote = true,
    h1 = true, h2 = true, h3 = true, h4 = true, h5 = true, h6 = true,
}

-- 把一章 HTML 拆成「块级文本」数组。
--
-- 口径必须与静读天下一致:按文档顺序累加各块文本、块内去掉所有空白。
-- 这里用**手写扫描**而不是模式里的选择分支 —— Lua 模式没有 `|`,无法一次匹配多种标签。
-- 做法是:找到每个开标签,再找它**第一个**同名的闭合标签,取出其中文字,然后从闭合标签之后继续。
-- 外层 div 因此只吞到它自己的第一个 </div>(通常是那张空的 logo 图),不会重复计算内层文字。
function Moon.blocks_tagged_from_html(html)
    local blocks = {}
    local pos, len = 1, #html
    while pos <= len do
        local s, e, name = html:find("<(%a[%w]*)[^>]*>", pos)
        if not s then break end
        name = name:lower()
        if BLOCK_TAGS[name] then
            local close_s, close_e = html:find("</" .. name .. ">", e + 1, true)  -- 纯文本查找
            if close_s then
                local text = Moon.plain_text(html:sub(e + 1, close_s - 1))
                if text ~= "" then blocks[#blocks + 1] = { tag = name, text = text } end
                pos = close_e + 1
            else
                pos = e + 1          -- 没有闭合标签:跳过这个开标签
            end
        else
            pos = e + 1
        end
    end
    return blocks
end

-- 只要文本的版本(读取方向用)。与 blocks_tagged_from_html 同源,保证两个方向口径一致。
function Moon.blocks_from_html(html)
    local out = {}
    for i, b in ipairs(Moon.blocks_tagged_from_html(html)) do out[i] = b.text end
    return out
end

-- 取出该章内偏移处的一小段文字,用于在 KOReader 里全文搜索定位。
--
-- **关键:片段必须落在同一个块内。** 之前是从"整章去空白后的连续文本"里切的,
-- 片段可能横跨两段;而渲染出来的正文在段与段之间是断开的,全文搜索必然搜不到 ——
-- 实测表现就是"搜索没命中、掉到百分比兜底、落点差很远"。
-- 若该位置离块尾太近(取不满 6 个字),就在块内往前借几个字;仍不够则返回 nil
-- (宁可如实报"定位不到",也不要拿一个搜不到的片段去碰运气)。
function Moon.snippet_in_blocks(blocks, offset, want)
    want = want or 20
    local idx, off = Moon.locate(blocks, offset)
    if not idx then return nil end
    local text = blocks[idx]
    local n = Moon.utf8_len(text)
    if off >= n then return nil end

    local start = off
    local take = math.min(want, n - start)
    if take < 6 and start > 0 then
        local borrow = math.min(6 - take, start)
        start = start - borrow
        take = take + borrow
    end
    if take < 6 then return nil end
    return Moon.utf8_sub(text, start + 1, take)
end

-- ── 反向:KOReader xpointer → 静读天下的 (章节序号, 章内偏移) ──────────────

-- 只保留非空白字符。用于把 KOReader 报回来的文字与本章正文对齐自检。
function Moon.compact(s)
    return (tostring(s or ""):gsub("%s+", ""))
end

-- 解析 crengine 的 xpointer,取出写回需要的三样东西。
--
--   完整形 `/body/DocFragment[1147]/body/p[8]/text().30`
--   缩写形 `DocFragment[1147] p[8] text().30`
--
--   section     = DocFragment 序号 − 1(静读天下的 `*` 是 0 基)
--   p_index     = **最后一个** p[N] 的下标(嵌套时最靠近 text() 的才是目标);
--                 0 表示这个位置不在任何 <p> 里(例如标题里的字)
--   text_offset = 该文本节点内的字符偏移
--
-- 返回表 或 nil + 原因。
function Moon.parse_xpointer(xp)
    if type(xp) ~= "string" or xp == "" then return nil, "没有 xpointer" end
    local frag = xp:match("DocFragment%[(%d+)%]")
    if not frag then return nil, "xpointer 里没有 DocFragment" end

    local p_index = 0
    for k in xp:gmatch("p%[(%d+)%]") do p_index = tonumber(k) end

    local m = xp:match("text%(%)%.(%d+)")
    return {
        section     = tonumber(frag) - 1,
        p_index     = p_index,
        text_offset = tonumber(m or 0),
    }
end

-- (第几个 <p>, 段内偏移) → 章内字符偏移。
--
-- 累加口径与读取方向**完全一致**:按文档顺序累加所有块级文本(不只是 <p>),
-- 块内按字符数(不是字节)。这样写回去的 `#` 与读回来的 `#` 落在同一个字上。
--
-- 返回偏移 或 nil + 原因 —— 对不上时宁可报错,也不写一个错位置覆盖用户进度。
function Moon.offset_from_tagged(tagged, p_index, text_offset)
    if type(tagged) ~= "table" or #tagged == 0 then return nil, "本章没有正文块" end
    if type(p_index) ~= "number" or p_index <= 0 then
        -- 第三个返回值是给调用方分类用的："nop" 表示这次是"停在标题/图片上"这种
        -- **正常偶发**情况,自动写回时不该当成错误弹窗。
        return nil, "xpointer 没有指向任何 <p>（可能停在标题或图片上）", "nop"
    end
    text_offset = tonumber(text_offset) or 0

    local acc, seen = 0, 0
    for i = 1, #tagged do
        local b = tagged[i]
        if b.tag == "p" then
            seen = seen + 1
            if seen == p_index then
                local n = Moon.utf8_len(b.text)
                if text_offset > n then
                    return nil, string.format("段内偏移 %d 超出该段长度 %d（两端版本可能不同）",
                                              text_offset, n)
                end
                return acc + text_offset
            end
        end
        acc = acc + Moon.utf8_len(b.text)
    end
    return nil, string.format("本章只有 %d 个 <p>，xpointer 指的是第 %d 个", seen, p_index)
end

return Moon
