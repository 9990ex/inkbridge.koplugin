-- ============================================================================
-- tests/moonsync_spec.lua — 墨桥 × 静读天下「同步模块」回归测试
--
-- 这一层在真机上要联网、要打开 EPUB,没法直接跑,所以依赖全部打桩:
--   * ffi/archiver    → 一个两章的假归档(验证 spine 解析、章节读取、全书字数统计)
--   * socket/ltn12    → 假 HTTP,记录请求表并回放响应(验证 PUT 的构造)
--   * G_reader_settings → 内存设置表
--
-- 重点一:**能不能加载**。上次就是漏了这类检查,把一个语法错误提交并打包了出去。
-- 重点二:写回流程的四个关口 —— 换算、自检、备份、回读校验。
--
-- 运行: luajit tests/moonsync_spec.lua   (在仓库根目录执行)
-- ============================================================================

local script_path = arg and arg[0] or "tests/moonsync_spec.lua"
local script_dir  = script_path:match("^(.*)[/\\][^/\\]*$") or "."
local PLUGIN_DIR  = script_dir .. "/../inkbridge.koplugin"
package.path = PLUGIN_DIR .. "/?.lua;" .. package.path

local passed, failed = 0, 0
local function check(label, cond, detail)
    if cond then passed = passed + 1; print("    PASS  " .. label)
    else failed = failed + 1
        print(string.format("    FAIL  %s%s", label, detail and ("  -> " .. tostring(detail)) or "")) end
end
local function eq(label, got, want)
    check(label, got == want, string.format("得到 %s，期望 %s", tostring(got), tostring(want)))
end

-- ── 打桩 ───────────────────────────────────────────────────────────────────
local shown = {}
local last_request = nil
local http_reply = nil          -- 每个用例可换：function(req) -> 与 socket.http.request 同返回值
local list_folder_reply = nil   -- 每个用例可换：peek_po 取服务器时间时走的目录列表
local list_folder_calls = {}
local settings = {}

_G.G_reader_settings = {
    readSetting = function(_, k) return settings[k] end,
    saveSetting = function(_, k, v) settings[k] = v end,
    delSetting  = function(_, k) settings[k] = nil end,
    has         = function(_, k) return settings[k] ~= nil end,
}

package.preload["ui/uimanager"] = function()
    return { show = function(_, w) shown[#shown + 1] = w end,
             close = function() end, nextTick = function(f) f() end }
end
package.preload["ui/widget/infomessage"] = function() return { new = function(_, o) return o or {} end } end
package.preload["ui/widget/confirmbox"]  = function() return { new = function(_, o) return o or {} end } end
-- 手动选进度文件用到的两个对话框。做成"可观测"的:把最后弹出的内容记下来,
-- 测试才能验证"只列了 .po""列表为空时也留了手动输入这条出路"。
local last_buttondialog = nil
local last_inputdialog  = nil
package.preload["ui/widget/buttondialog"] = function()
    return { new = function(_, o) last_buttondialog = o; return o or {} end }
end
package.preload["ui/widget/inputdialog"] = function()
    return { new = function(_, o)
        o = o or {}
        o.onShowKeyboard = function() end
        o.getInputText  = function() return o._typing end
        last_inputdialog = o
        return o
    end }
end
-- 真正的 inkbridge_webdav 会拉进一大堆 KOReader 模块,这里只用它做跳转,桩掉即可
-- 真正的 inkbridge_webdav 会拉进一大堆 KOReader 模块,这里只用它做跳转,桩掉即可。
-- human_age 给一份等价实现:真机上是 WebDAV.human_age,它本身在 webdav_spec 里有测试;
-- 这里要验的是 peek_label 的**拼装**,不是时间格式化。
package.preload["inkbridge_webdav"] = function()
    return { human_age = function(s)
        if not s or s < 0 then return "未知" end
        if s < 60 then return "刚刚" end
        local m = math.floor(s / 60)
        if m < 60 then return tostring(m) .. " 分钟前" end
        local h = math.floor(m / 60)
        if h < 24 then return tostring(h) .. " 小时前" end
        return tostring(math.floor(h / 24)) .. " 天前"
    end,
    -- peek_po 只用它取**服务器时间**。真实现(只读 PROPFIND,不耗网盘下载额度)的
    -- 控制流由 webdav_spec 覆盖;这边只需要一个可编排的桩。
    list_folder = function(_, folder, cb)
        list_folder_calls[#list_folder_calls + 1] = folder
        local reply = list_folder_reply
        if type(reply) == "function" then reply(cb); return end
        if type(reply) ~= "table" then cb(false, nil, "stub: 未编排"); return end
        cb(reply.ok, reply.items, reply.err)
    end }
end

local is_windows = package.config:sub(1, 1) == "\\"
package.preload["ffi/util"] = function()
    return { makePath = function(dir)
        local cmd = is_windows and ('mkdir "' .. dir .. '" 2>nul') or ('mkdir -p "' .. dir .. '"')
        os.execute(cmd)
    end }
end

-- 假归档:两章。第 1 章 = 标题「第一章」(3) + 两段(各 5);
-- 第 2 章 = 一段(8)。全书 21 字。
local CH1 = '<body><h1>第一章</h1><p>一二三四五</p><p>六七八九十</p></body>'
local CH2 = '<body><p>甲乙丙丁戊己庚辛</p></body>'
local OPF = '<package><manifest>'
    .. '<item id="c1" href="Text/c1.xhtml" media-type="application/xhtml+xml"/>'
    .. '<item id="c2" href="Text/c2.xhtml" media-type="application/xhtml+xml"/>'
    .. '</manifest><spine><itemref idref="c1"/><itemref idref="c2"/></spine></package>'

package.preload["ffi/archiver"] = function()
    return {
        Reader = {
            new = function()
                return {
                    open = function() return true end,
                    iterate = function()
                        local entries = {
                            { path = "mimetype" }, { path = "OEBPS/content.opf" },
                            { path = "OEBPS/Text/c1.xhtml" }, { path = "OEBPS/Text/c2.xhtml" },
                        }
                        local i = 0
                        return function() i = i + 1; return entries[i] end
                    end,
                    extractToMemory = function(_, key)
                        if key == "OEBPS/content.opf" then return OPF end
                        if key == "OEBPS/Text/c1.xhtml" then return CH1 end
                        if key == "OEBPS/Text/c2.xhtml" then return CH2 end
                        return nil
                    end,
                    close = function() end,
                }
            end,
        },
    }
end

package.preload["socket"] = function()
    -- 真 luasocket 的 skip(n, ...) 会丢掉前 n 个返回值;这里有同样的语义,
    -- 否则会把 http.request 的 "1"(成功标志) 当成状态码。
    local unpack = table.unpack or unpack
    return { skip = function(n, ...)
        local t, out = { ... }, {}
        for i = n + 1, #t do out[#out + 1] = t[i] end
        return unpack(out)
    end }
end
package.preload["socket.http"] = function()
    return { request = function(req)
        last_request = req
        if http_reply then return http_reply(req) end
        if req.sink then req.sink("ABCD") end     -- 回放 GET 的正文
        return 1, 200, {}, "HTTP/1.1 200 OK"
    end }
end
package.preload["ltn12"] = function()
    return {
        sink = { table = function(t)
            return function(chunk) if chunk then t[#t + 1] = chunk end return 1 end
        end },
        source = { string = function(s)
            local done = false
            return function() if done then return nil end done = true return s end
        end },
    }
end

local Moon = require("inkbridge_moon")
local MS   = dofile(PLUGIN_DIR .. "/inkbridge_moonsync.lua")

-- 后面的用例会把 MS.request 换成桩(模拟服务器超时/500/403)。**原始实现先留一份**:
-- 桩一旦忘了还原就会泄漏到后面的用例,表现为"我改的是 A,坏的却是 B"的假故障 ——
-- 这一节就真的踩到了(peek_po 拿到的正文是上一个用例的 PUT 内容)。
local REAL_REQUEST = MS.request

-- ── 模块加载 ───────────────────────────────────────────────────────────────
print("== 模块加载与导出 ==")
do
    check("moonsync 能加载(语法/依赖)", type(MS) == "table")
    for _, name in ipairs({ "get_dir", "set_dir", "fetch_po", "section_html", "section_blocks",
                            "section_blocks_tagged", "book_metrics", "get_book_ref",
                            "learn_book_ref", "request", "backup_po", "import_from_moon",
                            "push_to_moon", "_do_push", "build_push_job", "auto_push",
                            "auto_enabled", "set_auto", "local_position", "describe_direction",
                            "peek_po", "peek_label", "format_time" }) do
        check("导出 " .. name, type(MS[name]) == "function")
    end
end

-- ── 目录设置 ───────────────────────────────────────────────────────────────
print("== 同步目录设置 ==")
do
    eq("默认目录", MS.get_dir(), "Apps/Books/.Moon+/Cache")
    MS.set_dir("  Apps/X/  ")
    eq("去空白与尾部斜杠后保存", settings["inkbridge_moon_dir"], "Apps/X")
    eq("读回也是规范化的", MS.get_dir(), "Apps/X")
    MS.set_dir("/Apps/X")
    eq("以 / 开头表示服务器根,必须保留", MS.get_dir(), "/Apps/X")
    MS.set_dir("")
    eq("空串回落到默认", MS.get_dir(), "Apps/Books/.Moon+/Cache")
end

-- ── 账号级常量 ─────────────────────────────────────────────────────────────
print("== 账号级常量(写回要用,只能从云端学) ==")
do
    settings["inkbridge_moon_book_ref"] = nil
    eq("没学过时是 nil", MS.get_book_ref(), nil)
    MS.learn_book_ref("1785683827794")
    eq("学到后读得出", MS.get_book_ref(), "1785683827794")
    MS.learn_book_ref("")
    eq("空串不会覆盖已有值", MS.get_book_ref(), "1785683827794")
end

-- ── 章节读取(两章假归档) ─────────────────────────────────────────────────
print("== 章节读取 ==")
do
    local tagged = MS.section_blocks_tagged("fake.epub", 0)
    check("第 1 章读得出", tagged ~= nil)
    eq("第 1 章块数", #tagged, 3)
    eq("第 1 块是 h1", tagged[1].tag, "h1")
    eq("第 2 块是 p", tagged[2].tag, "p")
    eq("第 1 块文本", tagged[1].text, "第一章")

    local texts = MS.section_blocks("fake.epub", 0)
    eq("只要文本的版本块数一致", #texts, 3)
    eq("文本与标签版内容一致", table.concat(texts), "第一章" .. "一二三四五" .. "六七八九十")

    -- 反向换算接得上:(第 2 个 <p>, 段内 3) → 3 + 5 + 3 = 11
    eq("第 2 个 <p> 段内 3 → 11", Moon.offset_from_tagged(tagged, 2, 3), 11)

    local bad, err = MS.section_blocks_tagged("fake.epub", 99)
    eq("越界章节要拒绝", bad, nil)
    check("越界有原因", type(err) == "string" and err:find("超出本书范围", 1, true) ~= nil)
end

-- ── 全书字数与各章起始 ─────────────────────────────────────────────────────
print("== 全书字数统计(写回算 :% 用) ==")
do
    local m, cached = MS.book_metrics("fake.epub")
    check("统计得出", m ~= nil)
    eq("全书字数", m.total, 21)
    eq("第 1 章起始", m.starts[1], 0)
    eq("第 2 章起始", m.starts[2], 13)
    eq("末尾哨兵 = 总字数", m.starts[3], 21)
    eq("首次是现算的", cached, false)

    local m2, cached2 = MS.book_metrics("fake.epub")
    eq("第二次走缓存", cached2, true)
    eq("缓存值一致", m2.total, 21)
end

-- ── HTTP 请求构造 ──────────────────────────────────────────────────────────
print("== HTTP 请求构造 ==")
do
    local server = { username = "u", password = "p" }
    local code, status, body = MS.request(server, "https://dav/x.po", "PUT", "LINE")
    eq("PUT 返回码", code, 200)
    eq("PUT 用的是 PUT", last_request.method, "PUT")
    eq("PUT 带了 Content-Length", last_request.headers["Content-Length"], "4")
    eq("PUT 带了 Content-Type", last_request.headers["Content-Type"], "text/plain; charset=utf-8")
    eq("PUT 带了用户名", last_request.user, "u")
    eq("PUT 带了密码", last_request.password, "p")
    check("PUT 没有 sink", last_request.sink == nil)
    check("PUT 有 source", last_request.source ~= nil)

    last_request = nil
    local c2, s2, b2 = MS.request(server, "https://dav/x.po", "GET")
    eq("GET 返回码", c2, 200)
    eq("GET 收回了正文", b2, "ABCD")
    check("GET 没有 source", last_request.source == nil)
    check("GET 有 sink", last_request.sink ~= nil)
end

-- ── 备份 ───────────────────────────────────────────────────────────────────
print("== 覆盖前备份 ==")
do
    local tmp = (os.getenv("TEMP") or "/tmp")
    local path, err = MS.backup_po({ path = tmp }, "book.epub.po", "OLD-LINE\n")
    check("备份成功", path ~= nil, err)
    if path then
        local f = io.open(path, "rb")
        eq("备份内容与云端原值一致", f and f:read("*a"), "OLD-LINE\n")
        if f then f:close() end
        eq("备份文件名带原文件名", path:find("book.epub.po", 1, true) ~= nil, true)
        os.remove(path)
    end
    eq("没有内容时不备份", MS.backup_po({ path = tmp }, "book.epub.po", ""), nil)
    eq("拿不到插件目录时报错", MS.backup_po({}, "book.epub.po", "X"), nil)
end

-- ── 写入流程:_do_push ──────────────────────────────────────────────────────
print("== 写入流程(备份 → PUT → 回读校验) ==")
do
    local tmp = (os.getenv("TEMP") or "/tmp")
    local new_line = "1785683827794*1146@0#458:93.8%"
    local old_line = "1785683827794*1146@0#458:94%"
    local calls = {}

    MS.request = function(_, url, method, body)
        calls[#calls + 1] = { url = url, method = method, body = body }
        if method == "PUT" then return 201, "Created", nil, nil end
        return 200, "OK", new_line .. "\n", nil
    end

    shown = {}
    MS._do_push({ path = tmp, server = { type = "webdav" } }, {
        url = "https://dav/x.po", body = new_line, old_body = old_line,
        filename = "book.epub.po", section = 1146, hash = 458,
    })
    eq("先 PUT 再 GET", #calls, 2)
    eq("第一次是 PUT", calls[1].method, "PUT")
    eq("PUT 的正文就是新行", calls[1].body, new_line)
    eq("第二次是 GET(回读)", calls[2].method, "GET")
    check("回读一致时明确报成功",
          shown[#shown] ~= nil and shown[#shown].text:find("一致 ✓", 1, true) ~= nil,
          shown[#shown] and shown[#shown].text)
    check("报出了备份路径",
          shown[#shown] ~= nil and shown[#shown].text:find("备份：", 1, true) ~= nil)

    -- 服务器报错:必须说清楚"云端没被改动"
    MS.request = function()
        return 500, "Internal Server Error", nil, nil
    end
    shown = {}
    MS._do_push({ path = tmp, server = {} }, {
        url = "https://dav/x.po", body = new_line, old_body = old_line,
        filename = "book.epub.po", section = 1146, hash = 458,
    })
    check("服务器 500 要报失败", shown[#shown] ~= nil
          and shown[#shown].text:find("写入失败", 1, true) ~= nil)
    check("并说明云端未被改动", shown[#shown] ~= nil
          and shown[#shown].text:find("未被改动", 1, true) ~= nil)

    -- 传输层直接失败(返回 nil):也不能崩
    MS.request = function() return nil, nil, nil, "连接超时" end
    shown = {}
    MS._do_push({ path = tmp, server = {} }, {
        url = "https://dav/x.po", body = new_line, old_body = nil,
        filename = "book.epub.po", section = 1146, hash = 458,
    })
    check("传输失败要说清原因", shown[#shown] ~= nil
          and shown[#shown].text:find("连接超时", 1, true) ~= nil)
end

-- ── 顺手写回(上传进度时自动执行) ──────────────────────────────────────────
print("== 顺手写回:算得出与算不出 ==")
do
    local tmp = (os.getenv("TEMP") or "/tmp")
    local server = { type = "webdav", address = "https://dav", url = "Books",
                     username = "u", password = "p" }
    -- 假归档的第 1 章:标题「第一章」(3) + 两段(各 5)。
    -- 取第 2 个 <p> 的段内第 3 字 → 3 + 5 + 3 = 11
    local plugin = {
        path = tmp, server = server,
        ui = { document = {
            file = "fake.epub",
            getXPointer = function() return "/body/DocFragment[1]/body/p[2]/text().3" end,
            getTextFromXPointer = function() return "八九十" end,
        } },
    }

    local job, err, kind = MS.build_push_job(plugin)
    check("能算出写入内容", job ~= nil, err)
    if job then
        eq("章节序号(0 基)", job.section, 0)
        eq("章内偏移", job.hash, 11)
        eq("自检标记", job.checked, "已通过")
        -- 11 / 21(全书字数) = 52.38%
        eq("生成的整行", job.body, "1785683827794*0@0#11:52.4%")
        eq("目标 URL", job.url,
           "https://dav/Books/Apps/Books/.Moon+/Cache/fake.epub.po")
        eq("文件名沿用本机书名", job.filename, "fake.epub.po")
    end

    -- 停在标题上(xpointer 没有 p[])属于**正常偶发**,要归到 skip,不能弹错误
    local doc_h = {
        file = "fake.epub",
        getXPointer = function() return "/body/DocFragment[1]/body/h2/text().1" end,
        getTextFromXPointer = function() return "第一章" end,
    }
    local job_h, err_h, kind_h = MS.build_push_job({ path = tmp, server = server,
                                                     ui = { document = doc_h } })
    eq("标题上算不出内容", job_h, nil)
    eq("类别是 skip", kind_h, "skip")
    check("原因说得清", type(err_h) == "string" and err_h:find("段落", 1, true) ~= nil, err_h)

    -- 没有账号级常量:这是真问题,要归到 error
    local saved_ref = settings["inkbridge_moon_book_ref"]
    settings["inkbridge_moon_book_ref"] = nil
    local job_e, _, kind_e = MS.build_push_job(plugin)
    eq("没有常量时算不出", job_e, nil)
    eq("类别是 error", kind_e, "error")
    settings["inkbridge_moon_book_ref"] = saved_ref
end

print("== 顺手写回:开关与静默 ==")
do
    local tmp = (os.getenv("TEMP") or "/tmp")
    local server = { type = "webdav", address = "https://dav", url = "Books" }
    local plugin = {
        path = tmp, server = server,
        ui = { document = {
            file = "fake.epub",
            getXPointer = function() return "/body/DocFragment[1]/body/p[2]/text().3" end,
            getTextFromXPointer = function() return "八九十" end,
        } },
    }

    settings["inkbridge_moon_auto_push"] = nil
    eq("默认是开启", MS.auto_enabled(), true)
    MS.set_auto(false)
    eq("可以关掉", MS.auto_enabled(), false)
    eq("关掉后 auto_push 直接返回 nil", MS.auto_push(plugin), nil)
    MS.set_auto(true)

    -- 让 PUT/GET 自洽:GET 回读到的就是刚写下去的那一行
    local last_put
    MS.request = function(_, _, method, body)
        if method == "PUT" then last_put = body; return 201, "Created", nil, nil end
        return 200, "OK", last_put, nil
    end

    shown = {}
    local note = MS.auto_push(plugin)
    check("返回一句话结果", type(note) == "string"
          and note:find("已同步给静读天下", 1, true) ~= nil, note)
    eq("静默模式不额外弹窗(结果由上传提示一起显示)", #shown, 0)
    eq("写下去的确实是刚算出的那一行", last_put, "1785683827794*0@0#11:52.4%")

    -- 静默 ≠ 吞掉失败:失败必须能从返回值里读到
    -- 注意:这里替换的是**导出的模块函数**,用完必须还原 —— 否则后面所有用例
    -- 都会看到这个假的 500,是测试之间的串扰(不是产品行为)。
    MS.request = function() return 500, "err", nil, nil end
    shown = {}
    local job = MS.build_push_job(plugin)
    local ok_silent, brief = MS._do_push(plugin, job, { silent = true })
    eq("静默模式下失败不弹窗", #shown, 0)
    eq("但返回值说失败", ok_silent, false)
    check("并且给出可读原因", type(brief) == "string"
          and brief:find("写入失败", 1, true) ~= nil, brief)
    MS.request = REAL_REQUEST   -- 还原,别把假的 500 留给后面的用例

    -- skip 类别自动保持沉默
    local doc_h = {
        file = "fake.epub",
        getXPointer = function() return "/body/DocFragment[1]/body/h2/text().1" end,
    }
    shown = {}
    eq("skip 时返回 nil(连提示都不加)",
       MS.auto_push({ path = tmp, server = server, ui = { document = doc_h } }), nil)
    eq("skip 时确实没弹窗", #shown, 0)
end

-- ── 方向提示(导入确认框里那一句) ─────────────────────────────────────────
print("== 方向提示:远端比本机更早/更晚 ==")
do
    -- 真实数据:本机在第 167 章 #1806,静读天下回写到 #1802
    local remote = { section = 167, hash = 1802 }
    local earlier = MS.describe_direction(remote, { section = 167, hash = 1806 })
    check("同章更早:报出差值", type(earlier) == "string"
          and earlier:find("比本机早 4 字", 1, true) ~= nil, earlier)
    check("同章更早:说明会往回退", type(earlier) == "string"
          and earlier:find("会往回退", 1, true) ~= nil, earlier)
    check("提示要短(并进确认框第一行,不换行)", type(earlier) == "string"
          and #earlier < 40 and earlier:find("\n", 1, true) == nil, earlier)

    local later = MS.describe_direction(remote, { section = 167, hash = 1700 })
    check("同章更晚", type(later) == "string"
          and later:find("比本机晚 102 字", 1, true) ~= nil
          and later:find("是前进", 1, true) ~= nil, later)

    local same = MS.describe_direction(remote, { section = 167, hash = 1802 })
    check("完全相同要明说", type(same) == "string"
          and same:find("与本机位置相同", 1, true) ~= nil, same)

    local ch_early = MS.describe_direction({ section = 100, hash = 5 },
                                           { section = 167, hash = 1806 })
    check("跨章:更早", type(ch_early) == "string"
          and ch_early:find("在第 100 章，比本机更早", 1, true) ~= nil, ch_early)

    local ch_late = MS.describe_direction({ section = 200, hash = 5 },
                                          { section = 167, hash = 1806 })
    check("跨章:更晚", type(ch_late) == "string"
          and ch_late:find("在第 200 章，比本机更晚", 1, true) ~= nil, ch_late)

    eq("缺远端返回 nil", MS.describe_direction(nil, { section = 1, hash = 1 }), nil)
    eq("缺字段返回 nil", MS.describe_direction({}, { section = 1, hash = 1 }), nil)
    eq("缺本机返回 nil", MS.describe_direction(remote, nil), nil)
end

print("== 本机位置(方向提示的输入) ==")
do
    -- 假归档第 1 章:标题「第一章」(3 字) + 两段(各 5 字);
    -- 第 2 个 <p> 段内第 3 字 → 3 + 5 + 3 = 11
    local plugin = {
        ui = { document = {
            file = "fake.epub",
            getXPointer = function() return "/body/DocFragment[1]/body/p[2]/text().3" end,
        } },
    }
    local pos = MS.local_position(plugin)
    check("能算出本机位置", pos ~= nil)
    if pos then
        eq("  章节序号", pos.section, 0)
        eq("  章内偏移", pos.hash, 11)
    end
    eq("没开书时返回 nil", MS.local_position({ ui = {} }), nil)
    eq("取不到 xpointer 时返回 nil",
       MS.local_position({ ui = { document = { file = "fake.epub" } } }), nil)
    eq("xpointer 解析不出时返回 nil",
       MS.local_position({ ui = { document = { file = "fake.epub",
           getXPointer = function() return "没有 DocFragment" end } } }), nil)
end

print("== 下载列表里的静读天下一行 ==")
do
    eq("取不到数据时的文案", MS.peek_label(nil, 1000), "静读天下：无数据")
    eq("缺字段也当无数据", MS.peek_label({}, 1000), "静读天下：无数据")

    local t = MS.format_time(1000)
    check("format_time 是「月-日 时:分」",
          type(t) == "string" and t:match("^%d%d%-%d%d %d%d:%d%d$") ~= nil, t)
    eq("format_time(nil) 返回 nil", MS.format_time(nil), nil)

    local peek = { po = { star = 167, hash = 200, pct = 62.0 }, modified = 1000 }
    eq("绝对时间（相对时间）+ 百分比",
       MS.peek_label(peek, 1000 + 180),
       string.format("静读天下 · %s（3 分钟前） · 62.0%%", t))
    eq("有本机位置时再给方向",
       MS.peek_label(peek, nil, { section = 167, hash = 100 }),
       string.format("静读天下 · %s · 62.0%% · 比本机晚 100 字，是前进", t))
    eq("没有服务器时间就省掉那一段",
       MS.peek_label({ po = { star = 0, hash = 0, pct = 12.8 } }, 1000), "静读天下 · 12.8%")
end

-- ── 下载列表要的那"一眼":取 .po + 服务器时间 ──────────────────────────────
-- 这是**打开书时自动核对**和**下载列表**共用的取数口。它的失败全部要落到 nil,
-- 由调用方决定怎么显示;唯一不能做的是"拿半截数据去跳转"或"因为拿不到时间就
-- 把已经拿到的进度丢掉"。
print("== peek_po（取 .po 与它的服务器时间）==")
do
    MS.request = REAL_REQUEST   -- 兜底:前面的桩不许泄漏进来
    local SERVER = {
        type = "webdav", address = "https://dav.jianguoyun.com/dav",
        url = "/books", username = "u", password = "p",
    }
    -- 真机抓到的格式：T*spine@0#章内偏移:百分比%
    local PO_BODY = "1785683827794*167@0#200:62%"
    local BOOK_NAME = "死人经.epub.po"

    local called, got
    local function peek(plugin)
        called, got, last_request = false, nil, nil
        MS.peek_po(plugin, function(r) called, got = true, r end)
        return called, got
    end
    local function book_plugin()
        return { server = SERVER,
                 ui = { document = { file = "/mnt/onboard/书库/死人经.epub" } } }
    end
    local function reply(code, body)
        return function(req)
            if req.sink and body then req.sink(body) end
            return 1, code, {}, "HTTP/1.1 " .. tostring(code)
        end
    end

    list_folder_reply = { ok = true, items = {} }
    http_reply = reply(200, PO_BODY)

    -- ① 没开书 / 没配服务器 / 推不出书名:静默回调 nil,而且**一个请求都不发**
    local c, g = peek({ server = SERVER, ui = {} })
    eq("没开书也要回调(不能吊死调用方)", c, true)
    eq("  结果是 nil", g, nil)
    eq("  不发任何请求", last_request, nil)

    c, g = peek({ ui = { document = { file = "/x.epub" } } })
    eq("没配服务器:回调 nil", c, true)
    eq("  结果 nil", g, nil)
    eq("  也不发请求", last_request, nil)

    c, g = peek({ server = SERVER, ui = { document = { file = "/mnt/onboard/" } } })
    eq("书名推不出来:回调 nil", c, true)
    eq("  结果 nil", g, nil)
    eq("  仍然不发请求", last_request, nil)

    -- ② 请求没拿到正常正文:一律当"没数据"
    http_reply = reply(404, "not found")
    c, g = peek(book_plugin())
    eq("404 → 回调 nil", c, true)
    eq("  结果 nil", g, nil)

    http_reply = function(req) if req.sink then req.sink("") end return 1, 200, {}, "HTTP/1.1 200 OK" end
    c, g = peek(book_plugin())
    eq("200 但正文为空 → 回调 nil", c, true)
    eq("  结果 nil", g, nil)

    http_reply = reply(200, "<html>不是 .po</html>")
    c, g = peek(book_plugin())
    eq("正文不是 .po → 回调 nil", c, true)
    eq("  结果 nil", g, nil)

    http_reply = function() return false, "timeout" end
    c, g = peek(book_plugin())
    eq("网络断了 → 回调 nil", c, true)
    eq("  结果 nil", g, nil)

    -- ③ 成功路径:解析 + 文件名 + URL + 服务器时间
    http_reply = reply(200, PO_BODY)
    list_folder_calls = {}
    list_folder_reply = { ok = true, items = {
        { is_file = true, text = "别本.epub.po",   modification = 111 },
        { is_file = true, text = BOOK_NAME,        modification = 1700000000 },
    } }
    c, g = peek(book_plugin())
    eq("成功:回调有数据", c, true)
    check("  po 已解析", type(g) == "table" and type(g.po) == "table")
    eq("  spine 序号", g and g.po and g.po.star, 167)
    eq("  章内偏移", g and g.po and g.po.hash, 200)
    eq("  百分比", g and g.po and g.po.pct, 62)
    eq("  文件名是「书名.epub.po」", g and g.filename, BOOK_NAME)

    local esc = Moon.uri_escape(BOOK_NAME)
    check("  URL 指向同步目录里的这个文件",
          type(g) == "table" and type(g.url) == "string"
          and g.url:sub(-#esc) == esc, g and g.url)
    check("  URL 用的是配置里的静读天下目录",
          type(g) == "table" and type(g.url) == "string"
          and g.url:find("/books/Apps/Books/.Moon+/Cache/", 1, true) ~= nil, g and g.url)
    eq("  取时间只列了一次目录", #list_folder_calls, 1)
    eq("  列的就是那个目录", list_folder_calls[1], "/books/Apps/Books/.Moon+/Cache")

    local off = os.difftime(os.time(), os.time(os.date("!*t")))
    eq("  时间取服务器给的那个(补回本地时区偏移)",
       g and g.modified, 1700000000 + off)

    -- ④ 目录里没有这本书:拿不到时间,但**不能因此把进度丢掉**
    list_folder_reply = { ok = true, items = {
        { is_file = true, text = "别本.epub.po", modification = 111 },
    } }
    c, g = peek(book_plugin())
    eq("列表里没这本书:仍然回调", c, true)
    eq("  只是没有时间", g and g.modified, nil)
    check("  进度照样带出来", g and g.po and g.po.pct == 62)

    -- ⑤ 列目录整个失败(没网 / 权限):同上,只少一个时间
    list_folder_reply = { ok = false, items = nil, err = "boom" }
    c, g = peek(book_plugin())
    eq("列目录失败:仍然回调", c, true)
    eq("  时间也是 nil", g and g.modified, nil)
    check("  进度依旧在", g and g.po and g.po.star == 167)

    -- ⑥ 时间戳坏掉(字符串):不能算成数字,只能当没有
    list_folder_reply = { ok = true, items = {
        { is_file = true, text = BOOK_NAME, modification = "不是数字" },
    } }
    c, g = peek(book_plugin())
    eq("坏时间当没有", g and g.modified, nil)

    -- ⑦ GET 用的是 GET,而且带着账号(WebDAV 基本认证)
    http_reply = reply(200, PO_BODY)
    list_folder_reply = { ok = true, items = {} }
    peek(book_plugin())
    eq("  用 GET 取 .po", last_request and last_request.method, "GET")
    eq("  带上用户名", last_request and last_request.user, "u")
    eq("  GET 必须给 sink(否则正文收不到)",
       type(last_request and last_request.sink), "function")
end

-- ── 兼容平台 + 手动选进度文件 ─────────────────────────────────────────────
print("== 兼容平台(只有静读天下真能用) ==")
do
    settings["inkbridge_platform"] = nil
    eq("没设置过时用默认平台", MS.get_platform().id, "moon")
    eq("认不出的 id 也回落到默认", MS.platform("不存在的东西").id, "moon")
    eq("按 id 取得到", MS.platform("legado").name, "开源阅读（Legado）")

    eq("默认目录来自当前平台", MS.default_dir(), "Apps/Books/.Moon+/Cache")

    -- 待破译的平台:**只能识别空集**,绝不能退化成"全部认下"
    local legado = MS.platform("legado")
    eq("没破译的扩展名:不认 .po", MS.is_progress_file("x.epub.po", legado), false)
    eq("没破译的扩展名:也不认别的", MS.is_progress_file("随便什么", legado), false)

    -- 静读天下认 .po,大小写不敏感;其余一律不认
    local moon = MS.platform("moon")
    eq("认 .po", MS.is_progress_file("死人经.epub.po", moon), true)
    eq("认大写 .PO", MS.is_progress_file("BOOK.EPUB.PO", moon), true)
    eq("不认 .txt(那是墨桥自己的记录)", MS.is_progress_file("x.InkBridge.txt", moon), false)
    eq("不认书名里带 po 三字母的", MS.is_progress_file("po.epub", moon), false)
    eq("不认 epub 本体", MS.is_progress_file("死人经.epub", moon), false)
    eq("空名字不认", MS.is_progress_file("", moon), false)
    eq("nil 不认", MS.is_progress_file(nil, moon), false)
    eq("没有扩展名的空串不认", MS.is_progress_file("abc", { ext = "" }), false)

    -- 切平台必须连带换目录:留着上一家的目录会让新平台去读旧平台的文件夹
    MS.set_dir("我自己改过的目录")
    eq("先确认目录确实被改过", MS.get_dir(), "我自己改过的目录")
    MS.set_platform("moon")
    eq("切到静读天下:目录回到它自己的默认值", MS.get_dir(), "Apps/Books/.Moon+/Cache")
    eq("平台设置已保存", settings["inkbridge_platform"], "moon")
    settings["inkbridge_platform"] = nil
end

print("== 手动选进度文件(自己列目录,不用 KOReader 的文件选择器) ==")
do
    local SERVER2 = { type = "webdav", address = "https://dav.example.com/dav",
                      url = "/books", username = "u", password = "p" }
    settings["inkbridge_platform"] = nil

    -- ① 没配服务器 / 格式没破译:明确说原因,不是默默给个空列表
    local got_files, got_err
    MS.list_progress_files({ server = { type = "dropbox" }, ui = {} },
                           function(f, e) got_files, got_err = f, e end)
    eq("没配 WebDAV:拿不到列表", got_files, nil)
    check("并说明原因", type(got_err) == "string" and got_err:find("WebDAV", 1, true) ~= nil, got_err)

    settings["inkbridge_platform"] = "legado"
    MS.list_progress_files({ server = SERVER2, ui = {} },
                           function(f, e) got_files, got_err = f, e end)
    eq("格式没破译:拿不到列表", got_files, nil)
    check("并说明是没破译",
          type(got_err) == "string" and got_err:find("破译", 1, true) ~= nil, got_err)
    settings["inkbridge_platform"] = nil
    MS.set_platform("moon")

    -- ② 只挑出 .po,别的文件一律不算(目录里很可能还躺着墨桥自己的记录)
    list_folder_calls = {}
    list_folder_reply = { ok = true, items = {
        { is_file = true, text = "死人经.epub.po",       modification = 100 },
        { is_file = true, text = "墨桥记录.InkBridge.txt", modification = 900 },
        { is_file = true, text = "别的书.epub.po",        modification = 300 },
        { is_file = true, text = "封面.jpg",              modification = 500 },
        { is_file = false, text = "子目录" },
    } }
    got_files, got_err = nil, nil
    MS.list_progress_files({ server = SERVER2, ui = {} },
                           function(f, e) got_files, got_err = f, e end)
    check("拿到了列表", type(got_files) == "table")
    eq("只留两个 .po", type(got_files) == "table" and #got_files or -1, 2)
    eq("按时间从新到旧排", got_files and got_files[1] and got_files[1].name, "别的书.epub.po")
    eq("  次新的排第二", got_files and got_files[2] and got_files[2].name, "死人经.epub.po")
    eq("列的是配置里的目录", list_folder_calls[1], "/books/Apps/Books/.Moon+/Cache")
    eq("没有错误", got_err, nil)

    -- 时间坏掉时:不炸,只当没有时间(排序退化成按名字)
    list_folder_reply = { ok = true, items = {
        { is_file = true, text = "b.epub.po", modification = "坏" },
        { is_file = true, text = "a.epub.po", modification = nil },
    } }
    MS.list_progress_files({ server = SERVER2, ui = {} },
                           function(f) got_files = f end)
    eq("坏时间的排在后面也要有名字可比", got_files and got_files[1] and got_files[1].name, "a.epub.po")

    -- ③ 列目录失败:如实报错,不能变成"这个目录是空的"
    list_folder_reply = { ok = false, items = nil, err = "boom" }
    MS.list_progress_files({ server = SERVER2, ui = {} },
                           function(f, e) got_files, got_err = f, e end)
    eq("列目录失败:拿不到列表", got_files, nil)
    check("带上原始原因", type(got_err) == "string" and got_err:find("boom", 1, true) ~= nil, got_err)

    -- ④ 弹出来的列表必须:每份 .po 一个按钮 + **永远**留一条手动输入 + 取消
    list_folder_reply = { ok = true, items = {
        { is_file = true, text = "死人经.epub.po", modification = 1700000000 },
        { is_file = true, text = "别本.epub.po",   modification = 100 },
    } }
    last_buttondialog = nil
    local picked
    MS.pick_po({ server = SERVER2, ui = {} }, function(n) picked = n end)
    check("弹出了选择框", last_buttondialog ~= nil)
    local labels = {}
    for _, row in ipairs(last_buttondialog and last_buttondialog.buttons or {}) do
        labels[#labels + 1] = row[1] and row[1].text
    end
    eq("按钮数 = 两个文件 + 手动输入 + 取消", #labels, 4)
    check("第一项是那份 .po(带时间)",
          type(labels[1]) == "string" and labels[1]:find("死人经.epub.po", 1, true) ~= nil
          and labels[1]:find(MS.format_time(1700000000), 1, true) ~= nil, labels[1])
    eq("倒数第二项是手动输入", labels[3], "手动输入文件名…")
    eq("最后一项是取消", labels[4], "取消")

    -- 点第一项 → 回调文件名(不是内容、不是 URL)
    last_buttondialog.buttons[1][1].callback()
    eq("选中的文件名回调出来", picked, "死人经.epub.po")

    -- ⑤ 目录里一个 .po 都没有:仍然要弹出(否则手动输入这条路就没了),
    --    并且要把"为什么是空的"说清楚
    list_folder_reply = { ok = true, items = {} }
    last_buttondialog, shown = nil, {}
    MS.pick_po({ server = SERVER2, ui = {} }, function() end)
    check("空目录也弹出选择框", last_buttondialog ~= nil)
    eq("只剩两条出路", #(last_buttondialog and last_buttondialog.buttons or {}), 2)
    eq("一条是手动输入", last_buttondialog.buttons[1][1].text, "手动输入文件名…")
    check("并且解释了目录为什么是空的",
          #shown > 0 and type(shown[#shown].text) == "string"
          and shown[#shown].text:find("没有 .po 文件", 1, true) ~= nil,
          #shown > 0 and shown[#shown].text or "没有弹任何东西")

    -- ⑥ 手动输入:默认值给自动推出来的那个名字(用户多半只需改几个字)
    local plugin_v = { server = SERVER2,
                       ui = { document = { file = "/mnt/onboard/书库/死人经.epub" } } }
    last_inputdialog = nil
    MS._ask_po_name(plugin_v, function() end)
    check("弹出了输入框", last_inputdialog ~= nil)
    eq("默认值 = 本机文件名 + .po", last_inputdialog and last_inputdialog.input, "死人经.epub.po")

    -- ⑦ import_named 必须把文件名一路传到请求上(否则"手动选"等于没选)
    http_reply = function(req)
        if req.sink then req.sink("1785683827794*167@0#200:62%") end
        return 1, 200, {}, "HTTP/1.1 200 OK"
    end
    list_folder_reply = { ok = true, items = {} }
    last_request = nil
    local want_name = "云端那份不一样的名字.epub.po"
    local want_esc  = Moon.uri_escape(want_name)
    MS.import_named(plugin_v, want_name)
    check("请求发的是手动选中的那个名字(按 URL 规则转义)",
          last_request ~= nil and type(last_request.url) == "string"
          and last_request.url:sub(-#want_esc) == want_esc,
          last_request and last_request.url)
    last_request = nil
    MS.import_named(plugin_v, "")
    eq("空名字不发请求", last_request, nil)

    -- ⑧ 只读元数据:整个流程里一次 PUT/DELETE 都不能有
    --    (列目录是 PROPFIND,由 provider 统一发;这里能验的是"没有写动作")
    last_request = nil
    MS.import_named(plugin_v, "x.epub.po")
    eq("取进度文件只用 GET", last_request and last_request.method, "GET")
end

print(string.format("\n合计：%d 通过，%d 失败", passed, failed))
os.exit(failed == 0 and 0 or 1)
