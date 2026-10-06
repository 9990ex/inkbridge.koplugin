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

return Moon
