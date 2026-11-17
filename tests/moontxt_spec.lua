-- TXT 坐标与编码纯数据测试：不依赖归档、系统 iconv 或 crengine。
local root = (arg[0]:match("^(.*)[/\\]") or ".") .. "/../inkbridge.koplugin"
package.path = root .. "/?.lua;" .. package.path
local Txt = require("inkbridge_moontxt")
local Moon = require("inkbridge_moon")
local passed, failed = 0, 0
local function eq(label, got, want)
    if got == want then passed = passed + 1 else
        failed = failed + 1
        print("FAIL " .. label .. " got=" .. tostring(got) .. " want=" .. tostring(want))
    end
end
local function reject(label, value, err)
    eq(label, value, nil)
    eq(label .. "有原因", type(err), "string")
end
local function po(model, offset)
    return { star = 0, at = 0, hash = offset, pct = offset / model.total * 100 }
end
eq("txt后缀", Txt.is_txt("/a/中文.TXT"), true)
eq("epub不是txt", Txt.is_txt("a.epub"), false)
eq("伪后缀", Txt.is_txt("a.txt.zip"), false)
eq("空路径", Txt.is_txt(nil), false)

local body = "第一段中文正文足够长可以核对。\r\n  第二段中文正文也足够长可以核对。\n第三段结尾正文。"
local m = assert(Txt.from_bytes("\239\187\191" .. body))
eq("仅剔除开头BOM", m.text, body)
eq("CRLF两单元且保留空格", m.total, Moon.utf8_len(body))
eq("内部BOM保留", assert(Txt.from_bytes("甲\239\187\191乙")).total, 3)
eq("BOM编码名", m.encoding, "UTF-8 BOM")
eq("无BOM编码名", assert(Txt.from_bytes(body)).encoding, "UTF-8")
local offset = Moon.utf8_len("第一段中文正文足够长可以核对。\r\n  ")
local position = assert(Txt.position(m, po(m, offset), 48, .2))
eq("第二段真实偏移", position.character_offset, offset)
eq("不跨行取锚", position.snippet, "第二段中文正文也足够长可以核对。")
eq("保留内部英文空格", assert(Txt.position(assert(Txt.from_bytes("English words keep their spaces here.")),
    {star=0,at=0,hash=0,pct=0})).snippet, "English words keep their spaces here.")
eq("空白可向后取同段正文", assert(Txt.position(m, po(m, offset - 2))).snippet, position.snippet)
eq("CRLF起点借同段前文", assert(Txt.position(m, po(m, Moon.utf8_len("第一段中文正文足够长可以核对。")))).snippet,
    "第一段中文正文足够长可以核对。")
eq("段末剩一字借同段前文", assert(Txt.position(m, po(m, Moon.utf8_len("第一段中文正文足够长可以核对")))).snippet,
    "第一段中文正文足够长可以核对。")
eq("LF半边仍借同段前文", assert(Txt.position(m, po(m, Moon.utf8_len("第一段中文正文足够长可以核对。") + 1))).snippet,
    "第一段中文正文足够长可以核对。")
reject("负偏移", Txt.position(m, po(m, -1)))
reject("越界", Txt.position(m, po(m, m.total)))
reject("非整数", Txt.position(m, po(m, 1.5)))
reject("非数字", Txt.position(m, {star=0,at=0,hash="1",pct=1}))
reject("拒绝未知star", Txt.position(m, {star=1,at=0,hash=0,pct=0}))
reject("拒绝未知at", Txt.position(m, {star=0,at=1,hash=0,pct=0}))
reject("拒绝缺at", Txt.position(m, {star=0,hash=0,pct=0}))
reject("百分比不符", Txt.position(m, {star=0,at=0,hash=0,pct=30}))
reject("百分比NaN", Txt.position(m, {star=0,at=0,hash=0,pct=0/0}))
reject("短行不借后段", Txt.position(assert(Txt.from_bytes("短行\n下一段是完全无关的正文不可借用")), {star=0,at=0,hash=0,pct=0}))
reject("不跨长空白", Txt.position(assert(Txt.from_bytes(string.rep(" ", 300) .. body)), {star=0,at=0,hash=0,pct=0}))
local context = assert(Txt.from_bytes("紧邻前一段的正文足够长以便唯一核对。\r\n轰——！\r\n后文不可借字跳过短段。"))
local contextual = assert(Txt.position(context,po(context,Moon.utf8_len("紧邻前一段的正文足够长以便唯一核对。\r\n"))))
eq("短段只借紧邻前一段", contextual.snippet, "紧邻前一段的正文足够长以便唯一核对。")
eq("短段借上下文必须披露", type(contextual.anchor_note), "string")
local two_short = assert(Txt.from_bytes("短段\r\n短句\r\n后文足够长也不可跳过去。"))
reject("紧邻前段也短不越过它", Txt.position(two_short,po(two_short,4)))

local astral = assert(Txt.from_bytes("😀第二段中文正文足够长可以核对。"))
eq("非BMP算两个单元", astral.total, Moon.utf8_len(astral.text) + 1)
reject("代理对中间拒绝", Txt.position(astral, po(astral, 1)))
eq("代理对之后正确", assert(Txt.position(astral, po(astral, 2))).snippet, "第二段中文正文足够长可以核对。")

local le = string.char(255,254,0x3D,0xD8,0x00,0xDE,0x2D,0x4E,13,0,10,0)
local be = string.char(254,255,0xD8,0x3D,0xDE,0x00,0x4E,0x2D,0,13,0,10)
for _, bytes in ipairs({le, be}) do
    local u = assert(Txt.from_bytes(bytes))
    eq("UTF16正文", u.text, "😀中\r\n")
    eq("UTF16保留换行单元", u.total, 5)
end
reject("UTF16奇数", Txt.from_bytes(le .. "a"))
reject("UTF16高代理无下文", Txt.from_bytes(string.char(255,254,0,0xD8)))
reject("UTF16高代理配普通字", Txt.from_bytes(string.char(255,254,0,0xD8,65,0)))
reject("UTF16孤立低代理", Txt.from_bytes(string.char(255,254,0,0xDC)))
reject("UTF32拒绝", Txt.from_bytes(string.char(255,254,0,0,65,0,0,0)))
reject("空串", Txt.from_bytes(""))
reject("只有BOM", Txt.from_bytes("\239\187\191"))
reject("只有空白", Txt.from_bytes("\r\n\t  "))
reject("二进制NUL", Txt.from_bytes("hello\0world"))
reject("其他控制符", Txt.from_bytes("hello\1world"))
for _, bad in ipairs({"\192\128", "\237\160\128", "\244\144\128\128", "\128", "\224\128\128"}) do
    reject("BOM后非法UTF8", Txt.from_bytes("\239\187\191" .. bad))
end

local gb = assert(Txt.from_bytes(string.char(214,208,206,196,178,226,202,212)))
eq("GB双字节", gb.text, "中文测试")
eq("GB编码", gb.encoding, "GB18030")
eq("GB字符数不是字节数", gb.total, 4)
eq("GB四字节非BMP", assert(Txt.from_bytes(string.char(148,57,252,54))).text, "😀")
eq("GB四字节非BMP单元", assert(Txt.from_bytes(string.char(149,50,130,54))).total, 2)
eq("GB欧元", assert(Txt.from_bytes(string.char(162,227))).text, "€")
reject("GB非法尾字节", Txt.from_bytes(string.char(129,127)))
reject("GB截断", Txt.from_bytes(string.char(129,48,129)))
reject("GB四字节未分配", Txt.from_bytes(string.char(254,57,254,57)))
reject("GB不允许0xFF", Txt.from_bytes(string.char(255)))

local function doc(text, index)
    return { getXPointer = function() return "/FictionBook/body/section[3]/p[9]/text()." .. tostring(index or 0) end,
        getTextFromXPointer = function() return text end }
end
local r = assert(Txt.document_position(m, doc("第二段中文正文也足够长可以核对。")))
eq("反向还原含空白源偏移", r.hash, offset)
eq("TXT固定单元0", r.section, 0)
local r2 = assert(Txt.document_position(m, doc("第二段中文正文也足够长可以核对。", 2)))
eq("反向节点偏移不是整段起点", r2.hash, offset + 2)
local a = assert(Txt.document_position(astral, doc(astral.text, 1)))
eq("crengine码点偏移转MoonUTF16", a.hash, 2)
reject("无节点接口拒绝", Txt.document_position(m, {}))
reject("无节点偏移拒绝", Txt.document_position(m, {getXPointer=function() return "/p" end,getTextFromXPointer=function() return body end}))
reject("节点短文本拒绝", Txt.document_position(m, doc("正文")))
reject("异版节点拒绝", Txt.document_position(m, doc("这是完全不在源文件中的另一段文字。")))
reject("源重复拒绝", Txt.document_position(assert(Txt.from_bytes(body .. "\r\n" .. body)), doc("第二段中文正文也足够长可以核对。")))
reject("节点抛错拒绝", Txt.document_position(m, {getXPointer=function() error("broken") end,getTextFromXPointer=function() return body end}))

-- 跨稀疏索引边界：空白、CRLF 与非 BMP 均不能造成累计偏移漂移。
local long_prefix = string.rep("😀 中\r\n", 1800)
local long = assert(Txt.from_bytes(long_prefix .. "唯一长尾正文用于跨索引边界精确核对。"))
local expected = 6 * 1800 -- 😀=2、空格=1、中=1、CRLF=2。
eq("长文本UTF16总数", long.total, expected + 18)
local lp = assert(Txt.document_position(long, doc("唯一长尾正文用于跨索引边界精确核对。")))
eq("反向跨索引", lp.hash, expected)
eq("正向跨索引", assert(Txt.position(long, po(long, expected))).snippet, "唯一长尾正文用于跨索引边界精确核对。")

-- 真正的 Moon+ 坐标：原文块起点 + 经过 CRLF/缩进处理的显示偏移。
for _, size in ipairs({4096, 8192}) do
    for _, indent in ipairs({false, true}) do
        local profile = {block_size=size, indent=indent}
        local prefix = string.rep("甲", size)
        local line1 = "块首正文足够长用于核对。"
        local target = "唯一目标正文这里不能出现跨段误差。"
        local src = prefix .. line1 .. "\r\n\r\n    " .. target
        local model = assert(Txt.from_bytes(src))
        local remote = size + Moon.utf8_len(line1) + 2 + (indent and 0 or 4)
        local source = size + Moon.utf8_len(line1) + 8
        local actual = assert(Txt.position(model, po(model, remote), 48, .2, profile))
        eq("块内CRLF/缩进映射", actual.source_offset, source)
        eq("块内锚点不漂移", actual.snippet, target)
        local rev = assert(Txt.document_position(model, doc(target), profile))
        eq("反向编码显示偏移", rev.hash, remote)
        eq("反向往返核对", Txt.source_offset(model, rev.hash, profile), source)
        eq("切配置不会用旧块缓存", assert(Txt.position(model, po(model, remote), 48, .2, profile)).snippet, target)
    end
end
local single = assert(Txt.from_bytes("第一行正文足够长用于核对。\r\n    第二行正文足够长用于定位。"))
local profile = {block_size=4096,indent=true}
local single_hash = Moon.utf8_len("第一行正文足够长用于核对。") + 2
eq("中文单换行转双换行", assert(Txt.position(single,po(single,single_hash),48,.2,profile)).snippet,
    "第二行正文足够长用于定位。")
eq("中文单换行反向", assert(Txt.document_position(single,doc("第二行正文足够长用于定位。"),profile)).hash, single_hash)
reject("非法配置不崩溃", Txt.source_offset(single,0,{}))
reject("非法块长拒绝", Txt.source_offset(single,0,{block_size=2048,indent=true}))
reject("非法缩进类型拒绝", Txt.source_offset(single,0,{block_size=4096,indent=1}))
local sampling_prefix = string.rep("\n\n甲",100) .. string.rep("😀",100) .. "\n" .. string.rep("乙\n",80)
local sampling_target = "采样按代理对单元判断才可准确定位。"
local sampling = assert(Txt.from_bytes(sampling_prefix .. sampling_target .. string.rep("丙",1340)))
local sampling_source = 300 + 200 + 1 + 160
eq("双换行采样阈值按UTF16", assert(Txt.document_position(sampling,doc(sampling_target),profile)).hash,
    sampling_source + 81)
eq("双换行UTF16采样映射往返", Txt.source_offset(sampling,sampling_source+81,profile),sampling_source)
reject("显示代理项拒绝", Txt.position(astral,po(astral,1),48,.2,profile))
local cut = assert(Txt.from_bytes(string.rep("甲",4095) .. "😀后续正文足够长用于核对。"))
reject("块边界劈代理项拒绝", Txt.position(cut,po(cut,4097),48,.2,profile))
local tiny = assert(Txt.from_bytes("  足够长正文用于拒绝显示尾部越界坐标。\r\n\r\n"))
reject("原文有效显示越界仍拒绝", Txt.position(tiny,po(tiny,tiny.total-1),48,.2,profile))

print(string.format("合计：%d 通过，%d 失败", passed, failed))
os.exit(failed == 0 and 0 or 1)
