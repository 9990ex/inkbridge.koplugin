package.path = "inkbridge.koplugin/?.lua;" .. package.path
local Preview = require("inkbridge_home_preview")
local Rebuild = require("inkbridge_rebuild")
local passed, failed = 0, 0
local function check(name, value)
    if value then passed = passed + 1 else failed = failed + 1; print("FAIL " .. name) end
end
local records = {
    { text = "真实的文字" }, { text = "第一章开始" }, { text = "重复的正文" }, { text = "缺失的锚点" },
}
local analyzer = Preview.analyzer(records)
analyzer:feed(Rebuild.paragraphs("<html><head><title>错误的页面标题</title></head><body>"
    .. "<h1>第一章 开始</h1><p>这是真实的文字，后面还有一整段需要展示的正文。</p>"
    .. "<p>重复的正文。</p></body></html>"))
analyzer:feed(Rebuild.paragraphs("<body><p>本章延续到下一份正文文件。</p><h2>第二章 转折</h2>"
    .. "<p>重复的正文。</p><p>第二章的内容不能混到第一章选段。</p></body>"))
local result = analyzer:results()
check("从原书命中位置向后提取实际正文", result[1].status == "verified"
    and result[1].excerpt:find("真实的文字，后面还有一整段需要展示的正文。", 1, true) == 1)
check("真实章节取正文标题而非head标题", result[1].chapter == "第一章 开始")
check("标题锚点改取紧随标题的正文", result[2].chapter == "第一章 开始"
    and result[2].excerpt:find("这是真实的文字", 1, true) == 1 and not result[2].excerpt:find("第一章", 1, true))
check("选段可延续到同章下一正文文件", result[1].excerpt:find("本章延续到下一份正文文件。", 1, true) ~= nil)
check("选段不跨入下一章节", not result[1].excerpt:find("第二章", 1, true))
check("全书重复锚点拒绝选错章节", result[3].status == "ambiguous" and result[3].chapter == nil
    and result[3].excerpt == nil)
check("原书中找不到锚点不捏造选段", result[4].status == "missing" and result[4].excerpt == nil)
check("整理选段不修改同步锚点", records[1].text == "真实的文字" and records[1].excerpt == nil)
analyzer = Preview.analyzer({ { text = "跨越段落" } })
analyzer:feed({ { text = "第一节：测试", heading = true }, { text = "正文跨越" }, { text = "段落边界仍是真实文字。" } })
result = analyzer:results()
check("支持锚点跨段落边界", result[1].status == "verified" and result[1].excerpt:find("跨越 段落", 1, true))
analyzer = Preview.analyzer({ { text = "第一章 空章" } })
analyzer:feed({ { text = "第一章 空章", heading = true }, { text = "第二章 下一章", heading = true }, { text = "别章正文" } })
result = analyzer:results()
check("空章不能拿下一章正文冒充选段", result[1].status == "no_body" and result[1].excerpt == "")
analyzer = Preview.analyzer({ { text = "第一回见面的时候" } })
analyzer:feed({ { text = "第一回见面的时候，他很紧张。" } })
result = analyzer:results()
check("正文句子不冒充章节名", result[1].chapter == nil and result[1].status == "verified")
analyzer = Preview.analyzer({ { text = "正文" } })
analyzer:feed({ { text = "正文" .. string.rep("中", 300) } })
result = analyzer:results()
check("长选段按完整UTF8字符截断", result[1].excerpt == "正文" .. string.rep("中", 218))

local files = {
    ["META-INF/container.xml"] = '<container><rootfiles><rootfile full-path="OPS/book.opf"/></rootfiles></container>',
    ["OPS/book.opf"] = '<package><manifest><item id="a" href="a.xhtml" media-type="application/xhtml+xml"/>'
        .. '<item id="b" href="b.xhtml" media-type="application/xhtml+xml"/></manifest>'
        .. '<spine><itemref idref="a"/><itemref idref="b"/></spine></package>',
    ["OPS/a.xhtml"] = '<body><h1>第一章 起点</h1><p>原书唯一命中的正文，可以展开更多后续文字。</p></body>',
    ["OPS/b.xhtml"] = '<body><h1>第二章 终点</h1><p>下一章正文。</p></body>',
}
local queue, closed, opened = {}, 0, 0
local archiver = { Reader = {} }
function archiver.Reader:new()
    return { open = function() opened = opened + 1; return true end,
        close = function() closed = closed + 1 end,
        iterate = function()
            local key
            return function()
                key = next(files, key)
                if key then return { path = key, size = #files[key], mode = "file" } end
            end
        end,
        extractToMemory = function(_, path) return files[path] end,
    }
end
local mtime = 1
local lfs = { attributes = function() return { mode = "file", size = 100, modification = mtime } end }
local UI = { nextTick = function(_, fn) queue[#queue + 1] = fn end }
local id = "0123456789abcdef0123456789abcdef"
local book = { file = "sample.epub", book_id = id, records = { { text = "原书唯一命中" } } }
local deps = { UI = UI, lfs = lfs, Archiver = archiver, identify = function() return id end }
local function drain() while #queue > 0 do table.remove(queue, 1)() end end
local completed
Preview.start(book, function(...) completed = { ... } end, deps)
check("先显示页面再异步读取原书", opened == 0 and completed == nil)
table.remove(queue, 1)()
check("处理一份正文后让出UI", opened == 1 and completed == nil and #queue == 1)
drain()
check("真实归档读取完成返回章节和选段", completed and completed[1]
    and completed[2][1].chapter == "第一章 起点" and completed[2][1].excerpt:find("更多后续文字", 1, true))
check("完成后关闭归档且返回文件指纹", closed == 1 and completed[3] == Preview.stamp(book.file, lfs))
completed = nil
local cancel = Preview.start(book, function(...) completed = { ... } end, deps)
table.remove(queue, 1)(); cancel(); drain()
check("离开页面中止解析并关闭归档", completed == nil and closed == 2)
Preview.start(book, function(...) completed = { ... } end, deps)
table.remove(queue, 1)(); mtime = 2; drain()
check("解析期间原书变化拒绝提交旧选段", completed and completed[1] == false and closed == 3)
deps.identify = function() return "other-book" end
Preview.start(book, function(...) completed = { ... } end, deps); drain()
check("完整书籍身份不符时不打开原书", completed[1] == false and opened == 3)
print(string.format("合计：%d 通过，%d 失败", passed, failed))
os.exit(failed == 0 and 0 or 1)
