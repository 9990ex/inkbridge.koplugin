-- ============================================================================
-- tests/moon_spec.lua — InkBridge × 静读天下(Moon+ Reader)数据层回归测试
--
-- 覆盖：.po 行解析/生成、UTF-8 按字符处理、章内偏移换算、片段提取。
-- 断言用的是**真机实测样本**(见 墨桥-samples/po-findings.md):
--     1785683827794*275@0#1722:22%     (死人经 2000 页)
--     1785683827794*546@0#1703:45%     (死人经 4000 页)
--     1785683827794*818@0#161:66.9%    (死人经 6000 页)
--     1785683827794*7@0#1867:0%        (异兽迷城—澎湃,证明首个常量是账号级)
-- 运行： luajit tests/moon_spec.lua   (在仓库根目录执行)
-- ============================================================================

local script_path = arg and arg[0] or "tests/moon_spec.lua"
local script_dir  = script_path:match("^(.*)[/\\][^/\\]*$") or "."
local PLUGIN_DIR  = script_dir .. "/../inkbridge.koplugin"

local Moon = dofile(PLUGIN_DIR .. "/inkbridge_moon.lua")

local passed, failed = 0, 0
local function check(label, cond, detail)
    if cond then passed = passed + 1; print("    PASS  " .. label)
    else failed = failed + 1
        print(string.format("    FAIL  %s%s", label, detail and ("  -> " .. tostring(detail)) or "")) end
end
local function eq(label, got, want)
    check(label, got == want, string.format("得到 %s，期望 %s", tostring(got), tostring(want)))
end

-- ── 解析:真机样本 ─────────────────────────────────────────────────────────
print("== 解析实测样本 ==")
do
    local cases = {
        { "1785683827794*275@0#1722:22%",  275, 1722, 22    },
        { "1785683827794*546@0#1703:45%",  546, 1703, 45    },
        { "1785683827794*818@0#161:66.9%", 818, 161,  66.9  },
        { "1785683827794*7@0#1867:0%",     7,   1867, 0     },
        { "1785683827794*600@0#811:49.1%", 600, 811,  49.1  },
    }
    for _, c in ipairs(cases) do
        local p = Moon.parse(c[1])
        check("解析 " .. c[1], p ~= nil)
        if p then
            eq("  book_ref", p.book_ref, "1785683827794")
            eq("  star", p.star, c[2])
            eq("  hash", p.hash, c[3])
            eq("  pct", p.pct, c[4])
            eq("  at", p.at, 0)
        end
    end
    -- 末尾换行要能容忍(云端文件常带换行)
    local p = Moon.parse("1785683827794*275@0#1722:22%\n")
    check("容忍末尾换行", p ~= nil and p.hash == 1722)
end

-- ── 解析:坏输入必须报错而不是猜 ───────────────────────────────────────────
print("== 坏输入 ==")
do
    local bad = { "", "abc", "123", "123*456", "123*456@0", "123*456@0#789",
                  "123*456@0#789:", "123*456@0#789:abc", "1785683827794*275@0#1722" }
    for _, s in ipairs(bad) do
        local p, err = Moon.parse(s)
        check(string.format("拒绝 %q（%s）", s, tostring(err)), p == nil and err ~= nil)
    end
    check("非字符串也拒绝", select(1, Moon.parse(nil)) == nil)
end

-- ── 生成:格式与往返 ───────────────────────────────────────────────────────
print("== 生成 ==")
do
    eq("整数百分比不补小数", Moon.format("1785683827794", 600, 811, 49.1), "1785683827794*600@0#811:49.1%")
    eq("整数百分比写法",     Moon.format("1785683827794", 275, 1722, 22),  "1785683827794*275@0#1722:22%")
    eq("一位小数保留",       Moon.format("1785683827794", 818, 161, 66.9), "1785683827794*818@0#161:66.9%")
    eq("at 可指定",          Moon.format("1785683827794", 7, 1867, 0, 1),  "1785683827794*7@1#1867:0%")
    for _, s in ipairs({ "1785683827794*275@0#1722:22%", "1785683827794*818@0#161:66.9%" }) do
        local p = Moon.parse(s)
        eq("往返一致 " .. s, Moon.format(p.book_ref, p.star, p.hash, p.pct, p.at), s)
    end
end

-- ── UTF-8 按字符 ──────────────────────────────────────────────────────────
print("== UTF-8 ==")
do
    eq("纯中文长度", Moon.utf8_len("龙王"), 2)
    eq("纯英文长度", Moon.utf8_len("abc"), 3)
    eq("混合长度",   Moon.utf8_len("a龙b"), 3)
    eq("空串长度",   Moon.utf8_len(""), 0)
    eq("取中间两字", Moon.utf8_sub("龙王给出个说法", 3, 2), "给出")
    eq("取首字",     Moon.utf8_sub("龙王给出个说法", 1, 1), "龙")
    eq("取到末尾",   Moon.utf8_sub("龙王给出个说法", 6, 99), "说法")
    eq("取最后一个字", Moon.utf8_sub("龙王给出个说法", 7, 99), "法")
    eq("该串共 7 字", Moon.utf8_len("龙王给出个说法"), 7)
    eq("start 越界", Moon.utf8_sub("龙王", 5, 2), "")
end

-- ── 章内偏移换算(与静读天下口径一致:全部正文按顺序累加) ────────────────
print("== 章内偏移 ==")
do
    local paras = {
        "第一段：这一段的长度是固定的，用来占位。",           -- 20 字
        "第二段：龙王给出个说法，如果真有冒充者，请龙王指出来。", -- 27 字
        "第三段：最后一段。",                                 -- 9 字
    }
    eq("段内偏移累计", Moon.utf8_len(paras[1]), 20)
    eq("第1段起点", Moon.offset_of(paras, 1, 0), 0)
    eq("第2段起点", Moon.offset_of(paras, 2, 0), 20)
    eq("第2段内 4 字处", Moon.offset_of(paras, 2, 4), 24)
    eq("第3段起点", Moon.offset_of(paras, 3, 0), 47)

    local i, o = Moon.locate(paras, 24)
    eq("反查段号", i, 2); eq("反查段内偏移", o, 4)
    local i2, o2 = Moon.locate(paras, 0)
    eq("反查首段", i2, 1); eq("反查首段偏移", o2, 0)
    local i3, o3 = Moon.locate(paras, 20)
    eq("边界落在下一段首", i3, 2); eq("边界偏移 0", o3, 0)
    local i4, o4 = Moon.locate(paras, 9999)
    eq("越界落最后一段", i4, 3); eq("越界偏移为段长", o4, 9)
end

-- ── 片段提取(用于 KOReader 全文搜索定位) ────────────────────────────────
print("== 片段提取 ==")
do
    local text = "第二段：龙王给出个说法，如果真有冒充者，请龙王指出来。"
    eq("偏移处片段(8 字含标点)", Moon.snippet(text, 4, 8), "龙王给出个说法，")
    eq("偏移处片段(7 字)",       Moon.snippet(text, 4, 7), "龙王给出个说法")
    eq("整段长度",   Moon.utf8_len(text), 27)
    eq("偏移等于全长要拒绝", Moon.snippet(text, 27, 10), nil)
    eq("偏移越界要拒绝",     Moon.snippet(text, 99, 10), nil)
    eq("末尾自动截断",       Moon.snippet(text, 25, 10), "来。")
    eq("长度 0 要拒绝",      Moon.snippet(text, 3, 0), nil)
end

-- ── 与静读天下对接的路径与文本工具 ──────────────────────────────────────
print("== 路径与文本工具 ==")
do
    -- HTML → 纯文本(偏移口径的关键:必须去掉所有空白)
    eq("去标签", Moon.plain_text("<p>龙王</p>"), "龙王")
    eq("去空白与换行", Moon.plain_text("<p>龙王\n  给出 </p>"), "龙王给出")
    eq("实体解码", Moon.plain_text("a&amp;b&lt;c&gt;d&quot;e&apos;f"), "a&b<c>d\"e'f")
    eq("nbsp 直接丢", Moon.plain_text("龙王&nbsp;给出"), "龙王给出")
    eq("十进制实体", Moon.plain_text("a&#65;b"), "aAb")
    eq("非 ASCII 数字实体忽略", Moon.plain_text("a&#20320;b"), "ab")

    -- 目录规范化
    eq("默认值兜底", Moon.normalize_dir(nil, "Apps/Books/.Moon+/Cache"), "Apps/Books/.Moon+/Cache")
    eq("去首尾空白", Moon.normalize_dir("  Apps/x/  ", "d"), "Apps/x")
    eq("反斜杠归一", Moon.normalize_dir("Apps\\x", "d"), "Apps/x")
    eq("保留开头斜杠(绝对路径)", Moon.normalize_dir("/dav/1/BOOK", "d"), "/dav/1/BOOK")
    eq("空串退回默认", Moon.normalize_dir("   ", "def"), "def")

    -- 文件名
    eq("取书名", Moon.po_filename("/books/死人经 (冰临神下) (Z-Library).epub"),
       "死人经 (冰临神下) (Z-Library).epub.po")
    eq("Windows 路径", Moon.po_filename("D:\\b\\书名.epub"), "书名.epub.po")
    eq("空路径返回 nil", Moon.po_filename(""), nil)

    -- URL 拼装
    eq("相对目录接在 WebDAV 目标之后",
       Moon.build_url("https://dav.example.com/dav", "/1/BOOK/inkbridge/test",
                      "Apps/Books/.Moon+/Cache", "a b.epub.po"),
       "https://dav.example.com/dav/1/BOOK/inkbridge/test/Apps/Books/.Moon+/Cache/a%20b.epub.po")
    eq("绝对目录从服务器根算起(忽略 WebDAV 目标)",
       Moon.build_url("https://dav.example.com/dav", "/1/BOOK/inkbridge/test",
                      "/Apps/Books/.Moon+/Cache", "x.po"),
       "https://dav.example.com/dav/Apps/Books/.Moon+/Cache/x.po")
    eq("地址尾部斜杠容错",
       Moon.build_url("https://dav.example.com/dav/", "", "Apps", "x.po"),
       "https://dav.example.com/dav/Apps/x.po")
    -- 目录拼接(点选同步目录就是靠这个字符串判断"现在在哪一层")
    eq("目录为空 = WebDAV 目标本身,且不带尾斜杠",
       Moon.build_folder("/1/BOOK/inkbridge/test", ""), "/1/BOOK/inkbridge/test")
    eq("服务器根目录仍然是 /", Moon.build_folder("/", ""), "/")
    eq("目标为空时不留前导双斜杠", Moon.build_folder("", "Apps"), "/Apps")
    eq("中文按 UTF-8 字节转义",
       Moon.build_url("https://d/", "", "Apps", "死人经.epub.po"),
       "https://d/Apps/%E6%AD%BB%E4%BA%BA%E7%BB%8F.epub.po")
end

-- ── 章节文件扩展名判定 ────────────────────────────────────────────────────
-- 曾经的 bug:过滤写成 %.html?$,匹配不了 .xhtml,章节表被筛空,
-- 于是任何一本用 .xhtml 的书都会报「章节序号超出本书范围」。
print("== 章节文件扩展名 ==")
do
    check("xhtml 要认", Moon.is_html_href("OEBPS/Text/chapter1_35.xhtml"))
    check("html 要认",  Moon.is_html_href("a.html"))
    check("htm 要认",   Moon.is_html_href("a.htm"))
    check("大写要认",   Moon.is_html_href("A.XHTML"))
    check("css 不认",   not Moon.is_html_href("Styles/style.css"))
    check("opf 不认",   not Moon.is_html_href("OEBPS/content.opf"))
    check("无扩展名不认", not Moon.is_html_href("README"))
    check("非字符串不认", not Moon.is_html_href(nil))
end

-- ── 章节拆块与"可搜索片段" ───────────────────────────────────────────────
-- 针对一个真实踩过的坑:片段跨段 → 全文搜索搜不到 → 掉进百分比兜底、落点差很远。
print("== 章节拆块与可搜索片段 ==")
do
    local html = '<body><div><div class="logo"><img src="x.png"/></div>'
        .. '<h2>第595章 比气</h2><p>第一段文字。</p>'
        .. '<p>第二段：龙王给出个说法，如果真有冒充者。</p></div></body>'
    local bl = Moon.blocks_from_html(html)
    eq("块数(空 logo 不计入)", #bl, 3)
    eq("第一块是标题", bl[1], "第595章比气")
    eq("第二块", bl[2], "第一段文字。")
    eq("第三块", bl[3], "第二段：龙王给出个说法，如果真有冒充者。")
    eq("各块拼接 == plain_text(整章)", table.concat(bl), Moon.plain_text(html))

    -- 片段必须落在单块内:从第三块内"龙王"处取
    local off_p3 = Moon.utf8_len(bl[1]) + Moon.utf8_len(bl[2])
    local s = Moon.snippet_in_blocks(bl, off_p3 + 4, 6)
    eq("片段取自块内", s, "龙王给出个说")
    check("片段是该块的子串", s ~= nil and bl[3]:find(s, 1, true) ~= nil)

    -- 离块尾太近要往前借,借完仍是该块子串
    local long = "这是一段足够长的文字用来测试向前借用"
    local blocks = { "标题", long }
    local near_end = Moon.utf8_len(blocks[1]) + Moon.utf8_len(long) - 2
    local s2 = Moon.snippet_in_blocks(blocks, near_end, 20)
    check("借字后够长", s2 ~= nil and Moon.utf8_len(s2) >= 6)
    check("借字后仍在同一块内", s2 ~= nil and long:find(s2, 1, true) ~= nil)

    -- 越界要拒绝,而不是给出跨块片段
    eq("偏移超过全长要拒绝", Moon.snippet_in_blocks(blocks, 9999, 20), nil)
    eq("空块列表要拒绝", Moon.snippet_in_blocks({}, 0, 20), nil)
end

-- ── 反向:xpointer → (章节序号, 段序, 段内偏移) ───────────────────────────
print("== xpointer 解析(写回方向) ==")
do
    local p = Moon.parse_xpointer("/body/DocFragment[1147]/body/p[8]/text().30")
    check("完整路径可解析", p ~= nil)
    if p then
        eq("  section = DocFragment - 1", p.section, 1146)
        eq("  p_index", p.p_index, 8)
        eq("  text_offset", p.text_offset, 30)
    end

    local q = Moon.parse_xpointer("DocFragment[1] p[1] text().0")
    check("缩写形可解析", q ~= nil)
    if q then
        eq("  缩写形 section", q.section, 0)
        eq("  缩写形 p_index", q.p_index, 1)
        eq("  缩写形 text_offset", q.text_offset, 0)
    end

    -- 嵌套路径要取**最后一个** p[N](最靠近 text() 的那个才是目标)
    local r = Moon.parse_xpointer("/body/DocFragment[5]/body/div[2]/p[3]/p[9]/text().7")
    check("嵌套路径可解析", r ~= nil and r.p_index == 9, r and r.p_index)

    -- 没有 text() → 视为该段开头
    local s = Moon.parse_xpointer("/body/DocFragment[5]/body/p[2]")
    check("没有 text() 也能解析", s ~= nil)
    if s then
        eq("  text_offset 记 0", s.text_offset, 0)
        eq("  p_index 仍在", s.p_index, 2)
    end

    -- 停在标题上:没有 p[]
    local u = Moon.parse_xpointer("/body/DocFragment[5]/body/h2/text().3")
    check("标题位置可解析", u ~= nil and u.p_index == 0)

    eq("空串要拒绝", Moon.parse_xpointer(""), nil)
    eq("nil 要拒绝", Moon.parse_xpointer(nil), nil)
    eq("没有 DocFragment 要拒绝", Moon.parse_xpointer("/body/div/p[1]/text().0"), nil)
    eq("空串不能靠 p[] 蒙混过关", Moon.parse_xpointer("p[3]/text().1"), nil)
end

-- ── 反向:(第几个 <p>, 段内偏移) → 章内偏移 ───────────────────────────────
print("== 反向换算:(第几个 <p>, 段内偏移) → 章内偏移 ==")
do
    -- 真机样本 chapter7_66:`.po` 的 `*1146 #458` 落在该章**第 8 个 <p> 的第 30 字**。
    -- 该章第 1 块是章标题(非 <p>),前 8 块累计 428 字,428 + 30 = 458 —— 与 .po 完全一致。
    -- 这里用同构的小样验证同一套算术(真机数据见 墨桥-samples/po-locate.py 的输出)。
    local tagged = {
        { tag = "h1", text = "第一章" },        -- 3 字,不计入 <p>
        { tag = "p",  text = "一二三四五" },    -- 5 字,第 1 个 <p>
        { tag = "p",  text = "六七八九十" },    -- 5 字,第 2 个 <p>
    }
    eq("第 1 个 <p> 段内 0 → 3",  Moon.offset_from_tagged(tagged, 1, 0), 3)
    eq("第 1 个 <p> 段内 2 → 5",  Moon.offset_from_tagged(tagged, 1, 2), 5)
    eq("第 2 个 <p> 段内 0 → 8",  Moon.offset_from_tagged(tagged, 2, 0), 8)
    eq("第 2 个 <p> 段尾 5 → 13", Moon.offset_from_tagged(tagged, 2, 5), 13)
    eq("段内偏移越界要拒绝",     Moon.offset_from_tagged(tagged, 2, 6), nil)
    eq("p_index 超出本章要拒绝", Moon.offset_from_tagged(tagged, 9, 0), nil)
    eq("p_index = 0 要拒绝",     Moon.offset_from_tagged(tagged, 0, 0), nil)
    eq("空块表要拒绝",           Moon.offset_from_tagged({}, 1, 0), nil)
    eq("非表要拒绝",             Moon.offset_from_tagged(nil, 1, 0), nil)

    -- 非 <p> 的块(标题/div)也必须计入偏移 —— 否则整章会错位
    local with_div = {
        { tag = "div", text = "前置内容" },     -- 4 字
        { tag = "p",   text = "甲乙丙" },       -- 3 字,第 1 个 <p>
    }
    eq("前面的 div 计入累计", Moon.offset_from_tagged(with_div, 1, 0), 4)
end

-- ── 分块:保留标签 ─────────────────────────────────────────────────────────
print("== 分块(保留标签,写回要数第几个 <p>) ==")
do
    local html = '<body><div><div class="logo"><img src="x.png"/></div>'
        .. '<h2>第595章比气</h2><p>第一段文字。</p>'
        .. '<p>第二段：龙王给出个说法，如果真有冒充者。</p></div></body>'
    local t = Moon.blocks_tagged_from_html(html)
    eq("块数", #t, 3)
    eq("第 1 块标签", t[1].tag, "h2")
    eq("第 2 块标签", t[2].tag, "p")
    eq("第 3 块标签", t[3].tag, "p")
    eq("第 1 块文本", t[1].text, "第595章比气")
    -- 两个版本必须逐字一致,否则读写两个方向会错位
    eq("带标签版与纯文本版一致",
       table.concat({ t[1].text, t[2].text, t[3].text }),
       table.concat(Moon.blocks_from_html(html)))
end

-- ── 写回整行 ───────────────────────────────────────────────────────────────
print("== 生成整行(写回静读天下) ==")
do
    local line = Moon.format("1785683827794", 1146, 458, 93.8032, 0)
    eq("生成的内容", line, "1785683827794*1146@0#458:93.8%")
    local back = Moon.parse(line)
    check("生成的内容能被自己解析回来", back ~= nil)
    if back then
        eq("  回读 book_ref", back.book_ref, "1785683827794")
        eq("  回读 star", back.star, 1146)
        eq("  回读 hash", back.hash, 458)
    end
    eq("整数百分比不留小数位", Moon.format("1", 2, 3, 94, 0), "1*2@0#3:94%")
    eq("@ 字段必须原样透传", Moon.format("1", 2, 3, 50, 7), "1*2@7#3:50%")

    -- 读写闭环:真机那两个偏移量来回一趟必须不变
    for _, case in ipairs({ { 1146, 458 }, { 1144, 2821 }, { 600, 811 } }) do
        local l = Moon.format("1785683827794", case[1], case[2], 50, 0)
        local r = Moon.parse(l)
        check(string.format("闭环 *%d #%d", case[1], case[2]),
              r ~= nil and r.star == case[1] and r.hash == case[2])
    end

    eq("compact 去掉所有空白", Moon.compact(" 甲\n乙\t丙 "), "甲乙丙")
    eq("compact 容忍 nil", Moon.compact(nil), "")
end

print(string.format("\n合计：%d 通过，%d 失败", passed, failed))
os.exit(failed == 0 and 0 or 1)
