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

-- rapidjson 桩：只记录最后一次交给 decode 的文本，返回预置结果
local json_next
package.preload["rapidjson"] = function()
    return {
        encode = function() return "{}" end,
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
    -- 长度按字符算：32 个汉字必须完整保留（按字节截断只会剩 10 个）
    eq("按字符截断到 32 字", State._utf8_len(State._make_anchor(string.rep("字", 100))), 32)
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
    eq("text_anchor 为段落开头 32 字", entry.text_anchor, State._utf8_sub(PARA, 32))
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

print(string.format("\n合计：%d 通过，%d 失败", passed, failed))
if failed > 0 then os.exit(1) end
print("全部通过。")
