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
package.preload["ui/widget/infomessage"] = function() return { new = function(_, o) return o or {} end } end
package.preload["ui/widget/confirmbox"]  = function() return { new = function(_, o) return o or {} end } end
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
    isTrue       = function() return false end,
    readSetting  = function() end,
    saveSetting  = function() end,
    delSetting   = function() end,
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
        return opts.listing
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
            if xp == "hit-far" then return 10000 end
            return 90000
        end,
        clearSelection = function() calls.cleared = true end,
        getPageCount = function() return 8689 end,
    }
end

local function plan_ui(doc, rolling)
    if rolling == "none" then return { document = doc } end
    return { document = doc, rolling = rolling or { getLastProgress = function() end } }
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

print(string.format("\n合计：%d 通过，%d 失败", passed, failed))
if failed > 0 then os.exit(1) end
print("全部通过。")
