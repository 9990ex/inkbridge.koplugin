-- ============================================================================
-- tests/state_spec.lua — InkBridge 位置数据层回归测试
--
-- 覆盖：文本锚点规范化、阅读位置采集（含新增的排版无关锚点）、记录编解码校验。
-- 运行： luajit tests/state_spec.lua   (在仓库根目录执行)
-- ============================================================================

local script_path = arg and arg[0] or "tests/state_spec.lua"
local script_dir  = script_path:match("^(.*)[/\\][^/\\]*$") or "."
local PLUGIN_DIR  = script_dir .. "/../inkbridge.koplugin"
package.path = PLUGIN_DIR .. "/?.lua;" .. package.path

-- rapidjson 桩：
--   decode 返回预置表（每个用例自行设置）
--   encode 用一个"扁平对象"编码器，输出形状与 KOReader 的 rapidjson 一致
--   （无空格、非 ASCII 原样输出不转义——真实记录文件里就是原样 UTF-8），
--   这样才能对载荷的**结构与体积**做断言。
local json_next
local function json_encode_flat(t)
    local parts = {}
    for k, v in pairs(t) do
        local value
        if type(v) == "string" then
            value = '"' .. v:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
        elseif type(v) == "number" then
            value = string.format("%.14g", v)
        else
            value = tostring(v)
        end
        parts[#parts + 1] = '"' .. k .. '":' .. value
    end
    return "{" .. table.concat(parts, ",") .. "}"
end
package.preload["rapidjson"] = function()
    return {
        encode = json_encode_flat,
        decode = function() return json_next end,
    }
end
package.preload["util"] = function() return {} end

local State = dofile(PLUGIN_DIR .. "/inkbridge_state.lua")

local passed, failed = 0, 0
local function check(label, cond, detail)
    if cond then passed = passed + 1; print("    PASS  " .. label)
    else failed = failed + 1
        print(string.format("    FAIL  %s%s", label, detail and ("  -> " .. tostring(detail)) or "")) end
end
local function eq(label, got, want)
    check(label, got == want, string.format("得到 %s，期望 %s", tostring(got), tostring(want)))
end

local XP = "/body/DocFragment[305]/body/div/p[67]/text().0"
local PARA = "顾慎为很清楚这些刀客的热情能持续多久，等个三五天再说。"

-- 造一个假文档；opts 可覆盖任意接口（用 false 表示“移除该接口”），用来测降级路径
local function make_doc(opts)
    opts = opts or {}
    local doc = {
        file = "/books/死人经 (冰临神下) (Z-Library).epub",
        info = { doc_height = 100000, has_pages = false },
        getCurrentPage      = function() return 2222 end,
        getPageCount        = function() return 8922 end,
        getXPointer         = function() return XP end,
        getPosFromXPointer  = function(_, xp) return 24904.7 end,
        getTextFromXPointer = function(_, xp) return PARA end,
    }
    for k, v in pairs(opts) do
        if v == false then doc[k] = nil else doc[k] = v end
    end
    return doc
end

-- ============================================================================
print("== 1. _make_anchor（文本锚点规范化）==")
-- ============================================================================
do
    eq("去掉普通空格与换行", State._make_anchor("ab cd\nef"), "abcdef")
    eq("去掉全角空格 U+3000", State._make_anchor("作\u{3000}者一二三四五六"), "作者一二三四五六")
    check("过短的片段返回 nil", State._make_anchor("短") == nil)
    check("两个汉字（6 字节）仍然太短", State._make_anchor("好。") == nil)
    check("刚好 6 个字符可用", State._make_anchor("一二三四五六") ~= nil)
    -- 长度按字符算：20 个汉字必须完整保留（按字节截断只会剩 6 个）
    eq("按字符截断到 20 字", State._utf8_len(State._make_anchor(string.rep("字", 100))), 20)
    check("非字符串返回 nil", State._make_anchor(nil) == nil)
    check("数字返回 nil", State._make_anchor(123) == nil)
    check("空白串返回 nil", State._make_anchor("   \n  ") == nil)
end

do
    eq("_utf8_len 中文按字符计", State._utf8_len("一二三"), 3)
    eq("_utf8_len ASCII", State._utf8_len("abc"), 3)
    eq("_utf8_sub 中文按字符截", State._utf8_sub("一二三四五", 2), "一二")
    eq("_utf8_sub 不越界", State._utf8_sub("一二", 99), "一二")
end

-- ============================================================================
print("== 2. read_position（位置采集）==")
-- ============================================================================
do
    -- 可重排文档：xpointer 走 rolling:getLastProgress()（与 KOSync 同款）
    local ui = {
        document = make_doc(),
        rolling = { getLastProgress = function() return XP end },
        view = { footer = { percent_finished = 0.24904729881192558 } },
    }
    local entry = State.read_position(ui)
    eq("xpointer 取自 rolling:getLastProgress", entry.xpointer, XP)
    eq("页码", entry.page, 2222)
    eq("总页数", entry.total_pages, 8922)
    eq("percent 取自状态栏", entry.percent, 0.24904729881192558)
    check("pos_percent 已计算", entry.pos_percent ~= nil)
    eq("pos_percent 等于 位置/文档高度", math.floor(entry.pos_percent * 1e6) / 1e6, 0.249047)
    check("text_anchor 已提取", entry.text_anchor ~= nil)
    eq("text_anchor 为段落开头 20 字", entry.text_anchor, State._utf8_sub(PARA, 20))
    eq("book_name 去掉 .epub 后缀", entry.book_name, "死人经 (冰临神下) (Z-Library)")
end

do
    -- 固定版式：getLastProgress 返回页码
    local ui = {
        document = make_doc({ getXPointer = false, getTextFromXPointer = false,
                              getPosFromXPointer = false, info = { doc_height = 0, has_pages = true } }),
        paging = { getLastProgress = function() return 581 end },
    }
    local entry = State.read_position(ui)
    eq("页码取自 paging:getLastProgress", entry.page, 581)
    check("没有 xpointer", entry.xpointer == nil)
    check("没有 pos_percent", entry.pos_percent == nil)
    check("没有 text_anchor", entry.text_anchor == nil)
end

do
    -- 接口缺失/抛异常时不能崩，应安静降级
    local ui = {
        document = make_doc({
            getPosFromXPointer = function() error("boom") end,
            getTextFromXPointer = function() error("boom") end,
        }),
        rolling = { getLastProgress = function() error("boom") end },
        footer = { percent_finished = 0.5 },
    }
    local ok, entry = pcall(State.read_position, ui)
    check("不抛异常", ok, entry)
    if ok then
        eq("percent 仍然可用", entry.percent, 0.5)
        check("pos_percent 降级为 nil", entry.pos_percent == nil)
        check("text_anchor 降级为 nil", entry.text_anchor == nil)
    end
end

do
    -- 段落太短（少于 6 字）不应成为锚点，否则会满书误命中
    local ui = {
        document = make_doc({ getTextFromXPointer = function() return "好。" end }),
        rolling = { getLastProgress = function() return XP end },
    }
    local entry = State.read_position(ui)
    check("过短段落不生成 text_anchor", entry.text_anchor == nil)
end

-- ============================================================================
print("== 3. decode（记录校验）==")
-- ============================================================================
do
    local base = {
        schema_version = 1, book_id = "d31f852b", percent = 0.25,
        xpointer = XP, pos_percent = 0.249, text_anchor = PARA:sub(1, 32),
        page = 2222, total_pages = 8922,
    }
    json_next = base
    local rec = State.decode('{"anything":1}')
    check("接受带新字段的记录", rec ~= nil)
    eq("新字段原样保留", rec and rec.pos_percent, 0.249)
    eq("文本锚点原样保留", rec and rec.text_anchor, PARA:sub(1, 32))

    json_next = { schema_version = 1, book_id = "x", percent = 0.5 }
    check("缺少新字段的旧记录仍可读", State.decode("{}") ~= nil)

    json_next = { schema_version = 2, book_id = "x", percent = 0.5 }
    check("拒绝未知 schema_version", State.decode("{}") == nil)

    json_next = { schema_version = 1, book_id = "", percent = 0.5 }
    check("拒绝空 book_id", State.decode("{}") == nil)

    json_next = { schema_version = 1, book_id = "x", percent = 1.5 }
    check("拒绝越界 percent", State.decode("{}") == nil)

    json_next = nil
    check("拒绝非法 JSON", State.decode("not json") == nil)
    check("拒绝空串", State.decode("") == nil)
end

-- ============================================================================
print("== 4. 紧凑载荷（体积与向后兼容）==")
-- ============================================================================
-- 背景：实测一份真实记录 541 字节，而 Moon+ Reader 的 .po 只有 28 字节。
-- Moon+ 能那么小是因为它文件名固定（载荷不必带书籍身份）、只存自己的字符偏移、
-- 单文件覆盖写。墨桥做不到那么小（xpointer 本身就是 46 字节的内容锚点，
-- 而且保留追加式历史），但完全可以砍掉上传方的本机信息与冗余精度。
local REAL_ENTRY = {
    schema_version = 1,
    book_id = "d31f852ba4d127fb9fc230956ecd6b1d",
    device_id = "1791209408-8147",
    device_label = "c7t",
    book_file = "/storage/emulated/0/Books/死人经 (冰临神下) (Z-Library).epub",
    book_name = "死人经 (冰临神下) (Z-Library)",
    page = 1000,
    total_pages = 8922,
    percent = 0.11208249271463798,
    pos_percent = 0.11178582603430151,
    xpointer = "/body/DocFragment[138]/body/div/p[41]/text().0",
    text_anchor = "楼里终于清静了，铁寒锋肚子里的疑问比徒弟还多",
    updated_at = 1791262716,
}

do
    local payload = State.to_payload(REAL_ENTRY)
    check("使用短字段名 sv/id/di/dl",
        payload.sv == 1 and payload.id == REAL_ENTRY.book_id
        and payload.di == REAL_ENTRY.device_id and payload.dl == "c7t")
    eq("不写入 book_file（上传方本机绝对路径）", payload.book_file, nil)
    eq("不写入 book_name（云端文件名已含书名）", payload.book_name, nil)
    eq("内容比例保留 5 位小数", payload.pp, 0.11179)
    eq("页序比例保留 5 位小数", payload.p, 0.11208)
    eq("xpointer 原样保留", payload.xp, REAL_ENTRY.xpointer)
    eq("时间戳保留", payload.t, 1791262716)
end

do
    local text = State.encode(REAL_ENTRY)
    -- 原实现约 540 字节；book_file + book_name 就占约 137 字节。
    -- 留一点余量，一旦有人再往载荷里塞本机信息，这里会立刻红灯。
    check("编码后不超过 300 字节", #text <= 300, #text)
    check("载荷里没有本机路径", text:find("/storage/", 1, true) == nil)
    check("载荷里没有书名", text:find("死人经", 1, true) == nil)
    print(string.format("        （编码后实际 %d 字节，原实现约 541 字节）", #text))
end

do
    local back = State.from_payload(State.to_payload(REAL_ENTRY))
    eq("往返后 book_id 不变", back.book_id, REAL_ENTRY.book_id)
    eq("往返后 xpointer 不变", back.xpointer, REAL_ENTRY.xpointer)
    eq("往返后 text_anchor 不变", back.text_anchor, REAL_ENTRY.text_anchor)
    eq("往返后 page 不变", back.page, 1000)
    eq("往返后不引入 book_file", back.book_file, nil)
end

do
    -- 云上已有的旧记录（长字段名）必须仍能解析，否则升级即失效
    json_next = {
        schema_version = 1,
        book_id = "d31f852ba4d127fb9fc230956ecd6b1d",
        book_name = "死人经 (冰临神下) (Z-Library)",
        book_file = "/mnt/us/documents/死人经.epub",
        percent = 0.23017,
        xpointer = "/body/DocFragment[283]/body/div/p[24]/text().23",
        page = 2000, total_pages = 8689,
    }
    local rec = State.decode("{}")
    check("旧版长字段名仍可解析", rec ~= nil)
    eq("旧记录 book_id", rec and rec.book_id, "d31f852ba4d127fb9fc230956ecd6b1d")
    eq("旧记录 xpointer", rec and rec.xpointer, "/body/DocFragment[283]/body/div/p[24]/text().23")
    check("旧记录的 book_name 原样保留",
        rec and rec.book_name == "死人经 (冰临神下) (Z-Library)")
end

do
    json_next = { sv = 1, id = "abc123", p = 0.5, pp = 0.49, pg = 100, t = 1 }
    local rec = State.decode("{}")
    check("新版短字段名可解析", rec ~= nil)
    eq("sv -> schema_version", rec and rec.schema_version, 1)
    eq("id -> book_id", rec and rec.book_id, "abc123")
    eq("pp -> pos_percent", rec and rec.pos_percent, 0.49)
    eq("pg -> page", rec and rec.page, 100)
end

print(string.format("\n合计：%d 通过，%d 失败", passed, failed))
if failed > 0 then os.exit(1) end
print("全部通过。")
