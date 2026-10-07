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
end

print(string.format("\n合计：%d 通过，%d 失败", passed, failed))
if failed > 0 then os.exit(1) end
print("全部通过。")
