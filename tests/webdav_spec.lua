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
print(string.format("\n合计：%d 通过，%d 失败", passed, failed))
if failed > 0 then os.exit(1) end
print("全部通过。")
