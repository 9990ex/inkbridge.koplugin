-- ============================================================================
-- tests/main_spec.lua — InkBridge 主流程回归测试
--
-- 覆盖：文件名生成、位置比较、上传后清理暂存文件、未联网时的提示流程。
-- 运行： luajit tests/main_spec.lua   (在仓库根目录执行)
-- ============================================================================

dofile("tests/material_business_stub.lua")
local script_path = arg and arg[0] or "tests/main_spec.lua"
local script_dir  = script_path:match("^(.*)[/\\][^/\\]*$") or "."
local PLUGIN_DIR  = script_dir .. "/../inkbridge.koplugin"
package.path = PLUGIN_DIR .. "/?.lua;" .. package.path
local is_windows  = package.config:sub(1, 1) == "\\"
local null_device = is_windows and "nul" or "/dev/null"

-- ── 可观测的打桩设施 ───────────────────────────────────────────────────
local shown       = {}   -- UIManager:show 收到的内容
local wifi_prompt = nil  -- 未联网时 promptWifiOn 注册的回调
local connected   = true
local confirm_cb  = nil  -- ConfirmBox:new 收到的 ok_callback
local last_keyvalue = nil

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
        nextTick = function(_, fn) fn() end,
    }
end
package.preload["ui/widget/infomessage"] = function() return { new = function(_, o) return o or {} end } end
package.preload["ui/widget/keyvaluepage"] = function()
    return { new = function(_, o) last_keyvalue = o; return o or {} end }
end
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

local SETTINGS_DIR = (os.getenv("TEMP") or "/tmp")
    .. (is_windows and "\\" or "/") .. "ib-spec-settings"
package.preload["datastorage"] = function()
    return {
        getSettingsDir = function() return SETTINGS_DIR end,
        getDataDir = function() return SETTINGS_DIR .. (is_windows and "\\data" or "/data") end,
    }
end
package.preload["libs/libkoreader-lfs"] = function()
    return { attributes = function(path, mode)
        if mode ~= "file" then return nil end
        local file = io.open(path, "rb")
        if not file then return nil end
        file:close()
        return "file"
    end }
end
package.preload["util"] = function()
    return {
        tableDeepCopy = function(t)
            local c = {}
            for k, v in pairs(t or {}) do c[k] = v end
            return c
        end,
        makePath = function(dir)
            local path = is_windows and dir:gsub("/", "\\") or dir
            local command = is_windows and "mkdir" or "mkdir -p"
            os.execute(command .. ' "' .. path .. '" 2>' .. null_device)
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

local function row_value(rows, label)
    for _, row in ipairs(rows or {}) do
        if row[1] == label then return row[2] end
    end
end

local function item_index(items, text)
    for i, item in ipairs(items or {}) do
        if item.text == text then return i end
    end
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
    eq("设备名截断到 DEVICE_LABEL_MAX 个字符", State._utf8_len(label or ""),
       InkBridge.DEVICE_LABEL_MAX)
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

-- ============================================================================
print("== 6. 轻量同步状态页 ==")
-- ============================================================================
do
    local plugin = new_plugin({
        server = {
            type = "webdav",
            address = "https://secret-user:secret-password@dav.example.com/dav",
            username = "secret-user",
            password = "secret-password",
            url = "/books",
        },
    })
    plugin._status_book_context = function()
        return { book_name = "测试书", percent = 0.47, page = 47, total_pages = 100 }
    end
    local rows = plugin:_sync_status_rows()
    eq("状态页显示脱敏后的 WebDAV 目标", row_value(rows, "云端目标"), "https://dav.example.com/dav")
    eq("状态页显示同步目录", row_value(rows, "墨桥目录"), "/books")
    eq("状态页显示当前书", row_value(rows, "当前书籍"), "测试书")
    eq("状态页显示本地进度", row_value(rows, "本地位置"), "47.00%（第 47 / 100 页）")
    check("状态页不泄露用户名", not table.concat({
        tostring(row_value(rows, "云端目标") or ""), tostring(row_value(rows, "墨桥目录") or ""),
    }, "\n"):find("secret-user", 1, true))
    check("状态页不泄露密码", not table.concat({
        tostring(row_value(rows, "云端目标") or ""), tostring(row_value(rows, "墨桥目录") or ""),
    }, "\n"):find("secret-password", 1, true))

    last_keyvalue = nil
    plugin:show_sync_status()
    eq("使用 KeyValuePage 展示状态", last_keyvalue and last_keyvalue.title, "InkBridge+ · 同步状态")
    eq("状态页传入相同数据", row_value(last_keyvalue and last_keyvalue.kv_pairs, "当前书籍"), "测试书")

    local menu_items = {}
    plugin:addToMainMenu(menu_items)
    eq("顶层页签显示 InkBridge+", menu_items.inkbridge.text, "InkBridge+ v" .. require("_meta").version)
    eq("墨桥页签使用汉字桥图标", menu_items.inkbridge.icon, "inkbridge-bridge")
    eq("菜单入口不再指定工具子菜单", menu_items.inkbridge.sorting_hint, nil)
    check("墨桥保留原位下拉菜单入口", menu_items.inkbridge.callback == nil
        and type(menu_items.inkbridge.sub_item_table_func) == "function")
    local menu = menu_items.inkbridge.sub_item_table_func()
    for i, label in ipairs({ "上传", "下载", "同步", "高级" }) do
        eq("下拉图标顺序" .. i, menu[i].text, label)
        check("下拉动作带有图标" .. i, type(menu[i].icon) == "string")
    end
    check("高级选项继续使用原生动态子菜单", type(menu[4].sub_item_table_func) == "function")
    local bookmenu = menu_items.inkbridge_book.sub_item_table_func()
    check("墨页签使用独立汉字图标", menu_items.inkbridge_book.icon == "inkbridge-ink")
    for i, label in ipairs({ "书籍重构", "章节跳转", "内容搜索", "快速跳转", "首页" }) do
        eq("墨页签书籍操作顺序" .. i, bookmenu[i].text, label)
    end
    check("桥页签只保留跨设备同步功能及配置入口", #menu == 4 or #menu == 5 and menu[5]._inkbridge_setup)
    check("没有打开书时禁用章节搜索和跳转", not bookmenu[2].enabled_func()
        and not bookmenu[3].enabled_func() and not bookmenu[4].enabled_func())
    local chapter_calls, search_calls, goto_calls = 0, 0, 0
    plugin.ui = { document = {}, toc = { onShowToc = function() chapter_calls = chapter_calls + 1 end },
        search = { onShowFulltextSearchInput = function() search_calls = search_calls + 1 end },
        gotopage = { onShowGotoDialog = function() goto_calls = goto_calls + 1 end } }
    check("打开书后动态启用三个书籍入口", bookmenu[2].enabled_func()
        and bookmenu[3].enabled_func() and bookmenu[4].enabled_func())
    bookmenu[2].callback(); bookmenu[3].callback(); bookmenu[4].callback()
    check("书籍入口调用当前阅读器原生功能", chapter_calls == 1 and search_calls == 1 and goto_calls == 1)
    plugin.ui = nil
    local rebuild_plugin
    package.loaded["inkbridge_rebuild_ui"] = { show = function(p) rebuild_plugin = p end }
    bookmenu[1].callback()
    check("书籍重构按需加载并接收当前插件", rebuild_plugin == plugin)
    package.loaded["inkbridge_rebuild_ui"] = nil
    local menu_tabs = {
        { icon = "appbar.navigation" },
        { icon = "appbar.tools", menu_items.inkbridge },
    }
    menu_items.inkbridge.id = "inkbridge"
    local mock_menu = { tab_item_table = menu_tabs }
    check("菜单排序后提升为独立顶层页签", InkBridge._promote_menu_tab(mock_menu)
        and menu_tabs[1].icon == "inkbridge-bridge")
    check("提升后从工具页签列表移除", #menu_tabs[3] == 0)
    eq("提升保留桥字图标", menu_tabs[1].icon, "inkbridge-bridge")
    check("独立页签标记原位网格且不弹窗", menu_tabs[1]._inkbridge_grid
        and menu_tabs[1].callback == nil)
    check("重复刷新不会重复插入页签", not InkBridge._promote_menu_tab(mock_menu) and #menu_tabs == 3)
    local bridge = table.remove(menu_tabs, 1)
    table.insert(menu_tabs, bridge)
    check("缓存中的桥页签也能移到第一位", InkBridge._promote_menu_tab(mock_menu)
        and menu_tabs[1] == bridge and #menu_tabs == 3)
    check("其他页签的相对顺序不变", menu_tabs[2].icon == "appbar.navigation"
        and menu_tabs[3].icon == "appbar.tools")
    menu_items.inkbridge_book.id = "inkbridge_book"
    table.insert(menu_tabs[3], menu_items.inkbridge_book)
    check("墨提升为与桥平级的第二个页签", InkBridge._promote_menu_tab(mock_menu)
        and menu_tabs[1]._inkbridge_tab and menu_tabs[2]._inkbridge_book_tab
        and menu_tabs[2]._inkbridge_grid and menu_tabs[2].icon == "inkbridge-ink")
    check("两页签重复显示不重复创建", not InkBridge._promote_menu_tab(mock_menu) and #menu_tabs == 4)
    local menu_show_calls, rebuild_calls = 0, 0
    local show_menu = function() menu_show_calls = menu_show_calls + 1 end
    local cached_menu = {
        onShowMenu = show_menu,
        setUpdateItemTable = function(self)
            rebuild_calls = rebuild_calls + 1
            self.tab_item_table = menu_tabs
        end,
        tab_item_table = menu_tabs,
    }
    check("显示菜单前安装提升钩子", InkBridge._install_menu_promoter(cached_menu))
    cached_menu:onShowMenu()
    check("显示缓存菜单时执行钩子", menu_show_calls == 1 and rebuild_calls == 0)
    cached_menu.tab_item_table = nil
    cached_menu:onShowMenu()
    check("菜单首次构建后也执行提升", menu_show_calls == 2 and rebuild_calls == 1)
    check("菜单提升钩子只安装一次", not InkBridge._install_menu_promoter(cached_menu))
    local menu_class = { onShowMenu = show_menu }
    check("提升钩子可安装到KOReader菜单类", InkBridge._install_menu_promoter(menu_class))
    local new_menu_instance = setmetatable({ tab_item_table = menu_tabs }, { __index = menu_class })
    new_menu_instance:onShowMenu()
    check("后续创建的菜单实例继承提升钩子", menu_show_calls == 3)
    local icon_plugin = new_plugin{ path = PLUGIN_DIR }
    icon_plugin:_install_menu_icon()
    local icon_path = require("datastorage").getDataDir()
        .. (is_windows and "\\icons\\inkbridge-bridge.png" or "/icons/inkbridge-bridge.png")
    local icon_file = io.open(icon_path, "rb")
    local installed_icon = icon_file and icon_file:read("*a")
    if icon_file then icon_file:close() end
    check("首次启动安装桥字PNG菜单图标", installed_icon and installed_icon:sub(1, 8) == "\137PNG\r\n\26\n")
    icon_plugin:_install_menu_icon()
    local icon_check = io.open(icon_path, "rb")
    local icon_after_repeat = icon_check and icon_check:read("*a")
    if icon_check then icon_check:close() end
    eq("重复安装不覆盖已有图标", icon_after_repeat, installed_icon)
    os.remove(icon_path)
end

-- ============================================================================
print("== 7. 下载临时文件路径 ==")
-- ============================================================================
-- ① 临时名必须是纯 ASCII：LuaJIT 在 Windows 上通过 ANSI 代码页打开文件，
-- 含中文的本地路径会直接报 “Illegal byte sequence”。
-- 设备端是 UTF-8 本来没事，但没有理由让一个临时文件名成为平台陷阱。
do
    local plugin = new_plugin()
    local path = plugin:_download_staging_path()

    local non_ascii = 0
    for i = 1, #path do
        if path:byte(i) > 127 then non_ascii = non_ascii + 1 end
    end
    eq("路径里没有非 ASCII 字节", non_ascii, 0)
    contains("位于插件自己的 staging 目录下", path, SETTINGS_DIR)
    check("以 .tmp 结尾", path:sub(-4) == ".tmp")

    -- 旧签名接受远端文件名；即使有人按老方式带参调用，也必须仍然是 ASCII
    local path2 = plugin:_download_staging_path("死人经-1006-130615-c7t.d31f852b.InkBridge.txt")
    eq("带参调用也不含非 ASCII", path2, path)
end

-- ============================================================================
print("== 无墨桥历史时仍可手动读取 Moon+ ==")
do
    local MS = require("inkbridge_moonsync")
    local list, download, peek, import, confirm = WebDAV.list_history, WebDAV.download, MS.peek_po, MS.import_from_moon, WebDAV.confirm_jump
    local plugin = new_plugin()
    local entry = {book_id="txt-first-sync",book_name="测试TXT"}
    local imports, peeks, confirms = 0, 0, 0
    WebDAV.list_history = function(_,_,cb) cb(true,{}) end
    WebDAV.download = function(_,_,cb) cb(false,nil,"missing") end
    MS.peek_po = function(_,cb) peeks=peeks+1;cb({po={star=0,hash=100}}) end
    MS.import_from_moon = function() imports=imports+1 end
    WebDAV.confirm_jump = function() confirms=confirms+1 end
    plugin:_sync(entry,"download")
    eq("没有墨桥历史仍查Moon",peeks,1)
    eq("有Moon记录进入正文核对",imports,1)
    MS.peek_po = function(_,cb) peeks=peeks+1;cb(nil) end
    plugin:_sync(entry,"download")
    eq("两处均无记录不导入",imports,1)
    contains("两处无记录明确提示",shown[#shown].text,"没有找到")
    WebDAV.download = function(_,_,cb) cb(true,{book_id=entry.book_id}) end
    plugin:_sync(entry,"download")
    eq("旧版历史仍优先兼容",confirms,1)
    eq("旧版存在不额外查Moon",peeks,2)
    WebDAV.download = function(_,_,cb) cb(false,nil,"HTTP 403") end
    plugin:_sync(entry,"download")
    eq("旧版请求异常不吞错转Moon",peeks,2)
    contains("旧版请求异常如实提示",shown[#shown].text,"读取旧版远端记录失败")
    WebDAV.list_history, WebDAV.download, MS.peek_po, MS.import_from_moon, WebDAV.confirm_jump = list, download, peek, import, confirm
end

print("== 7. 云端历史记录的保留策略（每台设备每本书留 3 条）==")
-- ============================================================================
-- 这是本项目里**唯一会删用户云端数据**的代码,每一条安全线都要有测试。
-- 删除不可逆 —— 出错的代价不是"多一个文件",而是"另一台设备的记录没了"。
do
    -- 真名格式:<书名>-MMDD-HHMMSS-<设备名>.<短哈希>.InkBridge.txt
    -- idx 让每条的 HMMSS 与 url 都唯一(否则 fixture 自己就会撞成一条)。
    local function record(device, time, idx)
        local name = "死人经-1006-" .. string.format("%06d", idx)
            .. "-" .. device .. ".deadbeef.InkBridge.txt"
        return { is_file = true, text = name, url = "/books/" .. name,
                 modification = time }
    end

    local function prune_plugin(items, delete_ok)
        local deleted = {}
        local provider = {
            run = function(cb) cb() end,
            listFolder = function() return items end,
            deleteFile = function(url)
                deleted[#deleted + 1] = url     -- 先记下"确实调用过",再模拟失败
                if delete_ok == "throw" then error("boom") end
                if delete_ok == false then return nil end
                return true
            end,
        }
        local p = new_plugin{ ui = { cloudstorage = { providers = { webdav = provider } } } }
        return p, deleted
    end

    local function run_prune(p, keep_name)
        local got
        p:_prune_history("deadbeef", keep_name, function(n) got = n end)
        return got
    end

    -- ① 到上限为止:一条都不删
    local items = {}
    for i = 1, 3 do items[i] = record("汉王C7T", 1000 + i, i) end
    local p, del = prune_plugin(items)
    eq("恰好 3 条:不删", run_prune(p, "没有这条"), 0)
    eq("  也没发出删除请求", #del, 0)

    -- ② 超一条:删最旧的那一条
    items = {}
    for i = 1, 4 do items[i] = record("汉王C7T", 1000 + i, i) end
    p, del = prune_plugin(items)
    eq("4 条:删 1 条", run_prune(p, "没有这条"), 1)
    eq("  最旧的那条被删", del[1], record("汉王C7T", 1001, 1).url)

    -- ③ 每台设备**各算各的** —— 这是"每设备 3 条"的关键
    items = {}
    for i = 1, 4 do items[i] = record("汉王C7T", 2000 + i, i) end          -- 4 条
    for i = 1, 3  do items[#items + 1] = record("Kindle", 3000 + i, 100 + i) end  -- 3 条
    p, del = prune_plugin(items)
    eq("两台设备:只删超限的那台", run_prune(p, "没有这条"), 1)
    eq("  删的是汉王最旧那条", del[1], record("汉王C7T", 2001, 1).url)
    check("  没碰 Kindle 的任何一条",
          del[1] ~= record("Kindle", 3001, 101).url
          and del[1] ~= record("Kindle", 3002, 102).url)

    -- ④ ★ 刚上传的那一条**永不删**,哪怕服务器把它的时间戳给成 0(排到最后)
    items = {}
    for i = 1, 5 do items[i] = record("汉王C7T", 1000 + i, i) end
    local keep_name = record("汉王C7T", 1001, 1).text      -- 最旧的那条,就是"刚传的"
    p, del = prune_plugin(items)
    eq("刚上传的那条占一个名额", run_prune(p, keep_name), 2)
    check("  被删的不是它", del[1] ~= record("汉王C7T", 1001, 1).url, del[1])
    check("  第二旧的被删", del[1] == record("汉王C7T", 1002, 2).url
        or del[2] == record("汉王C7T", 1002, 2).url)

    -- ⑤ 认不出设备名的记录(旧格式)一律不碰
    items = {}
    for i = 1, 4 do items[i] = record("汉王C7T", 1000 + i, i) end
    items[#items + 1] = { is_file = true, text = "InkBridge-deadbeef-1700000000.json",
                          url = "/books/InkBridge-deadbeef-1700000000.json",
                          modification = 1 }
    p, del = prune_plugin(items)
    eq("旧格式记录不参与计数", run_prune(p, "没有这条"), 1)
    eq("  只删了一条", #del, 1)
    check("  旧格式那条没被删",
          del[1] ~= "/books/InkBridge-deadbeef-1700000000.json", del[1])

    -- ⑥ 列目录失败:什么都不删(保留总比删错好)
    p, del = prune_plugin(nil)
    eq("列目录失败:不删", run_prune(p, "没有这条"), 0)
    eq("  一条都没发出去", #del, 0)

    -- ⑦ 服务器拒绝删除:计数不涨,也不抛
    p, del = prune_plugin(items, false)
    eq("服务器拒绝:计数为 0", run_prune(p, "没有这条"), 0)
    eq("  但确实尝试过", #del, 1)

    -- ⑧ 删除抛异常:吃掉,继续删剩下的(不能让第 1 条失败挡住第 2 条)
    items = {}
    for i = 1, 5 do items[i] = record("汉王C7T", 1000 + i, i) end
    p, del = prune_plugin(items, "throw")
    eq("抛异常不传播,计数为 0", run_prune(p, "没有这条"), 0)
    eq("  并且把该试的两条都试了", #del, 2)

    -- ⑨ provider 不支持删除(老版本):放弃,不误报
    items = {}
    for i = 1, 5 do items[i] = record("汉王C7T", 1000 + i, i) end
    local p9 = new_plugin{ ui = { cloudstorage = { providers = { webdav = {
        run = function(cb) cb() end,
        listFolder = function() return items end,
    } } } } }
    eq("provider 不能删:计数为 0(也不会报成功)", run_prune(p9, "没有这条"), 0)

    -- ⑩ 三台设备各超限:条数相加
    items = {}
    for i = 1, 6 do items[i] = record("A", 1000 + i, i) end
    for i = 1, 5 do items[#items + 1] = record("B", 2000 + i, 100 + i) end
    for i = 1, 3 do items[#items + 1] = record("C", 3000 + i, 200 + i) end
    p, del = prune_plugin(items)
    eq("A 超 3、B 超 2、C 不超 → 删 5", run_prune(p, "没有这条"), 5)
    eq("  确实发了 5 个删除请求", #del, 5)

    -- ⑪ list_history 自己崩掉:整段被 pcall 包住,清理绝不能把上传流程带崩;
    --    但也必须**回调出去**,否则调用方会一直等。
    local p11 = new_plugin{ ui = { cloudstorage = { providers = { webdav = {
        run = function() error("dispatcher down") end,
        listFolder = function() return {} end,
        deleteFile = function() return true end,
    } } } } }
    local called = false
    local ok11 = pcall(function()
        p11:_prune_history("deadbeef", "x", function() called = true end)
    end)
    check("派发崩掉也不抛异常", ok11)
    eq("  仍然回调(计数 0)", called, true)
end

-- ============================================================================
print("== 8. 设备名默认值（读设备型号）==")
-- ============================================================================
-- 设备名写进云端记录的文件名,而记录靠**设备名**区分来源 ——
-- 默认值全都一样的话,几台设备的记录会被当成同一台。
-- 探测有四个分支(安卓 / 通用 model / info() / 都没有),真机上只能碰运气遇到。
do
    local function with_device(dev, android)
        package.preload["device"]  = dev     and function() return dev end     or nil
        package.preload["android"] = android and function() return android end or nil
        package.loaded["device"]   = nil
        package.loaded["android"]  = nil
        return InkBridge._detect_device_model()
    end

    eq("Kindle:直接用 Device.model", with_device({ model = "KindlePaperWhite6" }), "KindlePaperWhite6")
    eq("Scribe 也是", with_device({ model = "KindleScribe" }), "KindleScribe")
    eq("Kobo 的型号带前缀", with_device({ model = "Kobo_luna" }), "Kobo_luna")

    -- 安卓:优先 android.prop.model(手机"设置→关于"里那个),它比 KOReader 用的
    -- android.prop.product(ro.product.name,常常只是代号)更好认
    eq("安卓:优先营销型号",
       with_device({ model = "PJZ110" }, { prop = { model = "OnePlus 13", product = "PJZ110" } }),
       "OnePlus 13")
    eq("安卓:没有 prop.model 时退回 Device.model",
       with_device({ model = "PJZ110" }, { prop = { product = "PJZ110" } }), "PJZ110")
    eq("安卓:prop 不是表也不炸",
       with_device({ model = "android-arm64" }, { prop = "坏数据" }), "android-arm64")

    -- 有些平台只给 :info()
    eq("没有 model 字段时试 info()",
       with_device({ info = function() return "PB1040" end }), "PB1040")
    eq("info() 抛异常时不留半个名字",
       with_device({ info = function() error("boom") end }), nil)

    -- 都拿不到:返回 nil,由调用方决定退回什么
    eq("没有 device 模块", with_device(nil), nil)
    eq("model 是 nil", with_device({}), nil)
    eq("model 是空串", with_device({ model = "" }), nil)
    eq("model 不是字符串", with_device({ model = 123 }), nil)

    package.preload["device"], package.preload["android"] = nil, nil
    package.loaded["device"], package.loaded["android"] = nil, nil
end

-- ============================================================================
print("== 9. 设备名长度上限（不能把两台设备截成同一个）==")
-- ============================================================================
do
    local function name_for(label)
        local p = new_plugin({ device_label = label })
        return p:_history_name({ book_id = "deadbeefcafe1234", book_name = "书",
                                 updated_at = 1760000000 })
    end

    -- ★ 这两台都是真实机型。上限若是 16,截断后都会变成 "KindlePaperWhit",
    -- 云端就会把它们当成**同一台设备** —— 选更新只挑一条、保留策略共用一个桶。
    local a = name_for("KindlePaperWhite5SE")
    local b = name_for("KindlePaperWhite6")
    contains("长型号完整保留", a, "-KindlePaperWhite5SE.deadbeef.InkBridge.txt")
    check("两种机型不会被截成同一个名字", a ~= b, a .. " vs " .. b)
    eq("上限是 32", InkBridge.DEVICE_LABEL_MAX, 32)

    -- 截断仍然按**字符**算:汉字不能被劈成半个
    local utf8_len = State._utf8_len
    local long = name_for(string.rep("长", 100))
    local label = long:match("%-%d%d%d%d%-%d%d%d%d%d%d%-(.-)%.deadbeef")
    eq("超长名字按字符截到 32", utf8_len(label or ""), 32)

    -- 设备名里的非法字符照样要清掉(安卓型号可能带空格/斜杠)
    local weird = name_for("OnePlus 13/LE2110")
    check("非法字符被替换", weird:find("/", 1, true) == nil, weird)
    contains("空格保留(文件名允许)", weird, "OnePlus 13_LE2110")
end

do
    local History = require("inkbridge_home_history")
    local old_observe, old_write, old_upload = History.observe, State.write_file, WebDAV.upload
    local Moonsync = require("inkbridge_moonsync")
    local old_auto = Moonsync.auto_push
    local cached, source, cached_file, cached_id, moon_pushes = 0, nil, nil, nil, 0
    History.observe = function(_, entry, from, file, book_id)
        cached = cached + 1
        source, cached_file, cached_id = from, file, book_id
    end
    State.write_file = function() return true end
    Moonsync.auto_push = function() moon_pushes = moon_pushes + 1; return nil end
    local plugin = new_plugin{
        _staging_dir = function() return SETTINGS_DIR end,
        _prune_history = function(_, _, _, cb) if cb then cb(0) end end,
    }
    local entry = { book_id = "deadbeef", book_name = "书", book_file = "book.epub",
        text_anchor = "真实同步正文" }
    WebDAV.upload = function(_, _, cb) cb(false, "upload failed") end
    plugin:_sync(entry, "upload")
    eq("上传失败不产生首页记录", cached, 0)
    WebDAV.upload = function(_, _, cb) cb(true) end
    plugin:_sync(entry, "upload")
    eq("成功上传才采集首页正文", cached, 1)
    eq("上传来源不冒充静读天下", source, "墨桥 · 本机上传")
    eq("上传回调传递原书文件快照", cached_file, "book.epub")
    eq("上传回调传递原书身份快照", cached_id, "deadbeef")
    eq("手动上传仍写回 Moon+", moon_pushes, 1)
    cached = 0
    plugin:_sync(entry, "upload", { close_document = true })
    eq("关书自动上传不触发 Moon+ 写回", cached, 1)
    eq("关书自动上传不触发 Moon+ 写回", moon_pushes, 1)
    History.observe, State.write_file, WebDAV.upload, Moonsync.auto_push = old_observe, old_write, old_upload, old_auto
end

do
    local uploads, options = 0
    connected = true
    local plugin = new_plugin{
        _book_context = function() return { book_id = "deadbeef", percent = 0.5 } end,
        _sync = function(_, _, mode, opts)
            if mode == "upload" then uploads = uploads + 1; options = opts end
        end,
    }
    plugin:onCloseDocument()
    plugin:onCloseDocument()
    eq("关书事件每份文档只触发一次上传", uploads, 1)
    check("关书上传标记模式且不调用Moon+", options and options.close_document == true)

    connected = false
    local offline = new_plugin{
        _book_context = function() return { book_id = "deadbeef" } end,
        _sync = function() uploads = uploads + 1 end,
    }
    offline:onCloseDocument()
    eq("离线关书不派发上传", uploads, 1, shown[#shown].text)
    contains("离线关书明确提示未上传", shown[#shown].text, "未上传云端")
    connected = true
end

-- ============================================================================
print("== 10. 检查更新的完整请求流程 ==")
-- ============================================================================
do
    local module_names = { "socket.http", "socket", "ltn12", "rapidjson" }
    local saved = {}
    for _, name in ipairs(module_names) do saved[name] = package.loaded[name] end
    local request, decoded, request_count, response_body = nil, nil, 0, '{"tag_name":"v0.3.20-alpha"}'
    local mode = "success"
    package.loaded["socket"] = { skip = function(n, ...) return select(n + 1, ...) end }
    package.loaded["ltn12"] = { sink = { table = function(buffer)
        -- 与真实 ltn12 一样：未传表时内部新建，但调用方必须持有它才能读取正文。
        buffer = buffer or {}
        return function(chunk)
            if chunk then buffer[#buffer + 1] = chunk end
            return 1
        end, buffer
    end } }
    package.loaded["socket.http"] = { request = function(req)
        request_count = request_count + 1
        request = req
        if mode == "exception" then error("TLS handshake failed") end
        req.sink(response_body:sub(1, 12))
        req.sink(response_body:sub(13))
        req.sink(nil)
        if mode == "timeout" then return nil, "timeout" end
        if mode == "forbidden" then return 1, 403, {}, "HTTP/1.1 403 Forbidden" end
        if mode == "missing" then return 1, 404, {}, "HTTP/1.1 404 Not Found" end
        -- headers 和 status 不能被透传成 tonumber 的第二、第三个参数。
        return 1, "200", { ["content-type"] = "application/json" }, "HTTP/1.1 200 OK"
    end }
    package.loaded["rapidjson"] = { decode = function(body)
        decoded = body
        if mode == "invalid_json" then error("bad json") end
        return { tag_name = "v0.3.20-alpha", assets = {
            { name = "inkbridge.moon.koplugin-v0.3.20-alpha.zip",
              browser_download_url = "https://example.com/update.zip" },
        } }
    end }
    local function run(check_network)
        shown, last_keyvalue, decoded = {}, nil, nil
        if check_network then new_plugin():check_update() else new_plugin():_do_check_update() end
        return shown[#shown] and shown[#shown].text or ""
    end

    connected = true
    run(true)
    eq("更新请求只发送一次", request_count, 1)
    eq("更新请求使用固定官方 API", request and request.url, require("inkbridge_update").API_URL)
    eq("更新请求只读", request and request.method, "GET")
    eq("更新请求带 User-Agent", request and request.headers["User-Agent"], "inkbridge-koplugin")
    eq("更新请求带 GitHub JSON 类型", request and request.headers.Accept, "application/vnd.github+json")
    eq("HTTP 200 的多返回值不误报网络失败", last_keyvalue and last_keyvalue.title, "墨桥 · 检查更新")
    eq("多个数据块完整进入 JSON 解码器", decoded, response_body)
    eq("更新页面显示返回版本", row_value(last_keyvalue and last_keyvalue.kv_pairs, "最新版本"), "v0.3.20-alpha")
    eq("同版本不显示下载地址", row_value(last_keyvalue and last_keyvalue.kv_pairs, "下载地址"), nil)

    local install_confirmation
    local major, minor, patch = require("_meta").version:match("^(%d+)%.(%d+)%.(%d+)")
    local newer_tag = string.format("v%d.%d.%d-alpha", tonumber(major), tonumber(minor), tonumber(patch) + 1)
    local newer_plugin = new_plugin{ _confirm_install_update = function(_, rel) install_confirmation = rel end }
    package.loaded["rapidjson"].decode = function(body)
        decoded = body
        if mode == "invalid_json" then error("bad json") end
        return { tag_name = newer_tag, assets = {
            { name = "inkbridge.moon.koplugin-" .. newer_tag .. ".zip",
              browser_download_url = "https://example.com/update.zip", size = 10,
              digest = "sha256:" .. string.rep("a", 64) },
        } }
    end
    newer_plugin:_do_check_update()
    eq("发现新版进入安装确认", install_confirmation and install_confirmation.tag, newer_tag)

    mode = "timeout"
    local text = run()
    eq("超时不打开更新页面", last_keyvalue, nil)
    eq("失败时不解码残留的部分正文", decoded, nil)
    contains("超时保留诊断原因", text, "timeout")

    mode = "exception"
    text = run()
    eq("网络库抛异常不崩溃、不打开页面", last_keyvalue, nil)
    contains("网络异常保留诊断原因", text, "TLS handshake failed")

    mode = "forbidden"
    text = run()
    contains("HTTP 403 显示服务器状态", text, "403")
    eq("HTTP 403 不作为版本正文解码", decoded, nil)
    mode = "missing"
    contains("HTTP 404 显示服务器状态", run(), "404")

    mode = "invalid_json"
    text = run()
    contains("HTTP 200 的坏 JSON 提示解析失败", text, "没能读懂")
    eq("坏 JSON 不打开更新页面", last_keyvalue, nil)

    mode, connected, wifi_prompt = "success", false, nil
    local before = request_count
    run(true)
    eq("离线时不直接请求 GitHub", request_count, before)
    check("离线检查沿用联网确认", type(wifi_prompt) == "function")
    connected = true
    if wifi_prompt then wifi_prompt() end
    eq("联网确认后才发送请求", request_count, before + 1)
    eq("联网确认后的正文仍完整", decoded, response_body)

    for _, name in ipairs(module_names) do package.loaded[name] = saved[name] end
end

-- 收尾：清掉测试用的设置目录
if is_windows then
    os.execute('rmdir /s /q "' .. SETTINGS_DIR .. '" 2>' .. null_device)
else
    os.execute('rm -rf "' .. SETTINGS_DIR .. '" 2>' .. null_device)
end

print(string.format("\n合计：%d 通过，%d 失败", passed, failed))
if failed > 0 then os.exit(1) end
print("全部通过。")
