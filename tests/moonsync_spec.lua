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
-- 真正的 inkbridge_webdav 会拉进一大堆 KOReader 模块,这里只用它做跳转,桩掉即可
package.preload["inkbridge_webdav"] = function() return {} end

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

-- ── 模块加载 ───────────────────────────────────────────────────────────────
print("== 模块加载与导出 ==")
do
    check("moonsync 能加载(语法/依赖)", type(MS) == "table")
    for _, name in ipairs({ "get_dir", "set_dir", "fetch_po", "section_html", "section_blocks",
                            "section_blocks_tagged", "book_metrics", "get_book_ref",
                            "learn_book_ref", "request", "backup_po", "import_from_moon",
                            "push_to_moon", "_do_push", "build_push_job", "auto_push",
                            "auto_enabled", "set_auto" }) do
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
    MS.request = function() return 500, "err", nil, nil end
    shown = {}
    local job = MS.build_push_job(plugin)
    local ok_silent, brief = MS._do_push(plugin, job, { silent = true })
    eq("静默模式下失败不弹窗", #shown, 0)
    eq("但返回值说失败", ok_silent, false)
    check("并且给出可读原因", type(brief) == "string"
          and brief:find("写入失败", 1, true) ~= nil, brief)

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

print(string.format("\n合计：%d 通过，%d 失败", passed, failed))
os.exit(failed == 0 and 0 or 1)
