-- ============================================================================
-- tests/webdav_spec.lua — InkBridge 云存储层回归测试
--
-- 目的：把「下载/上传/列目录」三条链路的控制流锁死，避免再出现
--       “改完只能靠肉眼复核、上机才发现必崩” 的情况。
--
-- 运行： luajit tests/webdav_spec.lua
--        (在仓库根目录执行；Windows 上需先把 luajit 放进 PATH 或写全路径)
--
-- 设计说明：
--   * KOReader 的界面/网络模块全部用 package.preload 打桩，测试不需要设备。
--   * rapidjson 被替换成返回固定表的桩：这里验证的是**控制流与校验逻辑**，
--     而不是 KOReader 自带的 JSON 实现（那是上游的职责）。
--   * 真实 WebDAV provider 的调用约定（run(cb) 同步调用、downloadFile 返回
--     HTTP 码、listFolder(url, include_folders)）按 koreader-master 的
--     plugins/cloudstorage.koplugin/providers/webdav.lua 复刻。
-- ============================================================================

-- ── 0. 定位插件目录 ─────────────────────────────────────────────────────
dofile("tests/material_business_stub.lua")
local script_path = arg and arg[0] or "tests/webdav_spec.lua"
local script_dir  = script_path:match("^(.*)[/\\][^/\\]*$") or "."
local PLUGIN_DIR  = script_dir .. "/../inkbridge.koplugin"
package.path = PLUGIN_DIR .. "/?.lua;" .. package.path

-- ── 1. 打桩 KOReader 依赖 ───────────────────────────────────────────────
local json_result   -- 由每个用例设置：rapidjson.decode 返回什么

package.preload["ui/uimanager"] = function()
    return {
        show     = function() end,
        close    = function() end,
        nextTick = function(fn) fn() end,
    }
end
package.preload["ui/widget/infomessage"] = function()
    -- 同样记下最后一条提示：自动跳转只靠提示告知用户「差几行」。
    return { new = function(_, o) _last_message = o and o.text or nil; return o or {} end }
end
-- ConfirmBox 的桩顺手记下最后一次的构造参数：确认框文案（尤其是「首行对不齐」那一行）
-- 是用户唯一能看见的说明，必须锁定，不能只靠肉眼。
_last_confirm = nil
package.preload["ui/widget/confirmbox"] = function()
    return { new = function(_, o) _last_confirm = o; return o or {} end }
end
package.preload["ui/widget/buttondialog"] = function() return { new = function(_, o) return o or {} end } end
package.preload["ui/event"]              = function() return { new = function(_, n, a) return { name = n, arg = a } end } end
package.preload["rapidjson"] = function()
    return {
        encode = function() return "{}" end,
        decode = function() return json_result end,
    }
end
package.preload["util"] = function()
    return {
        -- 浅拷贝即可暴露「是否引用了同一个表」
        tableDeepCopy = function(t)
            local copy = {}
            for k, v in pairs(t or {}) do copy[k] = v end
            return copy
        end,
    }
end
_G.G_reader_settings = {
    -- data 是 LuaSettings 真正存放设置的地方,provider 的 isTrue("show_unsupported")
    -- 读的就是它。列目录要临时改这里的 show_unsupported,所以测试也照这个形状造。
    data         = {},
    isTrue       = function(self, k) return self.data[k] == true end,
    readSetting  = function(self, k) return self.data[k] end,
    saveSetting  = function(self, k, v) self.data[k] = v end,
    delSetting   = function(self, k) self.data[k] = nil end,
}

local WebDAV = dofile(PLUGIN_DIR .. "/inkbridge_webdav.lua")

-- ── 2. 极简断言框架 ─────────────────────────────────────────────────────
local passed, failed = 0, 0
local current_case = "?"

local function case(name) current_case = name end

local function check(label, cond, detail)
    if cond then
        passed = passed + 1
        print(string.format("    PASS  %s", label))
    else
        failed = failed + 1
        print(string.format("    FAIL  %s%s", label, detail and ("  -> " .. tostring(detail)) or ""))
    end
end

local function eq(label, got, want)
    check(label, got == want, string.format("得到 %s，期望 %s", tostring(got), tostring(want)))
end

-- ── 3. 测试夹具 ─────────────────────────────────────────────────────────

local BOOK_ID = "deadbeefcafe1234deadbeefcafe1234"   -- 模拟 partialMD5
local PREFIX  = BOOK_ID:sub(1, 8)                     -- "deadbeef"

local function new_server()
    return {
        name     = "测试网盘",
        type     = "webdav",
        address  = "https://dav.example.com/remote.php/dav",
        username = "user",
        password = "secret",
        url      = "/books",
    }
end

--- 造一个假的 provider + plugin。opts 控制各接口的行为。
local function make_env(opts)
    opts = opts or {}
    local calls = {}

    local provider = {}
    provider.run = function(cb)
        calls.run = (calls.run or 0) + 1
        return cb()
    end
    provider.downloadFile = function(url, local_path, progress_cb)
        calls.download_url = url
        calls.download_local = local_path
        -- 真实 provider 会把响应体写入 local_path（即使 404 也会留下文件），
        -- 所以这里也照做，否则“临时文件已清理”会变成一条空断言。
        local f = io.open(local_path, "w")
        if f then
            f:write(opts.download_body or "{}")
            f:close()
            calls.download_wrote = true
        end
        return opts.download_code or 200
    end
    provider.uploadFile = function(url, local_path, etag)
        calls.upload_url = url
        calls.upload_local = local_path
        calls.base_during_upload = provider.base   -- 用于验证 base 的副本/恢复行为
        return opts.upload_code or 200
    end
    provider.listFolder = function(url, include_folders)
        calls.list_url = url
        calls.list_include_folders = include_folders
        calls.base_during_list = provider.base   -- 验证 base 的副本/恢复行为
        return opts.listing
    end
    provider.deleteFile = function(url)
        calls.deleted = calls.deleted or {}
        calls.deleted[#calls.deleted + 1] = url
        calls.base_during_delete = provider.base
        if opts.delete_ok ~= nil then return opts.delete_ok end
        return true
    end

    local manager = { providers = { webdav = provider } }
    if opts.manager_upload_cb then
        manager.uploadFile = function(_, server, path, ok_cb, err_cb)
            calls.manager_upload_args = { server = server, path = path }
            opts.manager_upload_cb(ok_cb, err_cb)
        end
    end

    local plugin = {
        server = opts.server ~= nil and opts.server or new_server(),
        ui = { cloudstorage = manager },
        -- 本地临时名刻意用 ASCII：LuaJIT 在 Windows 上通过 ANSI 代码页打开文件，
        -- 含中文的本地路径会报 "Illegal byte sequence"，这属于测试环境的限制
        -- （设备端是 Linux/UTF-8，不受影响）。远端名仍含中文并原样传给 provider，
        -- 那才是本用例真正要覆盖的部分。
        _download_staging_path = function(self, remote_name)
            return "spec-download.tmp"
        end,
    }
    return plugin, provider, calls
end

--- 同步调用一个异步风格的接口，把回调结果收进表里
local function invoke(fn)
    local result = {}
    fn(function(...) result = { ... }; result.n = select("#", ...) end)
    return result
end

-- ============================================================================
print("== 1. is_safe_remote_path（远端路径校验）==")
-- ============================================================================
-- 历史背景：这里曾用 find("[\\\r\n\0]", 1)，而该模式里含 NUL 字节，
-- 会被 Lua 判为 malformed pattern 直接抛错，导致下载功能必然失败。
case("路径校验")
do
    local v = WebDAV._is_safe_remote_path
    local safe_cases = {
        { "正常中文全名", "/books/死人经-0615日30分45秒-汉王C7T8147.d31f852b.InkBridge.txt" },
        { "旧版相对名",   "inkbridge-progress-a1b2c3d4e5f6.json" },
        { "带空格",       "/books/my book.InkBridge.txt" },
        { "单斜杠开头",   "/a.txt" },
    }
    for _, c in ipairs(safe_cases) do
        check("接受：" .. c[1], v(c[2]) == true)
    end
    local unsafe_cases = {
        { "反斜杠",   "books\\evil.txt" },
        { "回车",     "books\rname.txt" },
        { "换行",     "books\nname.txt" },
        { "NUL",      "books\0name.txt" },
        { "TAB",      "books\tname.txt" },
        { "DEL",      "books\127name.txt" },
        { "双点穿越", "../etc/passwd" },
        { "中段双点", "books/../../etc/passwd" },
        { "协议头",   "http://evil/x" },
        { "空串",     "" },
        { "纯双点",   ".." },
    }
    for _, c in ipairs(unsafe_cases) do
        check("拒绝：" .. c[1], v(c[2]) == false)
    end
    check("拒绝 nil", v(nil) == false)
    check("拒绝数字", v(123) == false)
end

-- ============================================================================
print("== 2. download()（只读下载）==")
-- ============================================================================
case("下载成功")
do
    local plugin, provider, calls = make_env({ download_code = 200 })
    json_result = {
        schema_version = 1,
        book_id = BOOK_ID,
        percent = 0.47,
        xpointer = "/body/DocFragment[2]/body/div/p[7]",
        book_name = "死人经",
    }
    local r = invoke(function(cb)
        WebDAV.download(plugin, "/books/死人经-0615日30分45秒-汉王C7T8147.deadbeef.InkBridge.txt", cb)
    end)
    eq("回调第 1 个参数为 true", r[1], true)
    check("回调带回记录", type(r[2]) == "table")
    eq("记录 book_id 正确", r[2] and r[2].book_id, BOOK_ID)
    eq("第 3 个参数为 nil", r[3], nil)
    eq("传给 provider 的 URL 原样透传", calls.download_url, "/books/死人经-0615日30分45秒-汉王C7T8147.deadbeef.InkBridge.txt")
    check("provider 确实写了临时文件", calls.download_wrote == true)
    check("临时文件已清理", io.open("spec-download.tmp", "r") == nil)
end

case("下载 404")
do
    local plugin = make_env({ download_code = 404 })
    local r = invoke(function(cb)
        WebDAV.download(plugin, "/books/nothere.txt", cb)
    end)
    eq("回调 true", r[1], true)
    eq("记录为 nil", r[2], nil)
    eq("错误标记为 missing", r[3], "missing")
end

case("下载遇到非法路径")
do
    local plugin, provider, calls = make_env({ download_code = 200 })
    local r = invoke(function(cb)
        WebDAV.download(plugin, "books\\evil.txt", cb)
    end)
    eq("回调 false", r[1], false)
    eq("错误信息正确", r[3], "invalid remote path")
    eq("未触碰 provider.run", calls.run, nil)
    eq("未发起下载", calls.download_url, nil)
end

case("未配置 WebDAV 目标")
do
    local plugin = make_env({ server = {} })
    local r = invoke(function(cb)
        WebDAV.download(plugin, "/books/a.txt", cb)
    end)
    eq("回调 false", r[1], false)
    eq("提示未配置", r[3], "WebDAV destination is not configured")
end

-- ============================================================================
print("== 3. list_history()（历史记录筛选与排序）==")
-- ============================================================================
case("筛选与排序")
do
    local listing = {
        { is_file = true,  text = "死人经-0615日30分45秒-汉王C7T8147." .. PREFIX .. ".InkBridge.txt", modification = 300 },
        { is_file = true,  text = "无关书-0101日00分00秒-KOReader9999.cafebabe.InkBridge.txt",          modification = 999 },
        { is_file = true,  text = "InkBridge-" .. PREFIX .. "-20260101.txt",                            modification = 100 },
        { is_file = true,  text = "随便一个文件.txt",                                                   modification = 500 },
        { is_file = false, text = "某个目录/" },
        { is_file = true,  text = "书-0101日00分00秒-KOReader1234." .. PREFIX .. ".InkBridge.txt",       modification = 200 },
    }
    local plugin, provider, calls = make_env({ listing = listing })
    local r = invoke(function(cb) WebDAV.list_history(plugin, PREFIX, cb) end)
    eq("回调 true", r[1], true)
    local entries = r[2] or {}
    eq("命中条数（过滤掉异书/无关文件/目录）", #entries, 3)
    eq("第 1 条按时间最新", entries[1] and entries[1].modification, 300)
    eq("第 2 条", entries[2] and entries[2].modification, 200)
    eq("第 3 条（旧格式记录也保留）", entries[3] and entries[3].modification, 100)
    eq("listFolder 收到 server.url", calls.list_url, "/books")
    eq("listFolder 必须带 include_folders=true（否则 modification 为空）", calls.list_include_folders, true)
end

case("listFolder 返回 nil 不能当成空列表")
do
    local plugin = make_env({ listing = nil })
    local r = invoke(function(cb) WebDAV.list_history(plugin, PREFIX, cb) end)
    eq("回调 false", r[1], false)
    eq("错误信息", r[3], "WebDAV list failed")
end

-- ============================================================================
print("== 4. upload()（上传）==")
-- ============================================================================
case("未配置 WebDAV 目标")
do
    local plugin = make_env({ server = {} })
    local r = invoke(function(cb) WebDAV.upload(plugin, "nonexistent.spec-upload", cb) end)
    eq("回调 false", r[1], false)
    eq("提示未配置", r[2], "WebDAV destination is not configured")
end

case("本地文件不存在")
do
    local plugin = make_env({})
    local r = invoke(function(cb) WebDAV.upload(plugin, "nonexistent.spec-upload", cb) end)
    eq("回调 false", r[1], false)
    eq("提示本地文件缺失", r[2], "local upload file is missing")
end

case("经由 Cloud:uploadFile 主路径")
do
    local staged = "staged.spec-upload"
    local f = io.open(staged, "w"); f:write("{}"); f:close()
    local plugin, provider, calls = make_env({
        manager_upload_cb = function(ok_cb) ok_cb() end,
    })
    local r = invoke(function(cb) WebDAV.upload(plugin, staged, cb) end)
    eq("回调 true", r[1], true)
    check("确实调用了 manager:uploadFile", calls.manager_upload_args ~= nil)
    eq("透传的 server 就是插件保存的那份", calls.manager_upload_args and calls.manager_upload_args.server, plugin.server)
    eq("透传的路径正确", calls.manager_upload_args and calls.manager_upload_args.path, staged)
    os.remove(staged)
end

case("退回 provider.uploadFile 兼容路径")
do
    local staged = "staged.spec-upload"
    local f = io.open(staged, "w"); f:write("{}"); f:close()
    local plugin, provider, calls = make_env({ upload_code = 200 })
    local r = invoke(function(cb) WebDAV.upload(plugin, staged, cb) end)
    eq("回调 true", r[1], true)
    eq("上传 URL 用 server.url", calls.upload_url, "/books")
    check("上传期间 provider.base 已设置", calls.base_during_upload ~= nil)
    check("base 是副本而非插件设置表本身（防止回写设置）", calls.base_during_upload ~= plugin.server)
    eq("base 内容正确", calls.base_during_upload and calls.base_during_upload.address, "https://dav.example.com/remote.php/dav")
    check("上传完成后 base 已恢复原值", provider.base == nil)
    os.remove(staged)
end

case("兼容路径：上传失败要报错")
do
    local staged = "staged.spec-upload"
    local f = io.open(staged, "w"); f:write("{}"); f:close()
    local plugin = make_env({ upload_code = 500 })
    local r = invoke(function(cb) WebDAV.upload(plugin, staged, cb) end)
    eq("回调 false", r[1], false)
    check("错误信息含 HTTP 码", type(r[2]) == "string" and r[2]:find("500", 1, true) ~= nil, r[2])
    os.remove(staged)
end

-- ============================================================================
print("== 5. _plan_jump（跳转方式分级）==")
-- ============================================================================
-- 背景：记录里的 percent 来自 ReaderFooter:getBookProgress() = pageno/pages，
-- 是“页序占本机总页数的比例”，依赖排版（两台设备可能 8922 页 vs 8689 页）。
-- 所以跳转必须优先使用与排版无关的锚点：xpointer -> 文本锚点 -> 页数比例。
local XP_OK  = "/body/DocFragment[305]/body/div/p[67]/text().0"
local XP_BAD = "/body/DocFragment[901]/body/div/p[1]/text().0"
local ANCHOR = "顾慎为很清楚这些刀客的热情能持续多久"
local calls  = {}

local function plan_doc(opts)
    opts = opts or {}
    calls = {}
    return {
        info = { has_pages = opts.has_pages or false, doc_height = 100000 },
        isXPointerInDocument = function(_, xp)
            calls.validated = xp
            return opts.xpointer_ok or false
        end,
        findAllText = function(_, pattern, ci, ctx, max_hits)
            calls.search = { pattern = pattern, ci = ci, max_hits = max_hits }
            return opts.hits
        end,
        getPosFromXPointer = function(_, xp)
            if opts.positions and opts.positions[xp] then return opts.positions[xp] end
            if xp == "hit-far" then return 10000 end
            return 90000
        end,
        clearSelection = function() calls.cleared = true end,
        getPageCount = function() calls.page_count = true; return 8689 end,
        -- 首行核对 / 落点核算用到的接口：默认**不存在**，由用例按需打开，
        -- 这样第 5 节的既有用例行为完全不变。
        configurable = opts.configurable or {},
        getTextFromXPointer = opts.text_at and function(_, xp)
            calls.text_at = xp
            return opts.text_at[xp]
        end or nil,
        getPageFromXPointer = opts.page_from and function(_, xp)
            calls.page_from = xp
            return opts.page_from[xp]
        end or nil,
        getPageXPointer = opts.page_top and function(_, page)
            calls.page_top = page
            return opts.page_top[page]
        end or nil,
        compareXPointers = opts.compare or nil,
    }
end

local function plan_ui(doc, rolling)
    if rolling == "none" then return { document = doc } end
    return { document = doc, rolling = rolling or { getLastProgress = function() end } }
end

do
    local old_http, old_socketutil = package.loaded["socket.http"], package.loaded["socketutil"]
    local util = require("util")
    local old_encode = util.urlEncode
    util.urlEncode = function(path) return path end
    local status, request_count, request_seen = "204", 0, nil
    package.loaded["socket.http"] = { request = function(request)
        request_count = request_count + 1
        request_seen = request
        return 1, status
    end }
    package.loaded["socketutil"] = {
        FILE_BLOCK_TIMEOUT = 1, FILE_TOTAL_TIMEOUT = 2,
        set_timeout = function() end, reset_timeout = function() end,
    }
    local p, _, calls = make_env{ listing = {} }
    p.server.address = "https://dav.example/base"
    local function conditional(etag)
        return invoke(function(cb) WebDAV.delete_file(p, "/books/one.txt", cb, etag) end)
    end
    local r = conditional('"version-1"')
    eq("If-Match 条件删除成功", r[1], true)
    eq("条件请求携带强 ETag", request_seen.headers["If-Match"], '"version-1"')
    eq("条件删除 URL 保持目标服务器", request_seen.url, "https://dav.example/base/books/one.txt")
    status = "412"
    r = conditional('"version-1"')
    eq("云端版本变化时拒绝条件删除", r[1], false)
    local before = request_count
    r = conditional('W/"weak"')
    eq("弱 ETag 删除被拒绝", r[1], false)
    eq("弱 ETag 不发网络请求", request_count, before)
    eq("条件删除不使用无条件 provider 删除", calls.deleted, nil)
    package.loaded["socket.http"], package.loaded["socketutil"] = old_http, old_socketutil
    util.urlEncode = old_encode
end

do
    local doc = plan_doc({ xpointer_ok = true })
    local plan = WebDAV._plan_jump({ ui = plan_ui(doc) }, { xpointer = XP_OK, percent = 0.249 })
    eq("xpointer 可解析时优先用它", plan and plan.method, "xpointer")
    eq("plan 带回 xpointer", plan and plan.xpointer, XP_OK)
    eq("不触发全文搜索", calls.search, nil)
end

do
    -- xpointer 失效（跨设备最常见）-> 文本锚点；多个命中时用 pos_percent 消歧
    local doc = plan_doc({
        xpointer_ok = false,
        hits = {
            { start = "hit-far",  ["end"] = "e1" },   -- 内容位置 10000
            { start = "hit-near", ["end"] = "e2" },   -- 内容位置 90000
        },
    })
    local plan = WebDAV._plan_jump({ ui = plan_ui(doc) }, {
        xpointer = XP_BAD, text_anchor = ANCHOR, pos_percent = 0.9, percent = 0.249,
    })
    eq("xpointer 失效时降级到文本锚点", plan and plan.method, "text")
    eq("多命中时取最接近 pos_percent 的", plan and plan.xpointer, "hit-near")
    eq("带回命中总数", plan and plan.hits, 2)
    check("搜索参数正确（锚点/忽略大小写/限 8 条）",
        calls.search and calls.search.pattern == ANCHOR
        and calls.search.ci == true and calls.search.max_hits == 8,
        calls.search and (calls.search.pattern .. "/" .. tostring(calls.search.ci) .. "/" .. tostring(calls.search.max_hits)))
    check("搜索顺带产生的高亮已清理", calls.cleared == true)
end

do
    -- Moon+ 导入不相信 DocFragment/百分比：全文必须唯一命中才允许跳转。
    local doc = plan_doc({ xpointer_ok = false,
        hits = { { start = "unique-whole-book-hit", ["end"] = "e1" } },
    })
    local plan = WebDAV._plan_jump({ ui = plan_ui(doc) }, {
        text_anchor = ANCHOR, require_unique_text = true,
        fragment = 999, pos_percent = 0.01, percent = 0.9,
    })
    eq("唯一命中采用全文搜索位置", plan and plan.xpointer, "unique-whole-book-hit")
    eq("唯一命中标记", plan and plan.unique_text, true)
    eq("唯一模式不受 fragment 限定", calls.search and calls.search.pattern, ANCHOR)
    check("唯一模式清除搜索高亮", calls.cleared == true)
    eq("唯一模式不调用页数比例兜底", calls.page_count, nil)
end

do
    local doc = plan_doc({ xpointer_ok = false,
        hits = {
            { start = "duplicate-one", ["end"] = "e1" },
            { start = "duplicate-two", ["end"] = "e2" },
        },
    })
    local plan, reason = WebDAV._plan_jump({ ui = plan_ui(doc) }, {
        text_anchor = ANCHOR, require_unique_text = true, percent = 0.9,
    })
    eq("重复命中时不猜位置", plan, nil)
    eq("重复命中错误码", reason, "moon_anchor_ambiguous")
    eq("重复命中不回退页数比例", calls.page_count, nil)
    check("重复命中清除搜索高亮", calls.cleared == true)
end

do
    local doc = plan_doc({ xpointer_ok = false, hits = {} })
    local plan, reason = WebDAV._plan_jump({ ui = plan_ui(doc) }, {
        text_anchor = ANCHOR, require_unique_text = true, percent = 0.9,
    })
    eq("零命中时不跳转", plan, nil)
    eq("零命中错误码", reason, "moon_anchor_not_found")
    eq("零命中不回退页数比例", calls.page_count, nil)
end

do
    local doc = plan_doc({ xpointer_ok = false,
        hits = { { start = "unique-hit", ["end"] = "e1" } },
    })
    doc.findAllText = nil
    local plan, reason = WebDAV._plan_jump({ ui = plan_ui(doc) }, {
        text_anchor = ANCHOR, require_unique_text = true, percent = 0.9,
    })
    eq("全文搜索接口缺失时不跳", plan, nil)
    eq("缺接口错误码", reason, "moon_anchor_search_failed")
end

do
    -- 有锚点但搜不到 -> 继续降级到页数比例
    local doc = plan_doc({ xpointer_ok = false, hits = {} })
    local plan = WebDAV._plan_jump({ ui = plan_ui(doc) }, {
        xpointer = XP_BAD, text_anchor = ANCHOR, pos_percent = 0.249,
        percent = 0.24904729881192558,
    })
    eq("搜不到则退回页数比例", plan and plan.method, "percent")
    -- 用户实测：在 8689 页的设备上，0.2490473 * 8689 向下取整 + 1 = 2164
    eq("页码 = floor(percent * 本机总页数) + 1", plan and plan.page, 2164)
end

do
    -- 旧记录没有锚点字段，应安静降级而不是报错
    local doc = plan_doc({ xpointer_ok = false })
    local plan = WebDAV._plan_jump({ ui = plan_ui(doc) }, { percent = 0.5 })
    eq("旧记录降级为页数比例", plan and plan.method, "percent")
    eq("页码正确", plan and plan.page, math.floor(0.5 * 8689) + 1)
end

do
    -- 固定版式（PDF/CBZ）：页码由内容决定，直接用远端页码
    local doc = plan_doc({ has_pages = true })
    local plan = WebDAV._plan_jump({ ui = plan_ui(doc, "none") }, { page = 12, percent = 0.5 })
    eq("固定版式用页码", plan and plan.method, "page")
    eq("页码取记录里的值", plan and plan.page, 12)
end

do
    -- 固定版式但没有页码 -> 退回页数比例
    local doc = plan_doc({ has_pages = true })
    local plan = WebDAV._plan_jump({ ui = plan_ui(doc, "none") }, { percent = 0.5 })
    eq("无页码时退回页数比例", plan and plan.method, "percent")
end

do
    local plan, reason = WebDAV._plan_jump({ ui = {} }, { percent = 0.5 })
    eq("没有文档时返回 nil", plan, nil)
    eq("原因说明", reason, "no_document")
end

do
    local plan, reason = WebDAV._plan_jump({ ui = plan_ui(plan_doc({})) }, {})
    eq("完全没有位置信息时返回 nil", plan, nil)
    eq("原因说明", reason, "no_position")
end

-- ============================================================================
print("== 5b. 首行文字核对 与 落点核算（分页模式的「首行对齐」）==")
-- ============================================================================
-- 用户要求「不同设备上第一行内容要一样」。分页模式在绘制上就是一整页一整页画的
-- （ReaderView:drawPageView -> drawCurrentViewByPage -> gotoPage），屏幕顶端永远
-- 只可能是本机某一页的第一行，所以插件能保证的是：
--   1) 定位用**首行文字**，并且用它对 xpointer 做交叉校验（xpointer 可能「解析成功
--      却指到别处」，第三方分支的 DocFragment 切分不同就会这样）；
--   2) 落点取「包含远端那一行的那一页」；
--   3) 把「远端那一行在本页第几行」算出来如实告诉用户，不假装对齐。
do
    -- xpointer 解析成功，且该处文字与记录里的首行文字一致 -> 就用 xpointer
    local doc = plan_doc({ xpointer_ok = true, text_at = { [XP_OK] = ANCHOR } })
    local plan = WebDAV._plan_jump({ ui = plan_ui(doc) }, { xpointer = XP_OK, text_anchor = ANCHOR })
    eq("文字核对通过 -> 仍用 xpointer", plan and plan.method, "xpointer")
    eq("核对时读的是这个 xpointer 处的文字", calls.text_at, XP_OK)
    eq("没有多此一举去搜索", calls.search, nil)
    check("没有标记 mismatch", plan and plan.xpointer_mismatch == nil)
end

do
    -- xpointer 解析成功，但文字对不上（第三方分支指错了地方）-> 改用首行文字搜索
    local doc = plan_doc({
        xpointer_ok = true,
        text_at = { [XP_OK] = "这完全是另外一段正文，和远端首行对不上" },
        hits = { { start = "hit-near", ["end"] = "e1" } },
    })
    local plan = WebDAV._plan_jump({ ui = plan_ui(doc) }, {
        xpointer = XP_OK, text_anchor = ANCHOR, pos_percent = 0.9,
    })
    eq("xpointer 指到别处 -> 降级到首行文字", plan and plan.method, "text")
    eq("落点用搜索命中的位置", plan and plan.xpointer, "hit-near")
    eq("标记 mismatch（确认框要据此说明）", plan and plan.xpointer_mismatch, true)
    eq("搜索用的就是记录里的首行文字", calls.search and calls.search.pattern, ANCHOR)
end

do
    -- 旧记录没有 text_anchor：无从核对，不能因此把好好的 xpointer 丢掉
    local doc = plan_doc({ xpointer_ok = true })
    local plan = WebDAV._plan_jump({ ui = plan_ui(doc) }, { xpointer = XP_OK })
    eq("没有首行文字时仍用 xpointer", plan and plan.method, "xpointer")
    check("不误报 mismatch", plan and plan.xpointer_mismatch == nil)
end

do
    -- 本机取不到该处文字（接口返回 nil）时同样不推翻 xpointer
    local doc = plan_doc({ xpointer_ok = true, text_at = {} })
    local plan = WebDAV._plan_jump({ ui = plan_ui(doc) }, { xpointer = XP_OK, text_anchor = ANCHOR })
    eq("取不到文字时不降级", plan and plan.method, "xpointer")
end

do
    -- 落点核算：远端那一行在本页第 3 行（页首与该行相差 2 个行高）
    -- 行高按 KOReader 自己的式子算：font_size(10) × 1.1 × line_spacing(100)% = 11
    local doc = plan_doc({
        xpointer_ok = true,
        text_at = { [XP_OK] = ANCHOR },
        page_from = { [XP_OK] = 3 },
        page_top = { [3] = "page-top-3" },
        positions = { [XP_OK] = 90022, ["page-top-3"] = 90000 },
        configurable = { font_size = 10, line_spacing = 100 },
    })
    local plan = WebDAV._plan_jump({ ui = plan_ui(doc) }, { xpointer = XP_OK, text_anchor = ANCHOR })
    eq("落点页", plan and plan.page, 3)
    eq("页首 xpointer 一并带回", plan and plan.page_top, "page-top-3")
    eq("远端那一行在本页第 3 行", plan and plan.line_number, 3)
    eq("首行对不齐（第 3 行 != 页首）", plan and plan.first_line_same, false)
end

do
    -- 新版行框 API 按实际绘制行计数，不能把段落间距算成正文行。
    -- 目标页临时切换后必须恢复文档原页。
    local current_page, visited = 9, {}
    local doc = plan_doc({
        xpointer_ok = true,
        text_at = { [XP_OK] = ANCHOR },
        page_from = { [XP_OK] = 3 },
        page_top = { [3] = "page-top-boxes" },
        positions = { [XP_OK] = 90022, ["page-top-boxes"] = 90000 },
        configurable = { font_size = 10, line_spacing = 100 },
    })
    doc.getCurrentPage = function() return current_page end
    doc.gotoPage = function(_, page)
        current_page = page
        visited[#visited + 1] = page
    end
    doc.getScreenPositionFromXPointer = function(_, xp)
        return xp == "page-top-boxes" and 0 or 30, xp == "page-top-boxes" and 0 or 5
    end
    doc.getTextFromPositions = function(_, pos0, pos1, no_selection)
        check("行框查询发生在目标页", current_page == 3, tostring(current_page))
        check("按屏幕位置查询文本范围", pos0.y == 0 and pos1.y == 30 and no_selection)
        return { sboxes = { { y = 0 }, { y = 10 }, { y = 10 }, { y = 20 }, { y = 30 } } }
    end
    local plan = WebDAV._plan_jump({ ui = plan_ui(doc) }, { xpointer = XP_OK, text_anchor = ANCHOR })
    eq("行框计数忽略同一行的多个文字片段", plan and plan.line_number, 4)
    eq("行框计数恢复原页面", current_page, 9)
    eq("按需切到目标页再切回", table.concat(visited, ","), "3,9")

    current_page, visited = 3, {}
    plan = WebDAV._plan_jump({ ui = plan_ui(doc) }, { xpointer = XP_OK, text_anchor = ANCHOR })
    eq("已在目标页仍能核算实际行号", plan and plan.line_number, 4)
    eq("已在目标页不做多余跳页", #visited, 0)

    doc.getTextFromPositions = function()
        return { sboxes = {
            { y = 0, h = 10 }, { y = 2, h = 10 },
            { y = 14, h = 10 }, { y = 15, h = 10 },
        } }
    end
    plan = WebDAV._plan_jump({ ui = plan_ui(doc) }, { xpointer = XP_OK, text_anchor = ANCHOR })
    eq("同一视觉行的文字片段 y 不同仍合并", plan and plan.line_number, 2)

    current_page, visited = 9, {}
    doc.getTextFromPositions = function() error("render failed") end
    plan = WebDAV._plan_jump({ ui = plan_ui(doc) }, { xpointer = XP_OK, text_anchor = ANCHOR })
    eq("行框接口异常不影响正文定位方案", plan and plan.method, "xpointer")
    eq("行框接口异常也恢复原页", current_page, 9)
    eq("行框接口异常不退回公式猜行号", plan and plan.line_number, nil)

    doc.getTextFromPositions = function() return { sboxes = {} } end
    plan = WebDAV._plan_jump({ ui = plan_ui(doc) }, { xpointer = XP_OK, text_anchor = ANCHOR })
    eq("行框为空不编行号", plan and plan.line_number, nil)
    eq("行框为空仍恢复原页", current_page, 9)

    doc.gotoPage = function(_, page)
        current_page = page
        if page == 3 then error("target page failed after moving") end
    end
    plan = WebDAV._plan_jump({ ui = plan_ui(doc) }, { xpointer = XP_OK, text_anchor = ANCHOR })
    eq("切目标页抛错也恢复原页", current_page, 9)
    eq("切页异常不编行号", plan and plan.line_number, nil)
end

do
    -- 页首就是远端那一行 -> 首行完全对齐
    local doc = plan_doc({
        xpointer_ok = true,
        text_at = { [XP_OK] = ANCHOR },
        page_from = { [XP_OK] = 7 },
        page_top = { [7] = "page-top-same" },
        positions = { [XP_OK] = 90000, ["page-top-same"] = 90000 },
        configurable = { font_size = 10, line_spacing = 100 },
    })
    local plan = WebDAV._plan_jump({ ui = plan_ui(doc) }, { xpointer = XP_OK, text_anchor = ANCHOR })
    eq("首行对齐标记", plan and plan.first_line_same, true)
    eq("行号是第 1 行", plan and plan.line_number, 1)
end

do
    -- 半个行高以内算同一行（xpointer 写法不同不该误报「对不齐」）
    local doc = plan_doc({
        xpointer_ok = true,
        text_at = { [XP_OK] = ANCHOR },
        page_from = { [XP_OK] = 7 },
        page_top = { [7] = "page-top-same" },
        positions = { [XP_OK] = 90005, ["page-top-same"] = 90000 },
        configurable = { font_size = 10, line_spacing = 100 },
    })
    local plan = WebDAV._plan_jump({ ui = plan_ui(doc) }, { xpointer = XP_OK, text_anchor = ANCHOR })
    eq("差 5px（不足半行）仍算首行对齐", plan and plan.line_number, 1)
end

do
    -- 没有字体设置 -> 报不出行号，但不能编数字
    local doc = plan_doc({
        xpointer_ok = true,
        text_at = { [XP_OK] = ANCHOR },
        page_from = { [XP_OK] = 7 },
        page_top = { [7] = "page-top-x" },
        positions = { [XP_OK] = 90050, ["page-top-x"] = 90000 },
    })
    local plan = WebDAV._plan_jump({ ui = plan_ui(doc) }, { xpointer = XP_OK, text_anchor = ANCHOR })
    eq("算不出行号时字段为 nil", plan and plan.line_number, nil)
    eq("也不声称对齐/不对齐", plan and plan.first_line_same, nil)
end

do
    -- 没有字体设置时退回比较 xpointer 本身
    local doc = plan_doc({
        xpointer_ok = true,
        text_at = { [XP_OK] = ANCHOR },
        page_from = { [XP_OK] = 7 },
        page_top = { [7] = "page-top-x" },
        compare = function(_, a, b) return a == b and 0 or -1 end,
    })
    local plan = WebDAV._plan_jump({ ui = plan_ui(doc) }, { xpointer = XP_OK, text_anchor = ANCHOR })
    eq("不同点 -> 判定为对不齐", plan and plan.first_line_same, false)
    eq("比较不出来行号", plan and plan.line_number, nil)

    local doc2 = plan_doc({
        xpointer_ok = true,
        text_at = { [XP_OK] = ANCHOR },
        page_from = { [XP_OK] = 7 },
        page_top = { [7] = XP_OK },
        compare = function(_, a, b) return a == b and 0 or -1 end,
    })
    local plan2 = WebDAV._plan_jump({ ui = plan_ui(doc2) }, { xpointer = XP_OK, text_anchor = ANCHOR })
    eq("同一点 -> 首行对齐", plan2 and plan2.first_line_same, true)
    eq("同一点时行号是 1", plan2 and plan2.line_number, 1)
end

do
    -- 落点核算的所有接口都可能不存在（老版本 KOReader / 极简构建）：不许报错
    local doc = plan_doc({ xpointer_ok = true, text_at = { [XP_OK] = ANCHOR } })
    local plan = WebDAV._plan_jump({ ui = plan_ui(doc) }, { xpointer = XP_OK, text_anchor = ANCHOR })
    eq("缺接口时照常给出 xpointer 方案", plan and plan.method, "xpointer")
    eq("没有可核算的落点信息", plan and plan.page, nil)
    eq("不声称对齐", plan and plan.first_line_same, nil)
end

do
    -- _line_height：没有 device 模块时用未缩放的皮尺（保证测试与设备口径一致）
    package.loaded["device"] = nil
    package.preload["device"] = nil
    local h = WebDAV._line_height({ configurable = { font_size = 18, line_spacing = 130 } })
    check("按 font_size × 1.1 × line_spacing% 估算", math.abs((h or 0) - 18 * 1.1 * 1.3) < 1e-6,
        tostring(h))
    eq("没有 font_size 就报 nil（不猜）", WebDAV._line_height({ configurable = {} }), nil)
    eq("不是表也安全", WebDAV._line_height(nil), nil)

    -- device.screen.scaleBySize 存在时按设备缩放（KOReader 在设备上就是这样）
    package.loaded["device"] = nil
    package.preload["device"] = function()
        return { screen = { scaleBySize = function(_, v) return v * 2 end } }
    end
    local scaled = WebDAV._line_height({ configurable = { font_size = 18, line_spacing = 130 } })
    check("用设备缩放", math.abs((scaled or 0) - 2 * 18 * 1.1 * 1.3) < 1e-6, tostring(scaled))
    package.loaded["device"] = nil
    package.preload["device"] = nil
end

do
    -- 滚动模式:GotoXPointer 走 _gotoPos 把目标行放到视野顶部,首行天然对齐,
    -- 此时绝不能按「落点页」核算并误报「首行对不齐」(滚动模式没有页这回事)
    local doc = plan_doc({
        xpointer_ok = true,
        text_at = { [XP_OK] = ANCHOR },
        page_from = { [XP_OK] = 3 },
        page_top = { [3] = "page-top-3" },
        positions = { [XP_OK] = 90022, ["page-top-3"] = 90000 },
        configurable = { font_size = 10, line_spacing = 100 },
    })
    local ui = plan_ui(doc)
    ui.view = { view_mode = "scroll" }
    local plan = WebDAV._plan_jump({ ui = ui }, { xpointer = XP_OK, text_anchor = ANCHOR })
    eq("滚动模式仍用 xpointer", plan and plan.method, "xpointer")
    eq("滚动模式不算落点页", plan and plan.page, nil)
    eq("不声称对齐/不对齐", plan and plan.first_line_same, nil)
    eq("不带行号", plan and plan.line_number, nil)

    ui.handleEvent = function() end
    _last_confirm = nil
    WebDAV.confirm_jump({ ui = ui }, { xpointer = XP_OK, text_anchor = ANCHOR, percent = 0.25 })
    check("滚动模式确认框不误报「首行对不齐」",
        _last_confirm and (_last_confirm.text or ""):find("首行对不齐", 1, true) == nil,
        _last_confirm and _last_confirm.text)
end

-- ── 确认框文案：对齐时不加行；对不齐必须说清楚 ─────────────────────────────
do
    local function jump_ui(doc)
        local events = {}
        return {
            document = doc,
            rolling = { getLastProgress = function() end },
            handleEvent = function(_, ev) events[#events + 1] = ev end,
        }, events
    end

    local doc = plan_doc({
        xpointer_ok = true,
        text_at = { [XP_OK] = ANCHOR },
        page_from = { [XP_OK] = 3 },
        page_top = { [3] = "page-top-3" },
        positions = { [XP_OK] = 90000, ["page-top-3"] = 90000 },
        configurable = { font_size = 10, line_spacing = 100 },
    })
    local ui, events = jump_ui(doc)
    _last_confirm = nil
    WebDAV.confirm_jump({ ui = ui }, { xpointer = XP_OK, text_anchor = ANCHOR, percent = 0.25 })
    check("弹出了确认框", _last_confirm ~= nil)
    local text = _last_confirm and _last_confirm.text or ""
    check("首行对齐时不加「对不齐」那一行", text:find("首行对不齐", 1, true) == nil, text)
    check("照旧说明远端进度", text:find("远端阅读位置", 1, true) ~= nil, text)
    _last_confirm.ok_callback()
    eq("点跳转发的是 xpointer 事件", events[1] and events[1].name, "GotoXPointer")
    eq("事件里带上位置", events[1] and events[1].arg, XP_OK)
end

do
    local doc = plan_doc({
        xpointer_ok = true,
        text_at = { [XP_OK] = ANCHOR },
        page_from = { [XP_OK] = 3 },
        page_top = { [3] = "page-top-3" },
        positions = { [XP_OK] = 90022, ["page-top-3"] = 90000 },
        configurable = { font_size = 10, line_spacing = 100 },
    })
    local ui = plan_ui(doc)
    ui.handleEvent = function() end
    _last_confirm = nil
    WebDAV.confirm_jump({ ui = ui }, { xpointer = XP_OK, text_anchor = ANCHOR, percent = 0.25 })
    local text = _last_confirm and _last_confirm.text or ""
    check("对不齐时如实写出第几行",
        text:find("首行对不齐：远端那一行在本页第 3 行", 1, true) ~= nil, text)
end

do
    -- 自动跳转（already_confirmed，例如「打开书时自动核对」）也必须报出差几行
    local doc = plan_doc({
        xpointer_ok = true,
        text_at = { [XP_OK] = ANCHOR },
        page_from = { [XP_OK] = 3 },
        page_top = { [3] = "page-top-3" },
        positions = { [XP_OK] = 90022, ["page-top-3"] = 90000 },
        configurable = { font_size = 10, line_spacing = 100 },
    })
    local ui = plan_ui(doc)
    ui.handleEvent = function() end
    _last_message = nil
    _last_confirm = nil
    WebDAV.confirm_jump({ ui = ui }, { xpointer = XP_OK, text_anchor = ANCHOR, percent = 0.25 },
        { already_confirmed = true })
    eq("自动跳转不再弹确认框", _last_confirm, nil)
    check("自动跳转也说明差几行",
        type(_last_message) == "string" and _last_message:find("本页第 3 行", 1, true) ~= nil,
        tostring(_last_message))
end

do
    -- 对不齐但算不出行号(缺字体设置)时,自动跳转也必须说一句,不能静默退回
    local doc = plan_doc({
        xpointer_ok = true,
        text_at = { [XP_OK] = ANCHOR },
        page_from = { [XP_OK] = 3 },
        page_top = { [3] = "page-top-x" },
        compare = function(_, a, b) return a == b and 0 or -1 end,
    })
    local ui = plan_ui(doc)
    ui.handleEvent = function() end
    _last_message = nil
    WebDAV.confirm_jump({ ui = ui }, { xpointer = XP_OK, text_anchor = ANCHOR, percent = 0.25 },
        { already_confirmed = true })
    check("算不出行号时自动跳转仍说明首行对不齐",
        type(_last_message) == "string" and _last_message:find("首行对不齐", 1, true) ~= nil,
        tostring(_last_message))
end

do
    -- xpointer 指到别处时，确认框要说明「忽略它、改用首行文字」（这是可诊断性的一半）
    local doc = plan_doc({
        xpointer_ok = true,
        text_at = { [XP_OK] = "这完全是另外一段正文，和远端首行对不上" },
        hits = { { start = "hit-near", ["end"] = "e1" } },
        page_from = { [XP_OK] = 3, ["hit-near"] = 4 },
        page_top = { [4] = "page-top-4" },
        positions = { ["hit-near"] = 90000, ["page-top-4"] = 90000 },
        configurable = { font_size = 10, line_spacing = 100 },
    })
    local ui = plan_ui(doc)
    ui.handleEvent = function() end
    _last_confirm = nil
    WebDAV.confirm_jump({ ui = ui }, { xpointer = XP_OK, text_anchor = ANCHOR, percent = 0.25 })
    local text = _last_confirm and _last_confirm.text or ""
    check("说明 xpointer 指到别处", text:find("指到别处", 1, true) ~= nil, text)
    check("仍然会跳（不是拒绝）", text:find("跳转过去吗？", 1, true) ~= nil, text)
end


-- ============================================================================
print("== 6. describe_error（内部错误码 → 用户看得懂的中文）==")
-- ============================================================================
-- 回调里返回的仍是稳定的英文错误码（上面几节都依赖它们），
-- 只在显示给用户时才翻译。这一层保证不会再出现
-- “下载失败：remote_record_invalid_json” 这种把内部串甩到用户脸上的情况。
do
    eq("已知错误码", WebDAV.describe_error("invalid remote path"),
        "云端返回的文件名不合法，已拒绝")
    eq("未配置目标", WebDAV.describe_error("WebDAV destination is not configured"),
        "还没有设置 WebDAV 目标（菜单 → 设置 WebDAV 目标）")
    eq("嵌套错误码会被拆开翻译", WebDAV.describe_error("remote_record_invalid_json"),
        "远端记录无法解析：记录不是合法的 JSON")
    eq("跳转规划的原因也翻译", WebDAV.describe_error("no_document"), "当前没有打开的文档")
    eq("静读天下零命中有安全提示", WebDAV.describe_error("moon_anchor_not_found"),
       "正文片段在本书中未找到，为避免错跳已停止")
    eq("静读天下重复命中有安全提示", WebDAV.describe_error("moon_anchor_ambiguous"),
       "正文片段在本书中重复出现，无法唯一确认，为避免错跳已停止")
    eq("静读天下搜索失败有说明", WebDAV.describe_error("moon_anchor_search_failed"),
       "本机全文搜索未能完成")
    check("HTTP 403 指明下载失败",
        WebDAV.describe_error("WebDAV download failed: HTTP 403"):find("下载失败", 1, true) ~= nil)
    check("HTTP 403 附带权限提示",
        WebDAV.describe_error("WebDAV download failed: HTTP 403"):find("权限", 1, true) ~= nil)
    check("HTTP 401 提示认证问题",
        WebDAV.describe_error("WebDAV upload failed: HTTP 401"):find("认证失败", 1, true) ~= nil)
    check("HTTP 码保留在文案里",
        WebDAV.describe_error("WebDAV upload failed: HTTP 507"):find("507", 1, true) ~= nil)
    eq("未知错误原样返回（不吞信息）", WebDAV.describe_error("something weird"), "something weird")
    eq("nil 安全", WebDAV.describe_error(nil), "未知错误")
end

-- ============================================================================
print("== 7. 全文搜索期间的输入防护 ==")
-- ============================================================================
-- 搜索跑在 UI 线程上，大书要一两秒；不吞输入的话用户连点会造成动作重复。
-- 用一个可控的 device 桩验证真的调用了 setIgnoreInput。
do
    local toggles = {}
    package.loaded["device"] = nil
    package.preload["device"] = function()
        return { setIgnoreInput = function(_, value) toggles[#toggles + 1] = value end }
    end
    local doc = plan_doc({
        xpointer_ok = false,
        hits = { { start = "hit-near", ["end"] = "e1" } },
    })
    local plan = WebDAV._plan_jump({ ui = plan_ui(doc) }, {
        xpointer = XP_BAD, text_anchor = ANCHOR, pos_percent = 0.9, percent = 0.249,
    })
    eq("仍然完成规划", plan and plan.method, "text")
    eq("搜索前后各调用一次", #toggles, 2)
    eq("先吞输入", toggles[1], true)
    eq("后恢复输入", toggles[2], false)
end

do
    -- 搜索抛异常时也必须恢复，否则用户之后再也点不动界面
    local toggles = {}
    -- require 会缓存成功加载的模块：不清掉的话这里拿到的是上一个用例的桩，
    -- 计数就会计到别的表上（这个坑实际踩过一次）。
    package.loaded["device"] = nil
    package.preload["device"] = function()
        return { setIgnoreInput = function(_, value) toggles[#toggles + 1] = value end }
    end
    local doc = plan_doc({ xpointer_ok = false, hits = {} })
    doc.findAllText = function() error("boom") end
    local plan = WebDAV._plan_jump({ ui = plan_ui(doc) }, {
        xpointer = XP_BAD, text_anchor = ANCHOR, percent = 0.249,
    })
    eq("搜索失败则降级", plan and plan.method, "percent")
    eq("异常路径也恢复输入", #toggles, 2)
    eq("恢复值为 false", toggles[2], false)
end

do
    -- 没有 device 模块时（极简构建/测试环境）不能报错，应安静跳过防护
    package.preload["device"] = nil
    package.loaded["device"] = nil
    local doc = plan_doc({ xpointer_ok = false, hits = { { start = "hit-near", ["end"] = "e" } } })
    local ok, plan = pcall(WebDAV._plan_jump, { ui = plan_ui(doc) }, {
        xpointer = XP_BAD, text_anchor = ANCHOR, percent = 0.249,
    })
    check("没有 device 模块也不报错", ok)
    check("仍然完成规划", ok and plan ~= nil and plan.method == "text")
end

-- ── 「只配了一台服务器就直接进目录」的捷径 ───────────────────────────────
-- 这条捷径必须**只赢不输**:只有恰恰好一台服务器时才接管,
-- 其余任何情况(零台/两台/没有云存储/内部抛异常)都要安静退回原来的流程。
print("== 单服务器捷径:存储路径自适应 ==")
do
    local function fake_manager(servers)
        return {
            servers = servers,
            loaded  = false,
            opened  = nil,
            loadSettings = function(self) self.loaded = true end,
            openCloudServer = function(self, url, cb, do_show)
                self.opened = { url = url, cb = cb, do_show = do_show }
            end,
        }
    end

    -- 恰好一台:接管,并直接打开它的目录浏览
    local m = fake_manager({ { name = "坚果云", url = "https://dav/" } })
    local saved
    local handled = WebDAV.start_dir_pick_on_single_server(
        { ui = { cloudstorage = m } }, function(s) saved = s end)
    check("一台服务器时接管", handled == true)
    check("先刷新过服务器列表", m.loaded == true)
    eq("直接打开那台服务器", m.opened and m.opened.url, "https://dav/")
    eq("按下标 1 初始化", m.server_idx, 1)
    check("回调走字段、不走参数（异步时序下传参会丢）",
          m.opened and m.opened.cb == nil
          and type(m.caller_choose_folder_callback) == "function")

    -- 触发它自己的回调:要转交给调用方,并且**立刻把自己清掉**
    m.caller_choose_folder_callback({ name = "坚果云", url = "https://dav/" })
    eq("回调转交成功", saved and saved.url, "https://dav/")
    eq("用完立刻清掉（免得以后从文件管理器长按目录时误触发）",
       m.caller_choose_folder_callback, nil)

    -- 两台:不接管,交给原来的"列服务器"流程
    local m2 = fake_manager({ { url = "a" }, { url = "b" } })
    eq("两台服务器时不接管",
       WebDAV.start_dir_pick_on_single_server({ ui = { cloudstorage = m2 } },
                                              function() end), false)
    eq("而且什么都没打开", m2.opened, nil)

    -- 零台:也不接管 —— 用户还需要那个列表来新建服务器
    local m3 = fake_manager({})
    eq("没有服务器时不接管",
       WebDAV.start_dir_pick_on_single_server({ ui = { cloudstorage = m3 } },
                                              function() end), false)

    -- 没有云存储 manager / plugin 为空:不接管、也不报错
    eq("没有云存储时不接管",
       WebDAV.start_dir_pick_on_single_server({ ui = {} }, function() end), false)
    eq("plugin 为空也不报错",
       WebDAV.start_dir_pick_on_single_server(nil, function() end), false)

    -- 内部抛异常:必须吃掉异常并返回 false(捷径不能变成故障点)
    local m4 = fake_manager({ { url = "https://dav/" } })
    m4.openCloudServer = function() error("boom") end
    eq("openCloudServer 抛异常时返回 false",
       WebDAV.start_dir_pick_on_single_server({ ui = { cloudstorage = m4 } },
                                              function() end), false)
end

-- ── 借 KOReader 的云浏览器选一个目录(静读天下同步目录) ────────────────────
-- ★ 这一节钉的是一个**真实踩过的坑**:现行 KOReader 把 **Cloud 插件**注册为
--   `ui.cloudstorage`,而 `openCloudServer` / `loadSettings` 是 CloudStorage 对象上的方法
--   —— Cloud 插件没有它们。所以照抄上面那条"单服务器捷径"的内部实现,会因为它
--   `is_callable(manager.openCloudServer)` 恒为 false 而**永远静默失败**:
--   表现就是"点进去又变成输入框",没有任何报错。通用入口只有
--   `Cloud:onShowCloudStorageList(cb)`(KOReader 自己的 exporter/statistics 也这么调它)。
print("== pick_folder（借云浏览器选目录）==")
do
    -- Cloud 插件形状的假对象:**有** onShowCloudStorageList,**没有** openCloudServer
    local function fake_cloud()
        return {
            shown_cb = nil,
            shown = 0,
            onShowCloudStorageList = function(self, cb)
                self.shown_cb = cb
                self.shown = self.shown + 1
            end,
        }
    end
    local CHOSEN = { name = "坚果云", type = "webdav", address = "https://dav.example.com/dav",
                     username = "u", password = "p",
                     url = "我的同步/墨桥/Apps/Books/.Moon+/Cache" }

    -- ① 参数 / 环境不对:一律安静返回 false(调用方据此退回手动输入)
    eq("没给回调 → false", WebDAV.pick_folder({ ui = { cloudstorage = fake_cloud() } }, nil), false)
    eq("plugin 为空 → false", WebDAV.pick_folder(nil, function() end), false)
    eq("没有云存储 → false", WebDAV.pick_folder({ ui = {} }, function() end), false)
    eq("云存储里没有那个入口 → false",
       WebDAV.pick_folder({ ui = { cloudstorage = {} } }, function() end), false)

    -- ② ★ 真机上那条路:交给 onShowCloudStorageList,并把**我们的回调**原样交出去
    local cloud = fake_cloud()
    local got, calls = nil, 0
    local cb = function(c) got = c; calls = calls + 1 end
    eq("接管了", WebDAV.pick_folder({ ui = { cloudstorage = cloud } }, cb), true)
    eq("只调了一次 KOReader 的入口", cloud.shown, 1)
    eq("交出去的正是我们的回调", cloud.shown_cb, cb)

    -- ③ 用户在浏览器里长按确认之后:选中的那一层原样转交给调用方
    cloud.shown_cb(CHOSEN)
    eq("选中结果交到调用方手里", got, CHOSEN)
    eq("只转交一次", calls, 1)

    -- ④ 没有「墨桥同步目录」也要能用:选目录只依赖云存储功能,不依赖目标 ——
    --    那种情况下 apply_dir_choice 会按"从服务器根算起"存绝对路径(见 moonsync_spec)。
    local cloud2 = fake_cloud()
    eq("没有目标也接管",
       WebDAV.pick_folder({ server = nil, ui = { cloudstorage = cloud2 } }, function() end), true)
    eq("  并且照样调了 KOReader 的入口", cloud2.shown, 1)

    -- ⑤ 只读:它不许改 plugin.server(改目标的是另一条路,不是这里)
    local SAVED = { name = "坚果云", type = "webdav", address = "https://dav.example.com/dav",
                    username = "u", password = "p", url = "我的同步/墨桥" }
    local plugin = { server = SAVED, ui = { cloudstorage = fake_cloud() } }
    local before = plugin.server.url
    WebDAV.pick_folder(plugin, function() end)
    eq("不碰已保存的目标", plugin.server.url, before)

    -- ⑥ 老 API(ui.cloudstorage 就是 CloudStorage 的年代):仍然优先走那条捷径,
    --    不会去调 onShowCloudStorageList —— 保留它是为了老版本,不能反过来变成新故障。
    local legacy = {
        servers = { { name = "坚果云", address = "https://dav.example.com/dav",
                      username = "u", url = "我的同步/墨桥" } },
        opened = nil,
        shown = 0,
        loadSettings = function() end,
        openCloudServer = function(self, url) self.opened = url end,
        onShowCloudStorageList = function(self) self.shown = self.shown + 1 end,
    }
    eq("老 API 上仍然接管",
       WebDAV.pick_folder({ server = SAVED, ui = { cloudstorage = legacy } }, function() end), true)
    eq("  走的是捷径(打开了那台服务器的起点)", legacy.opened, "我的同步/墨桥")
    eq("  没有再去调通用入口", legacy.shown, 0)
end

-- ── 「远端有没有比我新」的判定(服务器时钟,没有跨设备时钟偏差) ──────────
print("== 远端新旧判定 ==")
do
    local cands = {
        { source = "kpw6",  time = 1000 },
        { source = "c7t",   time = 900  },
        { source = "phone", time = 800  },
    }

    -- 本机从没同步过这个来源 → 不打扰(第一次请用手动下载)
    eq("完全没有 seen 时不报更新", #WebDAV.select_updates(cands, {}), 0)

    local up = WebDAV.select_updates(cands, { kpw6 = 990, c7t = 950, phone = 800 })
    eq("只挑出真正更新的那个", #up, 1)
    eq("挑中的是 kpw6", up[1] and up[1].source, "kpw6")

    up = WebDAV.select_updates(cands, { kpw6 = 990, c7t = 800, phone = 800 })
    eq("两个更新", #up, 2)
    eq("新的排前面", up[1] and up[1].source, "kpw6")
    eq("旧的排后面", up[2] and up[2].source, "c7t")

    eq("时间相同不算更新(避免来回震荡)",
       #WebDAV.select_updates({ { source = "a", time = 100 } }, { a = 100 }), 0)
    eq("时间倒退更不算",
       #WebDAV.select_updates({ { source = "a", time = 99 } }, { a = 100 }), 0)

    eq("空候选不报错", #WebDAV.select_updates(nil, { a = 1 }), 0)
    eq("坏时间要跳过", #WebDAV.select_updates({ { source = "a", time = "x" } }, { a = 1 }), 0)
    eq("没有 source 要跳过", #WebDAV.select_updates({ { time = 999 } }, { [""] = 1 }), 0)

    -- 时间说人话
    eq("刚刚", WebDAV.human_age(5), "刚刚")
    eq("分钟", WebDAV.human_age(180), "3 分钟前")
    eq("小时", WebDAV.human_age(3600 * 2), "2 小时前")
    eq("天", WebDAV.human_age(86400 * 3), "3 天前")
    eq("负数当未知", WebDAV.human_age(-1), "未知")
    eq("nil 当未知", WebDAV.human_age(nil), "未知")
end

-- ── 列任意目录(静读天下的 .po 不在历史记录里,得单独列它那个目录) ──────────
-- 这一条路的输出会被直接拿去**显示给用户看的时间**,错了会误导;而且它的失败
-- 与"目录里就是没有这本书"必须分得清,否则会把同步故障伪装成"静读天下没这本"。
print("== list_folder（列任意目录，只读元数据）==")
do
    local function call(plugin, folder)
        return invoke(function(cb) WebDAV.list_folder(plugin, folder, cb) end)
    end

    -- ① 目标不是 WebDAV:直接失败,连 provider 都不碰
    local r = call({ server = { type = "dropbox" }, ui = {} }, "/x")
    eq("非 WebDAV 目标 → 失败", r[1], false)
    check("  并说明原因",
          type(r[3]) == "string" and r[3]:find("not configured", 1, true) ~= nil, r[3])

    -- ② KOReader 里没有 webdav provider(云存储插件缺失/被裁剪)
    r = call({ server = new_server(), ui = { cloudstorage = { providers = {} } } }, "/x")
    eq("provider 缺失 → 失败", r[1], false)
    check("  并说明原因",
          type(r[3]) == "string" and r[3]:find("unavailable", 1, true) ~= nil, r[3])

    -- ③ 正常:目录项丢掉(调用方要的是文件),路径与 include_folders 原样传下去
    local plugin, provider, calls = make_env{ listing = {
        { is_file = true,  text = "死人经.epub.po", modification = 1700000000 },
        { is_file = false, text = "子目录" },
        { is_file = true,  text = "另一本.epub.po" },
        { text = "没有 is_file 的捣乱项" },
    } }
    r = call(plugin, "/books/Apps/Books/.Moon+/Cache")
    eq("正常列目录 → 成功", r[1], true)
    eq("  只留文件项", #r[2], 2)
    eq("  顺序保持服务器给的顺序", r[2] and r[2][1] and r[2][1].text, "死人经.epub.po")
    eq("  时间戳原样带出来",
       r[2] and r[2][1] and r[2][1].modification, 1700000000)
    eq("  路径原样透传", calls.list_url, "/books/Apps/Books/.Moon+/Cache")
    eq("  要目录项(过滤留给调用方)", calls.list_include_folders, true)

    -- ④ base 是 server 的**副本**,用完必须还原 —— 否则会污染后续请求
    eq("  调用期间 base 指向目标服务器",
       calls.base_during_list and calls.base_during_list.address, plugin.server.address)
    check("  base 是副本,不是插件设置表本身",
          calls.base_during_list ~= plugin.server)
    eq("  调用后 base 还原", provider.base, nil)
    provider.base = "旧值"
    call(plugin, "/x")
    eq("  有旧值时还原成旧值", provider.base, "旧值")

    -- ⑤ listFolder 返回 nil 不能当空目录:那会把"同步失败"伪装成"没有这本书"
    local p5 = make_env{ listing = nil }
    r = call(p5, "/x")
    eq("listFolder 返回 nil → 失败", r[1], false)
    eq("  不给空列表", r[2], nil)
    check("  并说明原因",
          type(r[3]) == "string" and r[3]:find("list failed", 1, true) ~= nil, r[3])

    -- ⑥ provider 抛异常:必须吃掉,不能炸到调用方
    local p6 = make_env{}
    p6.ui.cloudstorage.providers.webdav.listFolder = function() error("boom") end
    r = call(p6, "/x")
    eq("listFolder 抛异常 → 失败(不抛出)", r[1], false)
    check("  带上原始原因",
          type(r[3]) == "string" and r[3]:find("boom", 1, true) ~= nil, r[3])
    eq("  异常时也要还原 base", p6.ui.cloudstorage.providers.webdav.base, nil)

    -- ⑦ 空目录是**成功**(只是没有 .po),要和失败严格区分
    local p7 = make_env{ listing = {} }
    r = call(p7, "/x")
    eq("空目录 → 成功", r[1], true)
    eq("  给出空列表", type(r[2]) == "table" and #r[2] or -1, 0)
    eq("  没有错误", r[3], nil)

    -- ⑧ 回调只许触发一次:provider.run 在回调之后再抛,不能把成功改写成失败
    local p8 = make_env{ listing = { { is_file = true, text = "a.po" } } }
    local prov8 = p8.ui.cloudstorage.providers.webdav
    prov8.run = function(cb) cb(); error("回调之后才炸") end
    r = call(p8, "/x")
    eq("迟到的异常不覆盖成功结果", r[1], true)
    eq("  文件还在", #r[2], 1)
    eq("  base 仍然还原", prov8.base, nil)

    -- ⑨ 缺路径:传空串,不能传 nil(上游按字符串拼 URL)
    local p9, _, c9 = make_env{ listing = {} }
    call(p9, nil)
    eq("缺路径时传空串", c9.list_url, "")

    -- ⑩ ★ 列目录期间必须临时打开 show_unsupported
    --
    -- 背景:KOReader 的 WebDAV provider 用
    --     if show_unsupported or DocumentRegistry:hasProvider(name) then … end
    -- 筛条目,而 `.po` 不在 KOReader 的文档类型表里 —— 不打开这个开关,
    -- `.po` 根本不会出现在列表里,表现就是「静读天下：无数据」。
    local seen_flag = nil
    G_reader_settings.data.show_unsupported = nil
    local p10 = make_env{ listing = {} }
    local prov10 = p10.ui.cloudstorage.providers.webdav
    local real_list = prov10.listFolder
    prov10.listFolder = function(url, inc)
        seen_flag = G_reader_settings.data.show_unsupported
        return real_list(url, inc)
    end
    call(p10, "/x")
    eq("列目录时 show_unsupported 是开的", seen_flag, true)
    eq("用完原样放回(原本没有 → 还是 nil)", G_reader_settings.data.show_unsupported, nil)

    -- 原本是 false(用户明确关过):也要放回 false,不能变成 true
    G_reader_settings.data.show_unsupported = false
    call(p10, "/x")
    eq("原本 false 就放回 false", G_reader_settings.data.show_unsupported, false)

    -- 原本是 true:保持 true
    G_reader_settings.data.show_unsupported = true
    call(p10, "/x")
    eq("原本 true 就保持 true", G_reader_settings.data.show_unsupported, true)

    -- provider 抛异常时也必须还原(否则等于偷偷改了全局偏好)
    G_reader_settings.data.show_unsupported = nil
    local p11 = make_env{}
    p11.ui.cloudstorage.providers.webdav.listFolder = function() error("boom") end
    call(p11, "/x")
    eq("抛异常后也要还原", G_reader_settings.data.show_unsupported, nil)

    -- 绝不写进设置文件:saveSetting 一次都不该被调用
    local saves = 0
    local real_save = G_reader_settings.saveSetting
    G_reader_settings.saveSetting = function(self, k, v)
        if k == "show_unsupported" then saves = saves + 1 end
        return real_save(self, k, v)
    end
    make_env{ listing = {} }
    call(make_env{ listing = {} }, "/x")
    eq("绝不把 show_unsupported 写进设置文件", saves, 0)
    G_reader_settings.saveSetting = real_save

    -- ⑪ 未联网时 provider.run 会**推迟回调**(NetworkMgr:willRerunWhenConnected
    --    返回 true 就立即 return、等联网再跑),开关必须一直开到回调真正执行 ——
    --    2026-10-08 自查抓到的时序 bug:原来在 run 返回后立刻还原,推迟执行时
    --    listFolder 真正跑起来开关已经关回去,.po 又会被过滤掉。
    local deferred_cb, deferred_flag = nil, nil
    G_reader_settings.data.show_unsupported = nil
    local p12 = make_env{ listing = { { is_file = true, text = "a.po" } } }
    local prov12 = p12.ui.cloudstorage.providers.webdav
    local real_list12 = prov12.listFolder
    prov12.listFolder = function(url, inc)
        deferred_flag = G_reader_settings.data.show_unsupported
        return real_list12(url, inc)
    end
    prov12.run = function(cb)
        deferred_cb = cb     -- 不执行,模拟"等联网"
        return true
    end
    local r12 = {}
    WebDAV.list_folder(p12, "/x", function(...) r12 = { ... } end)
    eq("  推迟时回调还没执行", #r12, 0)
    eq("  推迟期间开关仍然开着", G_reader_settings.data.show_unsupported, true)
    check("  推迟期间 base 也还摆着", prov12.base ~= nil)
    deferred_cb()
    eq("  推迟执行时 listFolder 看到的开关是开的", deferred_flag, true)
    eq("  推迟执行也列得出文件", r12[1], true)
    eq("  执行完才原样放回开关", G_reader_settings.data.show_unsupported, nil)
    eq("  执行完才还原 base", prov12.base, nil)
end

-- ── 删除云端文件(只给"清理过期记录"用) ────────────────────────────────────
-- 删除是**不可逆**的,所以这个函数的每一条拒绝路径都要有测试:
-- 宁可删不掉,也绝不能删错。
print("== delete_file（删除单个云端文件）==")
do
    local function del(plugin, url)
        return invoke(function(cb) WebDAV.delete_file(plugin, url, cb) end)
    end

    local r = del({ server = { type = "dropbox" }, ui = {} }, "/x.txt")
    eq("非 WebDAV 目标 → 失败", r[1], false)
    check("  并说明原因",
          type(r[2]) == "string" and r[2]:find("not configured", 1, true) ~= nil, r[2])

    -- ★ 远端路径来自服务器返回的列表项,不可信任 —— 和下载同一套校验
    local bad_paths = {
        { "反斜杠",     "/books\\evil.txt" },
        { "双点穿越",   "/books/../../etc/passwd" },
        { "协议头",     "http://evil/x" },
        { "换行",       "/books/a\nb.txt" },
        { "空串",       "" },
    }
    local plugin, provider, calls = make_env{ listing = {} }
    for _, c in ipairs(bad_paths) do
        r = del(plugin, c[2])
        eq("拒绝：" .. c[1], r[1], false)
    end
    eq("  非法路径一个都没送到 provider", calls.deleted, nil)
    eq("  拒绝 nil", del(plugin, nil)[1], false)
    eq("  拒绝数字", del(plugin, 123)[1], false)

    -- provider 不支持删除(老版本 / 非 WebDAV 后端)
    local p2 = make_env{ listing = {} }
    p2.ui.cloudstorage.providers.webdav.deleteFile = nil
    r = del(p2, "/books/x.txt")
    eq("provider 不能删 → 失败", r[1], false)
    check("  并说明原因",
          type(r[2]) == "string" and r[2]:find("cannot delete", 1, true) ~= nil, r[2])

    -- 正常
    local p3, prov3, c3 = make_env{ listing = {} }
    r = del(p3, "/books/旧记录.InkBridge.txt")
    eq("正常删除 → 成功", r[1], true)
    eq("  没有错误", r[2], nil)
    eq("  把路径原样交给 provider", c3.deleted and c3.deleted[1], "/books/旧记录.InkBridge.txt")
    eq("  调用期间 base 指向目标服务器",
       c3.base_during_delete and c3.base_during_delete.address, p3.server.address)
    check("  base 是副本,不是插件设置表本身", c3.base_during_delete ~= p3.server)
    eq("  调用后 base 还原", prov3.base, nil)

    -- 服务器拒绝(provider 返回 nil)
    local p4 = make_env{ listing = {}, delete_ok = false }
    r = del(p4, "/books/x.txt")
    eq("服务器拒绝 → 失败", r[1], false)
    eq("  base 也要还原", p4.ui.cloudstorage.providers.webdav.base, nil)

    -- 抛异常:吃掉,并且还原 base
    local p5 = make_env{ listing = {} }
    p5.ui.cloudstorage.providers.webdav.deleteFile = function() error("boom") end
    r = del(p5, "/books/x.txt")
    eq("抛异常 → 失败(不抛出)", r[1], false)
    check("  带上原始原因",
          type(r[2]) == "string" and r[2]:find("boom", 1, true) ~= nil, r[2])
    eq("  异常时也要还原 base", p5.ui.cloudstorage.providers.webdav.base, nil)

    -- provider.run 本身抛异常
    local p6 = make_env{ listing = {} }
    p6.ui.cloudstorage.providers.webdav.run = function() error("dispatcher down") end
    r = del(p6, "/books/x.txt")
    eq("派发失败 → 失败", r[1], false)
    eq("  此时也不该发出删除请求", p6.ui.cloudstorage.providers.webdav.base, nil)
end

do
    local History = require("inkbridge_home_history")
    local old_observe, old_plan = History.observe, WebDAV._plan_jump
    local sources = {}
    History.observe = function(_, _, source) sources[#sources + 1] = source end
    WebDAV._plan_jump = function() return nil, "not_found" end
    local plugin = { ui = { document = { file = "book.epub" } } }
    WebDAV.confirm_jump(plugin, { text_anchor = "原文", device_label = "静读天下" })
    eq("读取静读天下正文可缓存但不代表采用", sources[1], "静读天下")
    WebDAV.confirm_jump(plugin, { text_anchor = "原文", device_label = "Kindle" })
    eq("墨桥远端保留设备来源", sources[2], "墨桥 · Kindle")
    WebDAV.confirm_jump(plugin, { text_anchor = "原文" }, { home_replay = true })
    eq("首页重放不重复采集历史", #sources, 2)
    History.observe, WebDAV._plan_jump = old_observe, old_plan
end

print(string.format("\n合计：%d 通过，%d 失败", passed, failed))
if failed > 0 then os.exit(1) end
print("全部通过。")
