-- ============================================================================
-- tests/main_spec.lua — InkBridge 主流程回归测试
--
-- 覆盖：文件名生成、位置比较、上传后清理暂存文件、未联网时的提示流程。
-- 运行： luajit tests/main_spec.lua   (在仓库根目录执行)
-- ============================================================================

local script_path = arg and arg[0] or "tests/main_spec.lua"
local script_dir  = script_path:match("^(.*)[/\\][^/\\]*$") or "."
local PLUGIN_DIR  = script_dir .. "/../inkbridge.koplugin"
package.path = PLUGIN_DIR .. "/?.lua;" .. package.path

-- ── 可观测的打桩设施 ───────────────────────────────────────────────────
local shown       = {}   -- UIManager:show 收到的内容
local wifi_prompt = nil  -- 未联网时 promptWifiOn 注册的回调
local connected   = true
local confirm_cb  = nil  -- ConfirmBox:new 收到的 ok_callback

package.preload["ui/widget/container/widgetcontainer"] = function()
    local Widget = {}
    Widget.__index = Widget
    function Widget:extend(proto)
        proto = proto or {}
        proto.__index = proto
        return setmetatable(proto, { __index = self })
    end
    return Widget
end
package.preload["ui/uimanager"] = function()
    return {
        show     = function(_, widget) shown[#shown + 1] = widget end,
        close    = function() end,
        nextTick = function(fn) fn() end,
    }
end
package.preload["ui/widget/infomessage"] = function() return { new = function(_, o) return o or {} end } end
package.preload["ui/widget/inputdialog"] = function() return { new = function(_, o) return o or {} end } end
package.preload["ui/widget/buttondialog"] = function() return { new = function(_, o) return o or {} end } end
package.preload["ui/widget/confirmbox"]  = function()
    return { new = function(_, o) confirm_cb = o and o.ok_callback; return o or {} end }
end
package.preload["ui/event"] = function() return { new = function(_, n, a) return { name = n, arg = a } end } end
package.preload["rapidjson"] = function()
    return { encode = function() return "{}" end, decode = function() return nil, "stub" end }
end
package.preload["ui/network/manager"] = function()
    return {
        isConnected = function() return connected end,
        promptWifiOn = function(_, cb) wifi_prompt = cb end,
    }
end

local SETTINGS_DIR = (os.getenv("TEMP") or "/tmp") .. "\\ib-spec-settings"
package.preload["datastorage"] = function()
    return { getSettingsDir = function() return SETTINGS_DIR end }
end
package.preload["util"] = function()
    return {
        tableDeepCopy = function(t)
            local c = {}
            for k, v in pairs(t or {}) do c[k] = v end
            return c
        end,
        makePath = function(dir)
            os.execute('mkdir "' .. dir:gsub("/", "\\") .. '" 2>nul')
            return true
        end,
    }
end

local InkBridge = dofile(PLUGIN_DIR .. "/main.lua")
local WebDAV    = require("inkbridge_webdav")
local State     = require("inkbridge_state")

-- ── 断言框架 ───────────────────────────────────────────────────────────
local passed, failed = 0, 0
local function check(label, cond, detail)
    if cond then
        passed = passed + 1
        print("    PASS  " .. label)
    else
        failed = failed + 1
        print(string.format("    FAIL  %s%s", label, detail and ("  -> " .. tostring(detail)) or ""))
    end
end
local function eq(label, got, want)
    check(label, got == want, string.format("得到 %s，期望 %s", tostring(got), tostring(want)))
end
local function contains(label, haystack, needle)
    check(label, type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil,
        string.format("[%s] 中找不到 [%s]", tostring(haystack), tostring(needle)))
end

local function new_plugin(overrides)
    local p = setmetatable({}, InkBridge)
    p.device_id    = "1700000000-8147"
    p.device_label = "汉王C7T"
    p.server       = { type = "webdav", address = "https://dav.example.com/dav", username = "u", password = "p", url = "/books" }
    for k, v in pairs(overrides or {}) do p[k] = v end
    return p
end

local function file_exists(path)
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
end

-- ============================================================================
print("== 1. _history_name（云端文件名生成）==")
-- ============================================================================
-- 目标格式：<书名>-MMDD-HHMMSS-<设备名>.<短哈希>.InkBridge.txt
do
    local plugin = new_plugin()
    local entry = {
        schema_version = 1,
        book_id = "deadbeefcafe1234deadbeefcafe1234",
        book_name = "死人经",
        percent = 0.47,
        updated_at = 1760000000,
    }
    local name = plugin:_history_name(entry)
    contains("以书名开头", name, "死人经-")
    contains("含短哈希（机器认书用，不能去掉）", name, ".deadbeef.InkBridge.txt")
    check("扩展名为 .txt", name:sub(-4) == ".txt")

    -- 时间部分：含月份、纯 ASCII、可排序。旧格式 %d%H日%M分%S秒 不含月份，
    -- 9 月 6 日与 10 月 6 日会生成同样的名字。
    local expect_ts = os.date("%m%d-%H%M%S", 1760000000)
    contains("时间格式为 MMDD-HHMMSS", name, "死人经-" .. expect_ts .. "-")
    check("时间部分不含汉字（日/分/秒）",
        name:find("日", 1, true) == nil and name:find("分", 1, true) == nil
        and name:find("秒", 1, true) == nil)
    eq("时间部分长度为 11", #expect_ts, 11)
end

do
    -- 设备标识：只保留设备名，不再拼设备 ID 尾四位
    local plugin = new_plugin({ device_id = "1791209408-8147" })
    local name = plugin:_history_name({
        book_id = "deadbeefcafe1234", book_name = "书", updated_at = 1760000000,
    })
    contains("设备名后面直接跟短哈希（不含设备 ID 尾四位）", name, "-汉王C7T.deadbeef.InkBridge.txt")
    check("文件名里不出现设备 ID 尾四位", name:find("8147", 1, true) == nil, name)
end

do
    -- 非法字符必须被替换，避免生成设备上非法的文件名
    local plugin = new_plugin()
    local name = plugin:_history_name({
        book_id = "deadbeefcafe1234", book_name = 'a/b:c*?"<>|d',
        updated_at = 1760000000,
    })
    contains("非法字符替换为下划线", name, "a_b_c__")
    check("结果里没有路径分隔符等非法字符", name:find("[/:*?]", 1) == nil, name)
end

do
    -- 长度限制必须按字符算：按字节截断会把一个汉字劈成半个，产生非法 UTF-8
    local plugin = new_plugin({ device_label = string.rep("设", 40) })
    local long_name = string.rep("长", 100)
    local name = plugin:_history_name({
        book_id = "deadbeefcafe1234", book_name = long_name, updated_at = 1760000000,
    })
    local prefix = name:match("^(.-)%-%d%d%d%d%-%d%d%d%d%d%d%-") or ""
    eq("书名截断到 40 个字符", State._utf8_len(prefix), 40)
    local label = name:match("%-%d%d%d%d%-%d%d%d%d%d%d%-(.-)%.deadbeef")
    eq("设备名截断到 16 个字符", State._utf8_len(label or ""), 16)
end

do
    -- 书名缺失时用回退名，不能生成以 "-" 开头的文件名
    local plugin = new_plugin()
    local name = plugin:_history_name({
        book_id = "deadbeefcafe1234", book_name = "", updated_at = 1760000000,
    })
    contains("书名缺失时回退为 book", name, "book-")
    check("不以分隔符开头", name:sub(1, 1) ~= "-")
end

-- ============================================================================
print("== 2. _position_differs（位置比较）==")
-- ============================================================================
do
    local plugin = new_plugin()
    check("双方都有相同 xpointer -> 相同",
        plugin:_position_differs({ xpointer = "/body/p[1]" }, { xpointer = "/body/p[1]" }) == false)
    check("xpointer 不同 -> 不同",
        plugin:_position_differs({ xpointer = "/body/p[1]" }, { xpointer = "/body/p[2]" }) == true)
    check("无 xpointer 时按页码比较",
        plugin:_position_differs({ page = 10 }, { page = 11 }) == true)
    check("页码相同 -> 相同",
        plugin:_position_differs({ page = 10 }, { page = 10 }) == false)
    check("只剩百分比时按阈值比较",
        plugin:_position_differs({ percent = 0.40 }, { percent = 0.41 }) == true)
    check("百分比微差 -> 视为相同",
        plugin:_position_differs({ percent = 0.40000 }, { percent = 0.40001 }) == false)
end

-- ============================================================================
print("== 3. 上传后清理本地暂存文件 ==")
-- ============================================================================
do
    local plugin = new_plugin()
    local entry = {
        schema_version = 1,
        book_id = "deadbeefcafe1234deadbeefcafe1234",
        -- 用 ASCII 书名：LuaJIT 在 Windows 上按 ANSI 代码页打开文件，
        -- 中文文件名会写不出来（设备端无此限制）。
        book_name = "TestBook",
        percent = 0.47,
        updated_at = 1760000000,
    }

    local real_upload = WebDAV.upload
    local captured = {}
    WebDAV.upload = function(_, staged_path, cb)
        captured.path = staged_path
        captured.existed_during_upload = file_exists(staged_path)
        cb(true, nil)
    end

    plugin:_sync(entry, "upload")
    WebDAV.upload = real_upload

    check("上传时暂存文件确实存在", captured.existed_during_upload == true)
    contains("暂存路径在插件自己的 staging 目录下", captured.path, SETTINGS_DIR)
    check("上传完成后暂存文件已被删除", file_exists(captured.path) == false, captured.path)
end

-- ============================================================================
print("== 4. 未联网时的提示流程 ==")
-- ============================================================================
do
    local plugin = new_plugin()
    local ran = 0
    connected = true
    wifi_prompt = nil
    plugin:_with_network(function() ran = ran + 1 end)
    eq("已联网：直接执行", ran, 1)
    eq("已联网：不弹 WiFi 询问", wifi_prompt, nil)
end

do
    local plugin = new_plugin()
    local ran = 0
    connected = false
    wifi_prompt = nil
    shown = {}
    plugin:_with_network(function() ran = ran + 1 end)
    eq("未联网：先不执行", ran, 0)
    check("未联网：弹出了开启 WiFi 的询问", wifi_prompt ~= nil)
    -- 用户同意并连上
    connected = true
    if wifi_prompt then wifi_prompt() end
    eq("连上后执行动作", ran, 1)
end

do
    local plugin = new_plugin()
    local ran = 0
    connected = false
    wifi_prompt = nil
    shown = {}
    plugin:_with_network(function() ran = ran + 1 end)
    -- 用户拒绝 / 连接失败：仍处于未联网
    if wifi_prompt then wifi_prompt() end
    eq("未连上则中止动作", ran, 0)
    check("给出了可见提示（不再静默）", #shown > 0)
    if #shown > 0 then contains("提示文案正确", shown[#shown].text, "未连接网络") end
end

-- ============================================================================
print("== 5. 未打开书籍时的即时提示 ==")
-- ============================================================================
do
    local plugin = new_plugin()
    plugin.ui = {}          -- 没有 document
    connected = false
    wifi_prompt = nil
    shown = {}
    plugin:upload_current()
    check("给出提示", #shown > 0)
    eq("未联网也不该先弹 WiFi（书本检查优先）", wifi_prompt, nil)
end

-- 收尾：清掉测试用的设置目录
os.execute('rmdir /s /q "' .. SETTINGS_DIR .. '" 2>nul')

print(string.format("\n合计：%d 通过，%d 失败", passed, failed))
if failed > 0 then os.exit(1) end
print("全部通过。")
