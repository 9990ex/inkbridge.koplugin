-- 正文保留、章名识别、spine 顺序、合法 EPUB 打包和失败清理。
dofile("tests/material_business_stub.lua")
package.path = "inkbridge.koplugin/?.lua;" .. package.path
local R = require("inkbridge_rebuild")
local passed, failed = 0, 0
local function check(label, condition)
    if condition then passed = passed + 1 else failed = failed + 1 end
    print((condition and "PASS " or "FAIL ") .. label)
end
local function has(text, needle) return text and text:find(needle, 1, true) ~= nil end
local Progress = require("inkbridge_rebuild_progress")
local percent, label = Progress.describe("text", 3, 10)
check("实际正文文件数对应进度", percent == 27 and has(label, "3／10"))
percent, label = Progress.describe("verify", 10, 10)
check("校验完仍不提前声称已发布", percent == 99 and has(label, "10／10"))
check("初始阶段不编造文件数", Progress.describe("prepare", 0, 0) == 0)
check("生成目录阶段明确显示", Progress.describe("package", 0, 0) == 90)
check("畸形进度拒绝", not Progress.describe("text", 10, 1))
check("未知阶段拒绝", not Progress.describe("unknown", 0, 0))
local progress_path = (os.getenv("TEMP") or "/tmp") .. "/ib-rebuild-progress-spec"
local clock = 0
local write_progress = Progress.writer(progress_path, function() return clock end)
write_progress("text", 0, 10)
write_progress("text", 1, 10)
check("一秒内不重复写入刷新", Progress.read(progress_path) == 0)
clock = 1
write_progress("text", 5, 10)
check("经过一秒更新真实计数", Progress.read(progress_path) == 45)
write_progress("package", 0, 0)
check("阶段切换立即报告", Progress.read(progress_path) == 90)
write_progress("verify", 0, 10)
write_progress("verify", 10, 10)
check("最后一个文件立即报告", Progress.read(progress_path) == 99)
os.remove(progress_path)
check("无进度文件时保持原状态", not Progress.read(progress_path))

check("十六进制中文实体", R.decode("&#x4E2D;&#25991;") == "中文")
check("四字节实体", R.decode("&#x1F600;") == "😀")
check("实体只解码一次", R.decode("&amp;lt;") == "&lt;")
check("未知实体保留文字", R.decode("&unknown;") == "&unknown;")
check("非法实体拒绝", not pcall(R.decode, "&#xD800;"))
check("NUL 实体拒绝", not pcall(R.decode, "&#0;"))
for _, title in ipairs({ "第一章 风起", "第123回", "第两百章", "第一卷", "番外：回家", "Chapter 12: Home" }) do
    check("识别标题 " .. title, R.is_heading(title))
end
check("普通文字不是标题", not R.is_heading("他走进了第一章提到的地方。"))
check("部门不是分部", not R.is_heading("第一部门开始行动"))
check("长正文即使包含章名也不分章", not R.is_heading("第一章" .. string.rep("甲", 100)))
for _, sentence in ipairs({ "第一回见面的时候，他很紧张。", "第二节课上，老师点了他的名字。",
    "第一部电影上映之后，票房大卖。", "第三篇文章写得最好。", "第一集团军开始进攻。",
    "第一回合，李经、马伸连着南方道学一系大败而归。" }) do
    check("正文句子不是标题 " .. sentence, not R.is_heading(sentence))
end
for _, title in ipairs({ "第一章风起", "第十章 卷入风波", "第三回：你是谁？", "第一卷　风起，云涌",
        "第十章风起，云涌" }) do
    check("带章名的标题仍识别 " .. title, R.is_heading(title))
end
check("章名里的卷字不算卷", not R.is_volume("第十章 卷入风波") and not R.is_volume("第一章 卷土重来"))
check("真正的卷标题", R.is_volume("第一卷 风起") and R.is_volume("第十二卷"))
local nested = R.paragraphs("<h1><div>雨夜</div></h1><p>甲</p>")
check("标题内嵌套块保留标题标记", nested[1].text == "雨夜" and nested[1].heading and not nested[2].heading)
local scripted = R.paragraphs("<p>甲</p><script>if (a<b) { x() }</script><STYLE>p>a{}</STYLE><p>乙</p>")
check("脚本样式里的小于号不破坏正文", #scripted == 2 and scripted[1].text == "甲" and scripted[2].text == "乙")
check("未结束的脚本拒绝", not pcall(R.paragraphs, "<p>甲</p><script>a<b"))
check("原目录整行命中", R.is_heading("雨夜", { ["雨夜"] = true }))
check("HTML 标题可识别", R.is_heading("雨夜", {}, true))
check("父目录归一", R.resolve("OEBPS/Text", "../章%20一.xhtml#anchor") == "OEBPS/章 一.xhtml")
check("根目录逃逸拒绝", not R.resolve("", "../a.xhtml"))
check("外部地址拒绝", not R.resolve("OPS", "https://a/b"))
check("编码控制字符拒绝", not R.resolve("OPS", "a%00b"))

local p = R.paragraphs([=[<?xml version="1.0"?><html><head><title>不取</title><style>x</style></head><body>
<div><h1><span>第一章</span></h1><p data-x="a>b">甲<span>乙</span>&#x4E19;&amp;lt;</p>
<p>hello <i>world</i>.</p><p>第一行<br/>第二行</p><!-- <p>不取</p> -->
<script>不取</script><nav><p>目录不取</p></nav><p><![CDATA[小于 < 大于 >]]></p><p>末段<img src="x"/></p></div>
</body></html>]=])
check("嵌套容器不重复取字", #p == 7)
check("嵌套 span 不丢标题", p[1].text == "第一章" and p[1].heading)
check("引号内大于号及数字实体", p[2].text == "甲乙丙&lt;")
check("英文词间空格保留", p[3].text == "hello world.")
check("br 保留段落边界", p[4].text == "第一行" and p[5].text == "第二行")
check("CDATA 不当标签", p[6].text == "小于 < 大于 >")
local empty_heading = R.paragraphs("<h1/><p>普通正文</p>")
check("自闭合标题不会污染后续段落", #empty_heading == 1 and not empty_heading[1].heading)
local script_ok, after_script = pcall(R.paragraphs, '<x:script><![CDATA[ a<b; x="</x:script>"; ]]></x:SCRIPT ><p>正文</p>')
check("带命名空间的脚本跳过 CDATA 中的假闭标签", script_ok and #after_script == 1 and after_script[1].text == "正文")
check("正文尾段保留", p[7].text == "末段")
check("截断注释拒绝", not pcall(R.paragraphs, "<p>甲</p><!--"))
check("UTF16 正文拒绝", not pcall(R.paragraphs, "\255\254a\0"))
check("非 UTF8 声明拒绝", not pcall(R.paragraphs, '<?xml encoding="gbk"?><p>abc</p>'))

local container = '<container><rootfiles><rootfile full-path="OPS/main.opf"/></rootfiles></container>'
local opf = [[<package xmlns:dc="urn:dc"><metadata><dc:title>测试 &amp; 小说</dc:title><dc:creator>作者</dc:creator></metadata>
<manifest><item id="b" href="b.xhtml" media-type="application/xhtml+xml"/>
<item id="a" href="a.xhtml" media-type="application/xhtml+xml"/>
<item id="cover" href="cover.png" media-type="image/png"/>
<item id="nav" href="nav.xhtml" properties="nav" media-type="application/xhtml+xml"/></manifest>
<spine><itemref idref="cover"/><itemref idref="nav"/><itemref idref="a"/><itemref idref="b"/></spine></package>]]
local files = { ["META-INF/container.xml"] = container, ["OPS/main.opf"] = opf,
    ["OPS/a.xhtml"] = '<html><body><h1>第一章</h1><p>甲一。</p><p>甲二。</p><h2>第二章</h2><p>乙。</p></body></html>',
    ["OPS/b.xhtml"] = '<p>跨文件接续。</p><p>第三章</p><p>丙 &amp; 丁。</p>' }
local written, sequence, removed, close_count, reads = {}, {}, {}, 0, {}
local fail_write, throw_read, close_error, exists, oversized, verify_error
local Reader = {}
function Reader:new() return setmetatable({}, { __index = self }) end
function Reader:open(path) self.output = path == "work/book.epub"; return true end
function Reader:iterate()
    local data = self.output and written or files
    local paths = {}; for path in pairs(data) do paths[#paths + 1] = path end
    local i = 0
    return function()
        i = i + 1; local path = paths[i]
        if path then return { path = path, size = oversized and path == "OPS/a.xhtml" and 20 * 1024 * 1024 or #data[path], mode = "file" } end
    end
end
function Reader:extractToMemory(path)
    if self.output then return not verify_error and written[path] or nil end
    reads[#reads + 1] = path
    if throw_read then error("read failed") end
    return files[path]
end
function Reader:close() close_count = close_count + 1 end
local Writer = {}
function Writer:new() return setmetatable({}, { __index = self }) end
function Writer:open() return true end
function Writer:setZipCompression() return true end
function Writer:addFileFromMemory(path, data)
    if fail_write then return nil end
    written[path] = data; sequence[#sequence + 1] = path; return true
end
function Writer:close() if close_error then self.err = "disk full" end end
local deps = { lfs = { attributes = function() return exists end }, Archiver = { Reader = Reader, Writer = Writer },
    sha256 = function() return function(s) if not s then return "0123456789abcdef" end end end }
local remove = os.remove
os.remove = function(path) removed[#removed + 1] = path; return true end
local function convert(opts)
    written, sequence, removed, reads = {}, {}, {}, {}
    return R.convert("original.epub", "work/book.epub", opts, deps)
end
local result = convert()
check("完成重新识别", result and result.sections == 3 and result.paragraphs == 5)
check("mimetype 必须排首项", sequence[1] == "mimetype" and written.mimetype == "application/epub+zip")
check("按 spine 而非 manifest 排序", reads[3] == "OPS/a.xhtml" and reads[4] == "OPS/b.xhtml")
check("第一章段落保持独立", has(written["OEBPS/chapter_00001.xhtml"], "<p>甲一。</p>\n<p>甲二。</p>"))
check("第二章跨文件正文接续", has(written["OEBPS/chapter_00002.xhtml"], "跨文件接续。"))
check("重新生成的正文正确转义", has(written["OEBPS/chapter_00003.xhtml"], "丙 &amp; 丁。"))
check("副本元数据与原书不同", has(written["OEBPS/content.opf"], "测试 &amp; 小说－墨桥重构版"))
check("新目录包含所有章节", has(written["OEBPS/toc.ncx"], "第三章"))
check("成功不删除文件", #removed == 0)
local events = {}
result = convert({ progress = function(stage, done, total)
    events[#events + 1] = { stage, done, total }
end })
check("转换先报告准备阶段", events[1][1] == "prepare")
check("转换正文文件数来自真实 spine", events[2][1] == "text" and events[2][2] == 0 and events[2][3] == 2)
check("转换阶段完成报告真实计数", events[4][1] == "text" and events[4][2] == 2)
check("目录生成单独报告", events[5][1] == "package")
local last = events[#events]
check("校验进度跟随实际回读文件", last[1] == "verify" and last[2] == last[3] and last[3] > 3)
result = convert({ progress = function() error("进度文件写入失败") end })
check("进度写入失败不影响转换", result and result.paragraphs == 5 and #removed == 0)
local chapter_a = files["OPS/a.xhtml"]
files["OPS/a.xhtml"] = '<h1>第一卷</h1><p>卷首。</p><p>第十章 卷入风波</p><p>甲。</p>'
result = convert()
check("章名含卷字仍挂在卷下", has(written["OEBPS/toc.ncx"], "卷入风波")
    and written["OEBPS/toc.ncx"]:find("</navPoint></navPoint>", 1, true) ~= nil)
files["OPS/a.xhtml"] = chapter_a
result = convert({ recognize = false })
check("保留分章只按原文件切分", result and result.sections == 2)
check("保留模式中间标题仍作为文字保留", has(written["OEBPS/chapter_00001.xhtml"], "<p>第二章</p>"))
check("保留模式首段正文不丢", has(written["OEBPS/chapter_00002.xhtml"], "<p>跨文件接续。</p>"))
local original_a = files["OPS/a.xhtml"]
files["OPS/a.xhtml"] = '<h1>第一章</h1><h2>雨夜</h2><p>甲。</p><h1>第二章</h1><h2>归途</h2><p>乙。</p>'
result = convert()
check("章号与章名合并，不生成空章", result and result.sections == 3
    and has(written["OEBPS/chapter_00001.xhtml"], "<h1>第一章 雨夜</h1>"))
files["OPS/a.xhtml"] = original_a
local original_b = files["OPS/b.xhtml"]
files["OPS/a.xhtml"], files["OPS/b.xhtml"] = '<h1>重逢</h1>', '<h1>重逢</h1><p>甲。</p>'
result = convert()
check("跨正文文件的同名标题均保留", result and result.sections == 2
    and has(written["OEBPS/chapter_00001.xhtml"], "<h1>重逢</h1>")
    and has(written["OEBPS/chapter_00002.xhtml"], "<h1>重逢</h1>"))
files["OPS/a.xhtml"], files["OPS/b.xhtml"] = original_a, original_b
exists = "file"
result = convert()
check("已有输出拒绝且不删除", not result and #removed == 0)
exists, fail_write = nil, true
result = convert()
check("写入失败只清理工作文件", not result and removed[1] == "work/book.epub")
fail_write, throw_read = nil, true
result = convert()
check("读异常也安全返回", not result and removed[1] == "work/book.epub")
throw_read, oversized = nil, true
result = convert()
check("超大条目提取前拒绝", not result and #reads == 2)
oversized, close_error = nil, true
result = convert()
check("关闭错误不交付副本", not result and removed[1] == "work/book.epub")
close_error = nil
verify_error = true
result = convert()
check("副本回读失败不能交付", not result and removed[1] == "work/book.epub")
verify_error = nil
local saved = files["OPS/b.xhtml"]
files["OPS/b.xhtml"] = nil
result = convert()
check("缺少 spine 正文拒绝，不能交付半本书", not result)
files["OPS/b.xhtml"] = saved
files["OPS/a.xhtml"], files["OPS/b.xhtml"] = "<img src='a'/>", "<img src='b'/>"
result = convert()
check("图片书没有正文时拒绝", not result)
os.remove = remove

local U = require("inkbridge_rebuild_ui")
local reserved = {}
local fs = {
    attributes = function(path) if path == "novel－墨桥重构版.epub" then return "file" end end,
    mkdir = function(path) reserved[#reserved + 1] = path; return true end,
}
local dest, work = U.reserve("novel.epub", fs)
check("已有副本时换名", dest == "novel－墨桥重构版-2.epub")
check("工作目录独占", work == dest .. ".work" and reserved[1] == work)
local renamed = false
local rename = os.rename
os.rename = function() renamed = true; return true end
local ok = U.publish("work/book.epub", "novel－墨桥重构版.epub", fs)
check("发布时再检查目标，已有文件不覆盖", not ok and not renamed)
ok = U.publish("work/missing.epub", "free.epub", fs)
check("发布前要求工作文件存在", not ok and not renamed)
os.rename = rename
check("输入归档总是关闭", close_count >= 8)

-- 取消发生在子进程返回前或返回后，都不能把工作文件发布成副本。
local shown, ui_files, runs, outcome, opened = {}, {}, 0, "success", nil
package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(path) return ui_files[path] end,
    mkdir = function(path) ui_files[path] = "directory"; return true end,
    rmdir = function(path) ui_files[path] = nil end,
}
package.loaded["ui/uimanager"] = { show = function(_, widget) shown[#shown + 1] = widget end,
    close = function() end }
local widget = { new = function(_, opts) return opts end }
package.loaded["ui/widget/buttondialog"] = widget
package.loaded["ui/widget/infomessage"] = widget
package.loaded["logger"] = { warn = function() end }
package.loaded["apps/reader/readerui"] = { showReader = function(_, path) opened = path end }
local run_opts
local progress_stops, progress_shows, progress_trap = 0, 0, {}
package.loaded["inkbridge_rebuild_progress"] = {
    show = function()
        progress_shows = progress_shows + 1
        return progress_trap, function()
            progress_stops = progress_stops + 1
            if outcome == "stop-crash" then error("progress close failed") end
        end
    end,
    writer = function() return function() end end,
}
package.loaded["inkbridge_rebuild"] = { normalize_text = R.normalize_text, convert = function(_, path, opts)
    runs, run_opts = runs + 1, opts
    ui_files[path] = "file"
    if outcome == "failed" then return nil, "磁盘空间不足" end
    return { sections = 3, paragraphs = 10 }
end }
package.loaded["ui/trapper"] = {
    wrap = function(_, fn) fn() end,
    dismissableRunInSubprocess = function(_, fn, trap)
        check("子进程使用可取消的进度卡片", trap == progress_trap)
        if outcome == "crash" then error("worker failure") end
        local value, err = fn()
        return outcome ~= "cancel", value, err
    end,
}
local deletes, publishes = {}, 0
os.remove = function(path) ui_files[path] = nil; deletes[#deletes + 1] = path; return true end
os.rename = function(from, to)
    if outcome == "publish-crash" then error("publish failed") end
    publishes = publishes + 1; ui_files[from], ui_files[to] = nil, "file"; return true
end
local plugin = { ui = { document = { file = "novel.epub", getToc = function()
    return { false, { title = "　雨夜　" } }
end } } }
U.show({})
check("未开书时明确提示且不转换", runs == 0 and has(shown[#shown].text, "EPUB"))
U.show(plugin)
check("重构先说明有损范围与新身份", has(shown[#shown].title, "图片") and has(shown[#shown].title, "原记录"))
check("两个按钮说明分章依据", has(shown[#shown].title, "可能与原目录不同")
    and shown[#shown].buttons[2][1].text == "按原正文文件分章")
shown[#shown].buttons[3][1].callback()
check("选项页取消不生成文件", runs == 0 and publishes == 0)
U.show(plugin)
shown[#shown].buttons[1][1].callback()
check("重新识别在子进程执行且沿用目录标题", runs == 1 and run_opts.recognize == true and run_opts.headings["雨夜"])
check("成功才发布副本", publishes == 1 and has(shown[#shown].title, "重构完成"))
shown[#shown].buttons[1][1].callback()
check("打开副本作为新书", opened == "novel－墨桥重构版.epub")
local before = publishes
for _, mode in ipairs({ "cancel", "failed", "crash" }) do
    outcome, ui_files, deletes = mode, {}, {}
    U.run(plugin, "novel.epub", true)
    check("取消或失败不发布 " .. mode, publishes == before)
    check("取消或失败清工作文件 " .. mode, deletes[1] == "novel－墨桥重构版.epub.work/book.epub"
        and not ui_files["novel－墨桥重构版.epub.work"])
end
outcome, ui_files = "success", {}
U.run(plugin, "novel.epub", false)
check("失败后可重新操作且保留原分章选项", publishes == before + 1 and run_opts.recognize == false)
check("成功取消失败均停止进度刷新", progress_stops == progress_shows and progress_stops == 5)
check("工作目录的进度及半成品均清理", deletes[#deletes] == "novel－墨桥重构版.epub.work/progress.part")
outcome, ui_files = "stop-crash", {}
local stopped_ok = pcall(U.run, plugin, "novel.epub", true)
check("进度卡片关闭异常仍交付已验证副本并清理", stopped_ok and publishes == before + 2
    and not ui_files["novel－墨桥重构版.epub.work"])
outcome, ui_files = "publish-crash", {}
local publish_ok = pcall(U.run, plugin, "novel.epub", true)
check("发布抛异常也清工作目录并提示失败", publish_ok and publishes == before + 2
    and not ui_files["novel－墨桥重构版.epub.work"] and has(shown[#shown].text, "publish failed"))
outcome = "success"
U.run(plugin, "novel.epub", false)
check("异常之后可以重试", publishes == before + 3)
os.remove, os.rename = remove, rename
print(string.format("合计：%d 通过，%d 失败", passed, failed))
os.exit(failed == 0 and 0 or 1)
